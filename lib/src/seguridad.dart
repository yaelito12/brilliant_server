import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart'
    show Argon2BytesGenerator, Argon2Parameters;

import 'config.dart';

const issuer = 'brilliant-auth';
const audience = 'brilliant-app';

final _random = Random.secure();

Uint8List bytesAleatorios(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _random.nextInt(256)));

String base64UrlSinRelleno(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<int> decodificarBase64Url(String s) => base64Url.decode(base64Url.normalize(s));

/// UUID v4 aleatorio.
String nuevoUuid() {
  final b = bytesAleatorios(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// Comparación en tiempo constante (no revela en qué byte difieren).
bool igualesTiempoConstante(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a[i] ^ b[i];
  }
  return r == 0;
}

// ---------------------------------------------------------------------------
// Argon2id con el formato PHC estándar ($argon2id$v=19$m=..,t=..,p=..$sal$hash),
// el mismo que usaba el servidor de Node: las cuentas ya creadas siguen sirviendo.
// ---------------------------------------------------------------------------

Uint8List _argon2id(
  List<int> password,
  List<int> sal,
  List<int>? pepper,
  int memoria,
  int iteraciones,
  int paralelismo,
  int largo,
) {
  final gen = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        Uint8List.fromList(sal),
        secret: pepper == null ? null : Uint8List.fromList(pepper),
        desiredKeyLength: largo,
        iterations: iteraciones,
        memory: memoria,
        lanes: paralelismo,
        version: Argon2Parameters.ARGON2_VERSION_13,
      ),
    );
  return gen.process(Uint8List.fromList(password));
}

/// Argon2 es caro a propósito (cientos de ms): se calcula en otro isolate para
/// que el servidor siga atendiendo a los demás mientras tanto.
Future<Uint8List> _argon2idAparte(
  List<int> password,
  List<int> sal,
  List<int>? pepper,
  int memoria,
  int iteraciones,
  int paralelismo,
  int largo,
) => Isolate.run(
  () => _argon2id(password, sal, pepper, memoria, iteraciones, paralelismo, largo),
);

class _HashPhc {
  final int memoria, iteraciones, paralelismo;
  final List<int> sal, hash;
  _HashPhc(this.memoria, this.iteraciones, this.paralelismo, this.sal, this.hash);

  static _HashPhc? leer(String s) {
    final partes = s.split(r'$');
    // ['', 'argon2id', 'v=19', 'm=..,t=..,p=..', sal, hash]
    if (partes.length != 6 || partes[1] != 'argon2id' || partes[2] != 'v=19') {
      return null;
    }
    final params = <String, int>{};
    for (final kv in partes[3].split(',')) {
      final i = kv.indexOf('=');
      if (i <= 0) return null;
      final v = int.tryParse(kv.substring(i + 1));
      if (v == null || v <= 0) return null;
      params[kv.substring(0, i)] = v;
    }
    final m = params['m'], t = params['t'], p = params['p'];
    if (m == null || t == null || p == null) return null;
    try {
      return _HashPhc(
        m,
        t,
        p,
        base64.decode(base64.normalize(partes[4])),
        base64.decode(base64.normalize(partes[5])),
      );
    } on FormatException {
      return null;
    }
  }
}

String _b64SinRelleno(List<int> b) => base64.encode(b).replaceAll('=', '');

class Seguridad {
  final Config config;
  final List<int> _secretoJwt;
  final List<int>? _pepper;
  Future<String>? _hashSenuelo;

  Seguridad(this.config)
    : _secretoJwt = utf8.encode(config.jwtSecret),
      _pepper = config.passwordPepper == null
          ? null
          : utf8.encode(config.passwordPepper!);

  Future<String> hashearPassword(String password) async {
    final a = config.argon2;
    final sal = bytesAleatorios(16);
    final hash = await _argon2idAparte(
      utf8.encode(password),
      sal,
      _pepper,
      a.memoriaKiB,
      a.iteraciones,
      a.paralelismo,
      32,
    );
    return '\$argon2id\$v=19\$m=${a.memoriaKiB},t=${a.iteraciones},p=${a.paralelismo}'
        '\$${_b64SinRelleno(sal)}\$${_b64SinRelleno(hash)}';
  }

  Future<bool> verificarPassword(String hashGuardado, String password) async {
    final phc = _HashPhc.leer(hashGuardado);
    if (phc == null) return false;
    final calculado = await _argon2idAparte(
      utf8.encode(password),
      phc.sal,
      _pepper,
      phc.memoria,
      phc.iteraciones,
      phc.paralelismo,
      phc.hash.length,
    );
    return igualesTiempoConstante(calculado, phc.hash);
  }

  /// Hash "señuelo": cuando el nametag no existe también se hace una verificación
  /// de Argon2 para que la respuesta tarde lo mismo (evita enumerar usuarios por tiempo).
  Future<void> verificarContraSenuelo(String password) async {
    final senuelo = await (_hashSenuelo ??= hashearPassword(
      base64UrlSinRelleno(bytesAleatorios(16)),
    ));
    await verificarPassword(senuelo, password);
  }

  // ---------------------------------------------------------------------------
  // JWT HS256. El algoritmo está fijado: un token con "alg": "none" u otro
  // algoritmo se rechaza siempre.
  // ---------------------------------------------------------------------------

  static final _cabeceraJwt = base64UrlSinRelleno(
    utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})),
  );

  List<int> _firmar(String datos) =>
      Hmac(sha256, _secretoJwt).convert(utf8.encode(datos)).bytes;

  /// [sesion] es el id de la sesión (la familia de refresh tokens). Con él se
  /// comprueba en cada petición que la sesión siga abierta.
  String crearAccessToken(String userId, String sesion, {int? ahoraSeg}) {
    final iat = ahoraSeg ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return firmarJwt({
      'sub': userId,
      'sid': sesion,
      'iss': issuer,
      'aud': audience,
      'jti': nuevoUuid(),
      'iat': iat,
      'exp': iat + config.accessTtlSeg,
    });
  }

  /// Firma un payload cualquiera (también lo usan las pruebas).
  String firmarJwt(Map<String, Object?> payload) {
    final cuerpo = base64UrlSinRelleno(utf8.encode(jsonEncode(payload)));
    final datos = '$_cabeceraJwt.$cuerpo';
    return '$datos.${base64UrlSinRelleno(_firmar(datos))}';
  }

  /// Devuelve el usuario y la sesión del token, o null si no es válido, está
  /// vencido o no dice a qué sesión pertenece.
  ({String userId, String sesion})? verificarAccessToken(String token) {
    try {
      final partes = token.split('.');
      if (partes.length != 3) return null;
      final cabecera = jsonDecode(utf8.decode(decodificarBase64Url(partes[0])));
      if (cabecera is! Map || cabecera['alg'] != 'HS256') return null;

      final firma = decodificarBase64Url(partes[2]);
      if (!igualesTiempoConstante(firma, _firmar('${partes[0]}.${partes[1]}'))) {
        return null;
      }
      final p = jsonDecode(utf8.decode(decodificarBase64Url(partes[1])));
      if (p is! Map) return null;
      final ahora = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final exp = p['exp'];
      if (exp is! num || exp <= ahora) return null;
      final nbf = p['nbf'];
      if (nbf != null && (nbf is! num || nbf > ahora)) return null;
      if (p['iss'] != issuer) return null;
      final aud = p['aud'];
      if (!(aud == audience || (aud is List && aud.contains(audience)))) return null;
      final sub = p['sub'];
      final sid = p['sid'];
      if (sub is! String || sub.isEmpty || sid is! String || sid.isEmpty) return null;
      return (userId: sub, sesion: sid);
    } catch (_) {
      return null;
    }
  }

  String nuevoRefreshToken() => base64UrlSinRelleno(bytesAleatorios(32));

  String hashToken(String token) => sha256.convert(utf8.encode(token)).toString();

  /// Clave (anónima) para contar intentos fallidos de un nametag.
  String hashClaveUsuario(String nametagMinusculas) =>
      Hmac(sha256, _secretoJwt).convert(utf8.encode(nametagMinusculas)).toString();
}

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpConnectionInfo, stderr;
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import 'api_error.dart';
import 'config.dart';

const limiteCuerpoBytes = 10 * 1024;

Response respuestaJson(int status, Object? cuerpo, {Map<String, String>? headers}) =>
    Response(
      status,
      body: jsonEncode(cuerpo),
      headers: {'content-type': 'application/json; charset=utf-8', ...?headers},
    );

/// Lee el cuerpo como objeto JSON (máximo 10 KB). Si la petición no dice
/// `Content-Type: application/json` se trata como cuerpo vacío.
Future<Map<String, Object?>> leerJson(Request req) async {
  final tipo = req.headers['content-type'] ?? '';
  if (!tipo.toLowerCase().startsWith('application/json')) return {};

  final largo = req.contentLength;
  if (largo != null && largo > limiteCuerpoBytes) throw _muyGrande();

  final bytes = BytesBuilder(copy: false);
  await for (final trozo in req.read()) {
    bytes.add(trozo);
    if (bytes.length > limiteCuerpoBytes) throw _muyGrande();
  }
  if (bytes.isEmpty) return {};
  try {
    final dato = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (dato is Map<String, Object?>) return dato;
  } on FormatException {
    // cae al error de abajo
  }
  throw ApiError(400, 'json_invalido', 'El cuerpo no es un JSON válido.');
}

ApiError _muyGrande() =>
    ApiError(413, 'cuerpo_muy_grande', 'El cuerpo es demasiado grande.');

/// IP real del cliente (respeta X-Forwarded-For solo si hay proxies de confianza).
String ipCliente(Request req, int trustProxy) {
  final info = req.context['shelf.io.connection_info'] as HttpConnectionInfo?;
  final socket = info?.remoteAddress.address ?? 'desconocida';
  if (trustProxy <= 0) return socket;
  final cadena = [
    ...(req.headers['x-forwarded-for'] ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty),
    socket,
  ];
  // Se cuentan [trustProxy] saltos desde la derecha (como "trust proxy" de Express).
  final i = cadena.length - 1 - trustProxy;
  return cadena[i < 0 ? 0 : i];
}

bool esHttps(Request req, int trustProxy) {
  if (trustProxy > 0) {
    final proto = req.headers['x-forwarded-proto'];
    if (proto != null) return proto.split(',').first.trim().toLowerCase() == 'https';
  }
  return req.requestedUri.scheme == 'https';
}

/// Límite de peticiones por IP en una ventana fija.
class LimitePorIp {
  final Duration ventana;
  final int limite;
  final _cuentas = <String, ({int cuenta, DateTime reinicio})>{};

  LimitePorIp({required this.ventana, required this.limite});

  /// Devuelve los segundos a esperar si se pasó del límite, o null si puede seguir.
  int? registrar(String ip) {
    final ahora = DateTime.now();
    var c = _cuentas[ip];
    if (c == null || !ahora.isBefore(c.reinicio)) {
      c = (cuenta: 0, reinicio: ahora.add(ventana));
    }
    c = (cuenta: c.cuenta + 1, reinicio: c.reinicio);
    _cuentas[ip] = c;
    if (c.cuenta <= limite) return null;
    final s = c.reinicio.difference(ahora).inSeconds;
    return s < 1 ? 1 : s;
  }

  void limpiar() {
    final ahora = DateTime.now();
    _cuentas.removeWhere((_, c) => !ahora.isBefore(c.reinicio));
  }
}

/// Cabeceras de seguridad (las mismas que pone `helmet` por defecto) y no-store.
const cabecerasSeguridad = {
  'content-security-policy':
      "default-src 'self';base-uri 'self';font-src 'self' https: data:;form-action 'self';"
      "frame-ancestors 'self';img-src 'self' data:;object-src 'none';script-src 'self';"
      "script-src-attr 'none';style-src 'self' https: 'unsafe-inline';upgrade-insecure-requests",
  'cross-origin-opener-policy': 'same-origin',
  'cross-origin-resource-policy': 'same-origin',
  'origin-agent-cluster': '?1',
  'referrer-policy': 'no-referrer',
  'strict-transport-security': 'max-age=31536000; includeSubDomains',
  'x-content-type-options': 'nosniff',
  'x-dns-prefetch-control': 'off',
  'x-download-options': 'noopen',
  'x-frame-options': 'SAMEORIGIN',
  'x-permitted-cross-domain-policies': 'none',
  'x-xss-protection': '0',
  'cache-control': 'no-store',
};

/// Convierte cualquier excepción en una respuesta JSON limpia y añade las
/// cabeceras de seguridad. Los errores internos solo van al log.
Middleware manejarErrores() => (inner) => (req) async {
  Response res;
  try {
    res = await inner(req);
  } on ApiError catch (e) {
    final espera = e.extra['reintentarEnSegundos'];
    res = respuestaJson(
      e.status,
      e.toJson(),
      headers: espera != null ? {'retry-after': '$espera'} : null,
    );
  } on HijackException {
    rethrow; // WebSocket: la conexión ya no es HTTP.
  } catch (e, st) {
    stderr.writeln('[error] $e\n$st');
    res = respuestaJson(500, {
      'error': {'code': 'error_interno', 'message': 'Error interno del servidor.'},
    });
  }
  return res.change(headers: cabecerasSeguridad);
};

Middleware exigirHttps(Config config) => (inner) => (req) {
  if (!esHttps(req, config.trustProxy)) {
    throw ApiError(400, 'https_requerido', 'Se requiere HTTPS.');
  }
  return inner(req);
};

Middleware cors(List<String> origenes) => (inner) => (req) async {
  final origen = req.headers['origin'];
  final permitido = origen != null && origenes.contains(origen);
  final cabeceras = permitido
      ? {'access-control-allow-origin': origen, 'vary': 'Origin'}
      : <String, String>{};
  if (req.method == 'OPTIONS') {
    return Response(204, headers: {
      ...cabeceras,
      if (permitido) ...{
        'access-control-allow-methods': 'GET,POST',
        'access-control-allow-headers':
            req.headers['access-control-request-headers'] ?? 'content-type,authorization',
        'access-control-max-age': '600',
      },
    });
  }
  final res = await inner(req);
  return res.change(headers: cabeceras);
};

Middleware limitarPorIp(LimitePorIp limite, Config config) => (inner) => (req) {
  final espera = limite.registrar(ipCliente(req, config.trustProxy));
  if (espera != null) {
    throw ApiError(
      429,
      'demasiadas_peticiones',
      'Demasiadas peticiones. Espera unos minutos.',
      {'reintentarEnSegundos': espera},
    );
  }
  return inner(req);
};

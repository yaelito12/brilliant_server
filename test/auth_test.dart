import 'dart:convert';
import 'dart:io';

import 'package:brilliant_server/brilliant_server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const secret = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; // 48
const pass = 'una-clave-larga-123';

late HttpServer server;
late String base;
late Database db;
late Config config;
late AppAuth app;

Future<void> arrancar({int? limiteAuth, bool? requireHttps, List<String>? corsOrigins}) async {
  config = cargarConfig({'JWT_SECRET': secret}).copyWith(
    // Argon2 liviano solo para que las pruebas corran rápido.
    argon2: const ParametrosArgon2(memoriaKiB: 1024, iteraciones: 1, paralelismo: 1),
    limiteGlobal: 10000,
    limiteAuth: limiteAuth ?? 10000,
    requireHttps: requireHttps,
    corsOrigins: corsOrigins,
  );
  db = abrirDb(':memory:');
  app = AppAuth(config: config, db: db);
  server = await shelf_io.serve(app.handler, '127.0.0.1', 0, poweredByHeader: null);
  base = 'http://127.0.0.1:${server.port}';
}

Future<void> parar() async {
  await server.close(force: true);
  db.close();
}

typedef Resp = ({int status, Map<String, String> headers, dynamic json});

Future<Resp> api(String method, String path, {Object? body, String? token, String? raw}) async {
  final req = http.Request(method, Uri.parse(base + path));
  if (body != null || raw != null) req.headers['content-type'] = 'application/json';
  if (token != null) req.headers['authorization'] = 'Bearer $token';
  if (raw != null) {
    req.body = raw;
  } else if (body != null) {
    req.body = jsonEncode(body);
  }
  final res = await http.Response.fromStream(await req.send());
  return (
    status: res.statusCode,
    headers: res.headers,
    json: res.body.isEmpty ? null : jsonDecode(res.body),
  );
}

Future<Resp> registrar([String nametag = 'Ana', Map<String, Object?> extra = const {}]) =>
    api('POST', '/auth/register', body: {'nametag': nametag, 'password': pass, ...extra});

/// Hace como si las sesiones abiertas no dieran señales de vida hace rato
/// (el otro dispositivo se cerró sin salir).
void envejecerSesiones() =>
    db.execute('UPDATE refresh_tokens SET last_seen_at = 1, created_at = 1');

/// Inicia sesión como Ana con la contraseña correcta (con las otras sesiones
/// ya inactivas, para que no se bloquee por "sesión en uso").
Future<Resp> entrar() {
  envejecerSesiones();
  return api('POST', '/auth/login', body: {'nametag': 'Ana', 'password': pass});
}

int contar(String tabla) => db.select('SELECT COUNT(*) c FROM $tabla').first['c'] as int;

void main() {
  setUp(arrancar);
  tearDown(parar);

  test('registro devuelve sesión y NO guarda la contraseña en claro', () async {
    final r = await registrar();
    expect(r.status, 201);
    expect(r.json['accessToken'], isNotEmpty);
    expect(r.json['refreshToken'], isNotEmpty);
    expect(r.json['user'], {'id': isA<String>(), 'nametag': 'Ana'});

    final fila = db.select('SELECT * FROM users').first;
    expect(fila['password_hash'], startsWith(r'$argon2id$'));
    expect(fila['password_hash'], isNot(contains(pass)));
    final rt = db.select('SELECT token_hash FROM refresh_tokens').first;
    expect(rt['token_hash'], isNot(r.json['refreshToken'])); // solo se guarda el hash
  });

  test('el nametag es único sin importar mayúsculas y conserva las que se eligieron', () async {
    final primero = await registrar('  Ana_99 ');
    expect(primero.status, 201);
    expect(primero.json['user']['nametag'], 'Ana_99');
    for (final repetido in ['ana_99', 'ANA_99', 'Ana_99']) {
      final dup = await registrar(repetido);
      expect(dup.status, 409, reason: repetido);
      expect(dup.json['error']['code'], 'nametag_en_uso');
    }
  });

  test('registro valida los datos', () async {
    final malos = <Map<String, Object?>>[
      {'nametag': 'ab'},
      {'nametag': 'a' * 21},
      {'nametag': 'con espacio'},
      {'nametag': '<script>'},
      {'nametag': 'Ánder'},
      {'password': '12345'},
      {'password': 'a' * 129},
      {'password': '123456'},
      {'password': 'qwerty'},
      {'password': 'aaaaaa'},
      {'password': 'Pepe_01'}, // igual que su nametag
    ];
    for (final m in malos) {
      final r = await registrar(m['password'] == 'Pepe_01' ? 'Pepe_01' : 'Nuevo_1', m);
      expect(r.status, 400, reason: '$m');
      expect(r.json['error']['code'], 'validacion');
    }
    expect((await api('POST', '/auth/register', body: {})).status, 400);
    expect((await registrar('Seis_1', {'password': 'zorro7'})).status, 201);
  });

  test('login correcto e incorrecto (mismo mensaje exista o no el usuario)', () async {
    await registrar();
    final ok = await entrar();
    expect(ok.status, 200);
    expect(ok.json['accessToken'], isNotEmpty);

    final malaPass = await api('POST', '/auth/login',
        body: {'nametag': 'Ana', 'password': 'otra-clave-123'});
    final noExiste = await api('POST', '/auth/login',
        body: {'nametag': 'Nadie', 'password': 'otra-clave-123'});
    expect(malaPass.status, 401);
    expect(noExiste.status, 401);
    expect(malaPass.json, noExiste.json);
  });

  test('bloqueo tras varios intentos fallidos (también para nametags inexistentes)', () async {
    await registrar();
    for (final nametag in ['Ana', 'Fantasma']) {
      for (var i = 0; i < config.maxIntentosFallidos; i++) {
        final r = await api('POST', '/auth/login',
            body: {'nametag': nametag, 'password': 'mala-clave-123'});
        expect(r.status, 401);
      }
      final bloqueado = await api('POST', '/auth/login', body: {'nametag': nametag, 'password': pass});
      expect(bloqueado.status, 429);
      expect(bloqueado.json['error']['code'], 'cuenta_bloqueada');
      expect(bloqueado.headers['retry-after'], isNotNull);
    }
  });

  test('un login correcto reinicia el contador de fallos', () async {
    await registrar();
    for (var vuelta = 0; vuelta < 2; vuelta++) {
      for (var i = 0; i < config.maxIntentosFallidos - 1; i++) {
        await api('POST', '/auth/login', body: {'nametag': 'Ana', 'password': 'mala-clave-123'});
      }
      expect((await entrar()).status, 200);
    }
  });

  test('/account/me exige un access token válido', () async {
    final s = (await registrar()).json;
    expect((await api('GET', '/account/me')).status, 401);
    expect((await api('GET', '/account/me', token: 'basura')).status, 401);
    final me = await api('GET', '/account/me', token: s['accessToken']);
    expect(me.status, 200);
    expect(me.json['user']['nametag'], 'Ana');
  });

  test('rechaza JWT firmado con otra clave, vencido, sin sesión o con alg=none', () async {
    final id = (await registrar()).json['user']['id'] as String;
    final sid = db.select('SELECT family_id FROM refresh_tokens').first['family_id'] as String;
    final ahora = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String firmar(String clave, int exp, {String? sesion = ''}) =>
        Seguridad(cargarConfig({'JWT_SECRET': clave})).firmarJwt({
          'sub': id,
          'sid': sesion == '' ? sid : sesion,
          'iss': 'brilliant-auth',
          'aud': 'brilliant-app',
          'exp': exp,
        });

    expect((await api('GET', '/account/me', token: firmar('y' * 48, ahora + 300))).status, 401);
    expect((await api('GET', '/account/me', token: firmar(secret, ahora - 60))).status, 401);
    expect((await api('GET', '/account/me', token: firmar(secret, ahora + 300))).status, 200);
    expect((await api('GET', '/account/me', token: firmar(secret, ahora + 300, sesion: null))).status, 401);
    expect((await api('GET', '/account/me', token: firmar(secret, ahora + 300, sesion: 'inventada'))).status, 401);

    String b64(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
    final none = '${b64({'alg': 'none', 'typ': 'JWT'})}.'
        '${b64({'sub': id, 'iss': 'brilliant-auth', 'aud': 'brilliant-app', 'exp': 9999999999})}.';
    expect((await api('GET', '/account/me', token: none)).status, 401);
  });

  test('refresh rota el token y detecta reutilización (revoca toda la sesión)', () async {
    final s1 = (await registrar()).json;
    final r2 = await api('POST', '/auth/refresh', body: {'refreshToken': s1['refreshToken']});
    expect(r2.status, 200);
    expect(r2.json['refreshToken'], isNot(s1['refreshToken']));

    final reuso = await api('POST', '/auth/refresh', body: {'refreshToken': s1['refreshToken']});
    expect(reuso.status, 401);
    final tras = await api('POST', '/auth/refresh', body: {'refreshToken': r2.json['refreshToken']});
    expect(tras.status, 401);
  });

  test('refresh con token inventado o vencido falla', () async {
    expect((await api('POST', '/auth/refresh', body: {'refreshToken': 'a' * 43})).status, 401);
    final s = (await registrar()).json;
    db.execute('UPDATE refresh_tokens SET expires_at = 1');
    expect((await api('POST', '/auth/refresh', body: {'refreshToken': s['refreshToken']})).status, 401);
  });

  test('logout revoca el refresh token', () async {
    final s = (await registrar()).json;
    expect((await api('POST', '/auth/logout', body: {'refreshToken': s['refreshToken']})).status, 204);
    expect((await api('POST', '/auth/refresh', body: {'refreshToken': s['refreshToken']})).status, 401);
    expect((await api('POST', '/auth/logout', body: {'refreshToken': 'b' * 43})).status, 204);
  });

  test('logout-all cierra todas las sesiones', () async {
    final a = (await registrar()).json;
    final b = (await entrar()).json;
    // Al entrar con b, la sesión a ya quedó cerrada: logout-all se pide desde b.
    expect((await api('POST', '/auth/logout-all', token: b['accessToken'])).status, 204);
    expect((await api('POST', '/auth/refresh', body: {'refreshToken': a['refreshToken']})).status, 401);
    expect((await api('POST', '/auth/refresh', body: {'refreshToken': b['refreshToken']})).status, 401);
  });

  test('borrar cuenta: exige contraseña, borra todo y el token deja de servir', () async {
    final s = (await registrar()).json;
    final token = s['accessToken'] as String;
    expect((await api('POST', '/account/delete', body: {'password': pass})).status, 401);
    expect((await api('POST', '/account/delete', body: {'password': 'incorrecta-123'}, token: token)).status, 403);
    expect((await api('GET', '/account/me', token: token)).status, 200);

    expect((await api('POST', '/account/delete', body: {'password': pass}, token: token)).status, 204);
    expect(contar('users'), 0);
    expect(contar('refresh_tokens'), 0);
    expect((await api('GET', '/account/me', token: token)).status, 401);
    expect((await api('POST', '/auth/refresh', body: {'refreshToken': s['refreshToken']})).status, 401);
    expect((await entrar()).status, 401);
    expect((await registrar()).status, 201);
  });

  test('JSON inválido, cuerpo enorme y rutas inexistentes dan errores limpios', () async {
    final malo = await api('POST', '/auth/login', raw: '{no es json');
    expect(malo.status, 400);
    expect(malo.json['error']['code'], 'json_invalido');
    final grande = await api('POST', '/auth/login', body: {'nametag': 'ana', 'password': 'x' * 20000});
    expect(grande.status, 413);
    expect((await api('GET', '/nada')).status, 404);
  });

  test('cabeceras de seguridad presentes y sin x-powered-by', () async {
    final r = await api('GET', '/health');
    expect(r.headers['x-powered-by'], isNull);
    expect(r.headers['x-content-type-options'], 'nosniff');
    expect(r.headers['cache-control'], 'no-store');
  });

  test('inyección SQL en el nametag no funciona', () async {
    await registrar();
    final r = await api('POST', '/auth/login', body: {'nametag': "' OR 1=1 --", 'password': pass});
    expect(r.status, 401);
    expect((await registrar("x' OR '1'='1")).status, 400);
    expect(contar('users'), 1);
  });

  test('límite de peticiones por IP en rutas de autenticación', () async {
    await parar();
    await arrancar(limiteAuth: 3);
    final estados = <int>[];
    for (var i = 0; i < 5; i++) {
      estados.add((await api('POST', '/auth/login', body: {'nametag': 'ana', 'password': 'x'})).status);
    }
    expect(estados, [401, 401, 401, 429, 429]);
  });

  test('CORS: también las respuestas de error llevan el permiso (si no, la web no ve el mensaje)', () async {
    await parar();
    await arrancar(corsOrigins: ['http://localhost:5000']);
    Future<Map<String, String>> cabeceras(String origen, Map<String, Object?> cuerpo) async {
      final req = http.Request('POST', Uri.parse('$base/auth/login'))
        ..headers['content-type'] = 'application/json'
        ..headers['origin'] = origen
        ..body = jsonEncode(cuerpo);
      return (await http.Response.fromStream(await req.send())).headers;
    }

    await registrar();
    // 401 (contraseña mala), 409 (cuenta en uso) y 400 (datos inválidos).
    for (final cuerpo in [
      {'nametag': 'Ana', 'password': 'otra-clave-123'},
      {'nametag': 'Ana', 'password': pass},
      <String, Object?>{},
    ]) {
      final h = await cabeceras('http://localhost:5000', cuerpo);
      expect(h['access-control-allow-origin'], 'http://localhost:5000', reason: '$cuerpo');
    }
    // Un origen no permitido no recibe el permiso.
    final ajeno = await cabeceras('http://malo.com', {'nametag': 'Ana', 'password': pass});
    expect(ajeno['access-control-allow-origin'], isNull);
  });

  test('con HTTPS obligatorio rechaza peticiones HTTP', () async {
    await parar();
    await arrancar(requireHttps: true);
    expect((await api('GET', '/health')).status, 400);
  });

  test('la configuración exige un JWT_SECRET largo', () {
    expect(() => cargarConfig({}), throwsA(isA<ConfigInvalida>()));
    expect(() => cargarConfig({'JWT_SECRET': 'corto'}), throwsA(isA<ConfigInvalida>()));
  });

  test('autenticarToken (para el servidor de partidas)', () async {
    final s = (await registrar()).json;
    expect(app.autenticarToken(s['accessToken'])?.nametag, 'Ana');
    expect(app.autenticarToken('basura'), isNull);
    expect(app.autenticarToken(null), isNull);
    expect(app.autenticarToken(s['refreshToken']), isNull);

    await api('POST', '/account/delete', body: {'password': pass}, token: s['accessToken']);
    expect(app.autenticarToken(s['accessToken']), isNull); // cuenta borrada
  });

  test('una base de datos con el esquema antiguo (correo) se reinicia sola', () {
    final dir = Directory.systemTemp.createTempSync('brilliant-');
    final archivo = '${dir.path}/vieja.db';
    final vieja = sqlite3.open(archivo);
    vieja.execute('''CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE,
      nombre TEXT NOT NULL, password_hash TEXT NOT NULL, created_at INTEGER NOT NULL);
      INSERT INTO users VALUES ('1', 'a@b.co', 'Ana', 'x', 1);''');
    vieja.close();

    final nueva = abrirDb(archivo);
    final columnas = nueva.select('PRAGMA table_info(users)').map((c) => c['name']).toList();
    expect(columnas, contains('nametag'));
    expect(columnas, isNot(contains('email')));
    expect(nueva.select('SELECT COUNT(*) c FROM users').first['c'], 0);
    nueva.close();
    dir.deleteSync(recursive: true);
  });

  test('verifica contraseñas guardadas por el servidor anterior (Node)', () async {
    // Hashes generados con el paquete `argon2` de Node (m=1024, t=1, p=1).
    final s = Seguridad(config);
    const deNode =
        r'$argon2id$v=19$m=1024,p=1,t=1$voGAkgaPoqUd4hXo0vYeGQ$lF1CwjrzN/dXtc92WRrN410O7sHZxJx+H/vjfD3ke/k';
    expect(await s.verificarPassword(deNode, 'hola-123'), isTrue);
    expect(await s.verificarPassword(deNode, 'hola-124'), isFalse);
    expect(await s.verificarPassword('basura', 'hola-123'), isFalse);

    final conPepper = Seguridad(cargarConfig({'JWT_SECRET': secret, 'PASSWORD_PEPPER': 'pimienta'}));
    const deNodePepper =
        r'$argon2id$v=19$m=1024,p=1,t=1$sVniJeSUS7Pl8ZfO0NPgjw$hJT0P8mpQaH+5qKMw0mGLNAYwr79iD8aX+KpNfjOSXI';
    expect(await conPepper.verificarPassword(deNodePepper, 'hola-123'), isTrue);
    expect(await s.verificarPassword(deNodePepper, 'hola-123'), isFalse);
  });

  group('una sola sesión por cuenta', () {
    test('si la otra sesión ya no está en uso, entrar la cierra al instante', () async {
      final s1 = (await registrar()).json;
      final s2 = (await entrar()).json;

      // El access token viejo deja de servir aunque no haya vencido, y dice por qué.
      final me = await api('GET', '/account/me', token: s1['accessToken']);
      expect(me.status, 401);
      expect(me.json['error']['code'], 'sesion_reemplazada');

      final r = await api('POST', '/auth/refresh', body: {'refreshToken': s1['refreshToken']});
      expect(r.status, 401);
      expect(r.json['error']['code'], 'sesion_reemplazada');

      // La sesión nueva funciona y se puede renovar.
      expect((await api('GET', '/account/me', token: s2['accessToken'])).status, 200);
      final r2 = await api('POST', '/auth/refresh', body: {'refreshToken': s2['refreshToken']});
      expect(r2.status, 200);
      expect((await api('GET', '/account/me', token: r2.json['accessToken'])).status, 200);
    });

    test('cerrar sesión invalida también el access token al instante', () async {
      final s = (await registrar()).json;
      await api('POST', '/auth/logout', body: {'refreshToken': s['refreshToken']});
      final me = await api('GET', '/account/me', token: s['accessToken']);
      expect(me.status, 401);
      expect(me.json['error']['code'], 'no_autenticado');
    });

    test('avisa al multijugador de qué usuario cerró sesiones', () async {
      final avisados = <String>[];
      app.alCerrarSesiones = avisados.add;
      final s = (await registrar()).json;
      final id = s['user']['id'] as String;
      expect(avisados, isEmpty, reason: 'registrarse no cierra nada');
      final s2 = (await entrar()).json;
      await api('POST', '/auth/logout-all', token: s2['accessToken']);
      expect(avisados, [id, id]);
    });

    test('una base sin la columna revoke_reason se actualiza sola', () {
      final dir = Directory.systemTemp.createTempSync('brilliant-');
      final archivo = '${dir.path}/v1.db';
      final vieja = sqlite3.open(archivo);
      vieja.execute('''CREATE TABLE users (id TEXT PRIMARY KEY, nametag TEXT NOT NULL,
        nametag_lower TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, created_at INTEGER NOT NULL);
        CREATE TABLE refresh_tokens (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
        family_id TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, expires_at INTEGER NOT NULL,
        used_at INTEGER, revoked_at INTEGER, created_at INTEGER NOT NULL);
        INSERT INTO users VALUES ('u1', 'Ana', 'ana', 'x', 1);''');
      vieja.close();
      final nueva = abrirDb(archivo);
      final cols = nueva.select('PRAGMA table_info(refresh_tokens)').map((c) => c['name']);
      expect(cols, contains('revoke_reason'));
      expect(nueva.select('SELECT COUNT(*) c FROM users').first['c'], 1, reason: 'no se pierden cuentas');
      nueva.close();
      dir.deleteSync(recursive: true);
    });
  });

  group('no se puede entrar si la cuenta está en uso en otro dispositivo', () {
    test('con la otra sesión activa, el login se rechaza (409) y la otra sigue', () async {
      final s1 = (await registrar()).json;
      final r = await api('POST', '/auth/login', body: {'nametag': 'Ana', 'password': pass});
      expect(r.status, 409);
      expect(r.json['error']['code'], 'sesion_activa');
      expect(r.json['error']['message'], contains('otro dispositivo'));
      expect(r.headers['retry-after'], isNotNull);
      expect((await api('GET', '/account/me', token: s1['accessToken'])).status, 200,
          reason: 'la sesión abierta no se toca');
      expect(contar('refresh_tokens'), 1, reason: 'no se creó otra sesión');
    });

    test('con contraseña incorrecta no revela que la cuenta está conectada', () async {
      await registrar();
      final r = await api('POST', '/auth/login', body: {'nametag': 'Ana', 'password': 'otra-clave-123'});
      expect(r.status, 401);
      expect(r.json['error']['code'], 'credenciales_invalidas');
    });

    test('usar la app mantiene la sesión en uso', () async {
      final s1 = (await registrar()).json;
      envejecerSesiones();
      // La app avisa cada minuto (GET /account/me): vuelve a estar en uso.
      await api('GET', '/account/me', token: s1['accessToken']);
      final r = await api('POST', '/auth/login', body: {'nametag': 'Ana', 'password': pass});
      expect(r.status, 409);
    });

    test('cerrar sesión libera la cuenta al instante', () async {
      final s1 = (await registrar()).json;
      await api('POST', '/auth/logout', body: {'refreshToken': s1['refreshToken']});
      final r = await api('POST', '/auth/login', body: {'nametag': 'Ana', 'password': pass});
      expect(r.status, 200);
    });

    test('si el otro dispositivo se cerró sin salir, se libera sola', () async {
      final s1 = (await registrar()).json;
      envejecerSesiones(); // pasaron más de 2,5 min sin señales de vida
      final r = await api('POST', '/auth/login', body: {'nametag': 'Ana', 'password': pass});
      expect(r.status, 200);
      final viejo = await api('GET', '/account/me', token: s1['accessToken']);
      expect(viejo.json['error']['code'], 'sesion_reemplazada');
    });

    test('con el multijugador abierto la cuenta está en uso', () async {
      await registrar();
      envejecerSesiones();
      app.tieneConexionAbierta = (_) => true;
      final r = await api('POST', '/auth/login', body: {'nametag': 'Ana', 'password': pass});
      expect(r.status, 409);
    });

    test('otra cuenta no se ve afectada', () async {
      await registrar('Ana');
      await registrar('Beto');
      envejecerSesiones();
      db.execute("UPDATE refresh_tokens SET last_seen_at = ? WHERE user_id = (SELECT id FROM users WHERE nametag = 'Ana')",
          [DateTime.now().millisecondsSinceEpoch ~/ 1000]);
      final beto = await api('POST', '/auth/login', body: {'nametag': 'Beto', 'password': pass});
      expect(beto.status, 200, reason: 'Ana en uso no bloquea a Beto');
    });
  });
}

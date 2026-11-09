import 'dart:async';
import 'dart:io';

import 'package:brilliant_server/brilliant_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Lee `.env` si existe. Las variables de entorno reales tienen prioridad.
Map<String, String> _cargarEnv() {
  final valores = <String, String>{};
  final archivo = File('.env');
  if (archivo.existsSync()) {
    for (final linea in archivo.readAsLinesSync()) {
      final l = linea.trim();
      if (l.isEmpty || l.startsWith('#')) continue;
      final i = l.indexOf('=');
      if (i <= 0) continue;
      var v = l.substring(i + 1).trim();
      if (v.length >= 2 &&
          ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) {
        v = v.substring(1, v.length - 1);
      }
      valores[l.substring(0, i).trim()] = v;
    }
  }
  return {...valores, ...Platform.environment};
}

Future<void> main() async {
  final env = _cargarEnv();
  final Config config;
  try {
    config = cargarConfig(env);
  } on ConfigInvalida catch (e) {
    stderr.writeln('Configuración inválida: $e');
    exit(1);
  }

  final db = abrirDb(config.dbPath);
  final app = AppAuth(config: config, db: db);
  final ws = ServidorWs(
    lobby: Lobby(config: ConfigMultijugador.desdeEnv(env)),
    autenticar: app.autenticarSesion,
    sesionActiva: app.sesionActiva,
  );
  app
    ..webSocket = ws.handler
    ..alCerrarSesiones = ws.revisarSesiones
    ..tieneConexionAbierta = ws.tieneConexion;

  final timer = Timer.periodic(const Duration(hours: 1), (_) => app.limpiar());

  // anyIPv6 sin v6Only acepta IPv6 *e* IPv4. Hace falta porque en Windows
  // "localhost" se resuelve primero como ::1 (IPv6): con solo IPv4 la app no
  // encuentra el servidor.
  final server = await shelf_io.serve(
    app.handler,
    InternetAddress.anyIPv6,
    config.puerto,
    poweredByHeader: null, // no anunciar la tecnología del servidor
  );
  print('Servidor Brilliant escuchando en el puerto ${server.port}');
  if (!config.requireHttps) {
    print('AVISO: HTTPS no es obligatorio. Úsalo solo en desarrollo.');
  }

  Future<void> apagar() async {
    timer.cancel();
    ws.cerrar();
    await server.close();
    db.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => apagar());
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen((_) => apagar());
}

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

int? _entero(String? v) => v == null ? null : int.tryParse(v.trim());

/// IPv4 de esta PC en la red local (sin 127.x ni 169.254.x).
Future<List<String>> _ipsLocales() async {
  final ips = <String>[];
  try {
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in i.addresses) {
        if (!a.isLoopback && !a.isLinkLocal) ips.add(a.address);
      }
    }
  } catch (_) {
    // Sin acceso a las interfaces de red: solo localhost.
  }
  return ips;
}

/// Muestra dónde abrir el juego: en esta PC y desde otras PCs de la red.
/// [puertoJuego] es el puerto donde se sirve la app web (GAME_PORT, 5000).
void _imprimirLinks(List<String> ips, int puertoJuego) {
  final linea = '=' * 60;
  print('');
  print(linea);
  print('  Jugar en esta PC:   http://localhost:$puertoJuego');
  if (ips.isEmpty) {
    print('  No hay conexión de red: solo se puede jugar en esta PC.');
  } else {
    print('  Otros jugadores (misma red Wi-Fi o cable):');
    for (final ip in ips) {
      print('                      http://$ip:$puertoJuego');
    }
  }
  print(linea);
  print('');
}

Future<void> main() async {
  final env = _cargarEnv();

  // Permitir (CORS) el juego abierto desde esta PC y desde sus IPs de red,
  // para que otros jugadores de la red puedan entrar sin editar el .env.
  final puertoJuego = _entero(env['GAME_PORT']) ?? 5000;
  final ips = await _ipsLocales();
  env['CORS_ORIGINS'] = {
    ...(env['CORS_ORIGINS'] ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
    'http://localhost:$puertoJuego',
    for (final ip in ips) 'http://$ip:$puertoJuego',
  }.join(',');

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
  _imprimirLinks(ips, puertoJuego);
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

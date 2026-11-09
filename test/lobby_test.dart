import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:brilliant_server/brilliant_server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

const secret = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
const gracia = Duration(milliseconds: 400);

late HttpServer server;
late AppAuth app;
late Lobby lobby;
late ServidorWs servidorWs;
final _tokens = <String, String>{};

typedef Msg = Map<String, dynamic>;

/// Cliente WebSocket de prueba.
class Cliente {
  final IOWebSocketChannel ws;
  final StreamQueue<Msg> _cola;
  Cliente._(this.ws)
    : _cola = StreamQueue(ws.stream.map((d) => jsonDecode(d as String) as Msg));

  static Future<Cliente> abrir() async {
    final ws = IOWebSocketChannel.connect('ws://127.0.0.1:${server.port}/ws');
    await ws.ready;
    return Cliente._(ws);
  }

  /// Se conecta y se autentica como [nametag] (lo registra si hace falta).
  static Future<Cliente> de(String nametag) async {
    final c = await abrir();
    c.enviar({'tipo': 'auth', 'token': await token(nametag)});
    await c.esperar('autenticado');
    return c;
  }

  void enviar(Map<String, Object?> m) => ws.sink.add(jsonEncode(m));

  /// Siguiente mensaje que cumpla [cond] (descarta los anteriores).
  Future<Msg> esperarQue(bool Function(Msg m) cond, {String que = 'mensaje'}) async {
    return Future(() async {
      while (true) {
        final m = await _cola.next;
        if (cond(m)) return m;
      }
    }).timeout(const Duration(seconds: 3), onTimeout: () => fail('No llegó: $que'));
  }

  Future<Msg> esperar(String tipo) => esperarQue((m) => m['tipo'] == tipo, que: tipo);

  Future<Msg> esperarError(String code) =>
      esperarQue((m) => m['tipo'] == 'error' && m['code'] == code, que: 'error $code');

  /// Espera un estado de sala que cumpla [cond].
  Future<Msg> esperarSala(bool Function(Msg sala) cond, {String que = 'sala'}) async =>
      (await esperarQue(
        (m) => (m['tipo'] == 'sala' || m['tipo'] == 'partida_iniciada') && cond(m['sala'] as Msg),
        que: que,
      ))['sala'] as Msg;

  /// Espera a que el servidor cierre la conexión y devuelve el código.
  Future<int?> esperarCierre() async {
    await Future(() async {
      while (await _cola.hasNext) {
        await _cola.next;
      }
    }).timeout(const Duration(seconds: 3), onTimeout: () => fail('No se cerró'));
    return ws.closeCode;
  }

  Future<void> cerrar() => ws.sink.close();
}

Future<String> token(String nametag) async {
  final ya = _tokens[nametag];
  if (ya != null) return ya;
  final res = await http.post(
    Uri.parse('http://127.0.0.1:${server.port}/auth/register'),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({'nametag': nametag, 'password': 'clave-larga-123'}),
  );
  expect(res.statusCode, 201, reason: res.body);
  return _tokens[nametag] = jsonDecode(res.body)['accessToken'] as String;
}

List<Msg> jugadores(Msg sala) => (sala['jugadores'] as List).cast<Msg>();
Msg jugador(Msg sala, String nametag) =>
    jugadores(sala).firstWhere((j) => j['nametag'] == nametag, orElse: () => {});

/// Crea una sala con [anfitrion] y une a [otros]. Devuelve el código.
Future<String> salaCon(Cliente anfitrion, List<Cliente> otros, {int nivel = 1}) async {
  anfitrion.enviar({'tipo': 'crear_sala', 'nivel': nivel});
  final codigo = (await anfitrion.esperarSala((_) => true))['codigo'] as String;
  for (final o in otros) {
    o.enviar({'tipo': 'unirse', 'codigo': codigo, 'nivel': nivel});
    await o.esperarSala((s) => s['codigo'] == codigo);
  }
  return codigo;
}

void main() {
  setUp(() async {
    _tokens.clear();
    final config = cargarConfig({'JWT_SECRET': secret}).copyWith(
      argon2: const ParametrosArgon2(memoriaKiB: 1024, iteraciones: 1, paralelismo: 1),
      limiteGlobal: 100000,
      limiteAuth: 100000,
    );
    app = AppAuth(config: config, db: abrirDb(':memory:'));
    lobby = Lobby(
      config: const ConfigMultijugador(
        graciaReconexion: gracia,
        tiempoAuth: Duration(milliseconds: 400),
        maxMensajesPorSegundo: 20,
      ),
    );
    servidorWs = ServidorWs(
      lobby: lobby,
      autenticar: app.autenticarSesion,
      sesionActiva: app.sesionActiva,
    );
    app
      ..webSocket = servidorWs.handler
      ..alCerrarSesiones = servidorWs.revisarSesiones;
    server = await shelf_io.serve(app.handler, '127.0.0.1', 0, poweredByHeader: null);
  });

  tearDown(() async {
    servidorWs.cerrar();
    await server.close(force: true);
    app.db.close();
  });

  group('autenticación', () {
    test('token inválido: error y cierre 4001', () async {
      final c = await Cliente.abrir();
      c.enviar({'tipo': 'auth', 'token': 'basura'});
      await c.esperarError('no_autenticado');
      expect(await c.esperarCierre(), CodigoCierre.noAutenticado);
    });

    test('mandar otra cosa antes de autenticarse: cierre 4001', () async {
      final c = await Cliente.abrir();
      c.enviar({'tipo': 'crear_sala', 'nivel': 1});
      expect(await c.esperarCierre(), CodigoCierre.noAutenticado);
    });

    test('no autenticarse a tiempo: cierre 4001', () async {
      final c = await Cliente.abrir();
      expect(await c.esperarCierre(), CodigoCierre.noAutenticado);
    });

    test('autenticado devuelve el usuario y sala null', () async {
      final c = await Cliente.abrir();
      c.enviar({'tipo': 'auth', 'token': await token('Ana')});
      final m = await c.esperar('autenticado');
      expect(m['user']['nametag'], 'Ana');
      expect(m['sala'], isNull);
    });
  });

  group('lobby', () {
    test('unirse solo con el código: juega el mapa de quien creó la sala', () async {
      final ana = await Cliente.de('Ana');
      final beto = await Cliente.de('Beto');
      ana.enviar({'tipo': 'crear_sala', 'nivel': 3});
      final codigo = (await ana.esperarSala((_) => true))['codigo'] as String;

      beto.enviar({'tipo': 'unirse', 'codigo': codigo});
      final s = await beto.esperarSala((s) => jugadores(s).length == 2);
      expect(jugador(s, 'Beto')['nivel'], 3);

      // Un mapa inválido sí es un error (no se ignora).
      final carla = await Cliente.de('Carla');
      carla.enviar({'tipo': 'unirse', 'codigo': codigo, 'nivel': 99});
      await carla.esperarError('mapa_invalido');
    });

    test('crear sala y unirse con el código (sin importar mayúsculas)', () async {
      final ana = await Cliente.de('Ana');
      final beto = await Cliente.de('Beto');

      ana.enviar({'tipo': 'crear_sala', 'nivel': 2});
      final creada = await ana.esperarSala((_) => true);
      final codigo = creada['codigo'] as String;
      expect(codigo, matches(formatoCodigo));
      expect(creada['estado'], 'lobby');
      expect(creada['minJugadores'], 2);
      expect(creada['maxJugadores'], 6);
      expect(jugadores(creada).single, {
        'id': isA<String>(),
        'nametag': 'Ana',
        'nivel': 2,
        'listo': false,
        'conectado': true,
      });

      beto.enviar({'tipo': 'unirse', 'codigo': ' ${codigo.toLowerCase()} ', 'nivel': 3});
      for (final c in [ana, beto]) {
        final s = await c.esperarSala((s) => jugadores(s).length == 2);
        expect(jugador(s, 'Beto')['nivel'], 3);
        expect(jugador(s, 'Ana')['nivel'], 2);
      }
    });

    test('errores: código inexistente, mapa inválido, ya en sala, sin sala', () async {
      final ana = await Cliente.de('Ana');
      ana.enviar({'tipo': 'unirse', 'codigo': 'ZZZZZZ', 'nivel': 1});
      await ana.esperarError('sala_no_encontrada');
      ana.enviar({'tipo': 'unirse', 'codigo': '<script>', 'nivel': 1});
      await ana.esperarError('sala_no_encontrada');
      ana.enviar({'tipo': 'listo', 'listo': true});
      await ana.esperarError('no_en_sala');
      for (final nivel in [0, 99, '1', null]) {
        ana.enviar({'tipo': 'crear_sala', 'nivel': nivel});
        await ana.esperarError('mapa_invalido');
      }
      ana.enviar({'tipo': 'crear_sala', 'nivel': 1});
      await ana.esperarSala((_) => true);
      ana.enviar({'tipo': 'crear_sala', 'nivel': 1});
      final e = await ana.esperarError('ya_en_sala');
      expect(e['en'], 'crear_sala');
      ana.enviar({'tipo': 'listo'});
      await ana.esperarError('mensaje_invalido');
      ana.enviar({'tipo': 'volar'});
      await ana.esperarError('mensaje_desconocido');
      ana.enviar({'tipo': 'ping'});
      await ana.esperar('pong');
    });

    test('máximo 6 jugadores', () async {
      final clientes = [for (var i = 1; i <= 7; i++) await Cliente.de('Jugador$i')];
      final codigo = await salaCon(clientes.first, clientes.sublist(1, 6));
      expect(lobby.sala(codigo)!.jugadores, hasLength(6));

      clientes.last.enviar({'tipo': 'unirse', 'codigo': codigo, 'nivel': 1});
      await clientes.last.esperarError('sala_llena');
    });

    test('empieza solo cuando hay 2+ y todos están listos', () async {
      final ana = await Cliente.de('Ana');
      final beto = await Cliente.de('Beto');
      ana.enviar({'tipo': 'crear_sala', 'nivel': 1});
      final codigo = (await ana.esperarSala((_) => true))['codigo'] as String;

      // Solo con 1 jugador no empieza aunque esté listo.
      ana.enviar({'tipo': 'listo', 'listo': true});
      await ana.esperarSala((s) => jugador(s, 'Ana')['listo'] == true);
      expect(lobby.sala(codigo)!.estado, EstadoSala.lobby);

      beto.enviar({'tipo': 'unirse', 'codigo': codigo, 'nivel': 4});
      await beto.esperarSala((s) => jugadores(s).length == 2);

      // Cambiar de mapa quita el "listo".
      ana.enviar({'tipo': 'elegir_mapa', 'nivel': 3});
      final s = await ana.esperarSala((s) => jugador(s, 'Ana')['nivel'] == 3);
      expect(jugador(s, 'Ana')['listo'], isFalse);

      ana.enviar({'tipo': 'listo', 'listo': true});
      beto.enviar({'tipo': 'listo', 'listo': true});
      for (final c in [ana, beto]) {
        final inicio = await c.esperar('partida_iniciada');
        expect(inicio['sala']['estado'], 'jugando');
      }

      // Ya no se puede entrar ni cambiar de mapa.
      final carla = await Cliente.de('Carla');
      carla.enviar({'tipo': 'unirse', 'codigo': codigo, 'nivel': 1});
      await carla.esperarError('partida_en_curso');
      ana.enviar({'tipo': 'elegir_mapa', 'nivel': 2});
      await ana.esperarError('partida_en_curso');
    });

    test('si el único que faltaba sale, los demás empiezan', () async {
      final ana = await Cliente.de('Ana');
      final beto = await Cliente.de('Beto');
      final carla = await Cliente.de('Carla');
      await salaCon(ana, [beto, carla]);
      ana.enviar({'tipo': 'listo', 'listo': true});
      beto.enviar({'tipo': 'listo', 'listo': true});
      await ana.esperarSala((s) => jugador(s, 'Beto')['listo'] == true);

      carla.enviar({'tipo': 'salir'});
      await carla.esperar('saliste');
      final inicio = await ana.esperar('partida_iniciada');
      expect(jugadores(inicio['sala']).map((j) => j['nametag']), ['Ana', 'Beto']);
    });

    test('salir: la sala se actualiza y desaparece al quedar vacía', () async {
      final ana = await Cliente.de('Ana');
      final beto = await Cliente.de('Beto');
      final codigo = await salaCon(ana, [beto]);

      ana.enviar({'tipo': 'salir'});
      await ana.esperar('saliste');
      final m = await beto.esperarQue((m) => m['evento']?['tipo'] == 'salio', que: 'evento salio');
      expect(m['evento']['nametag'], 'Ana');
      expect(jugadores(m['sala']).single['nametag'], 'Beto');

      beto.enviar({'tipo': 'salir'});
      await beto.esperar('saliste');
      expect(lobby.sala(codigo), isNull);
      expect(lobby.cantidadSalas, 0);

      // Ya fuera, puede crear otra.
      ana.enviar({'tipo': 'crear_sala', 'nivel': 1});
      await ana.esperarSala((_) => true);
    });
  });

  group('desconexiones en el lobby', () {
    test('se cae y vuelve a tiempo: recupera su lugar', () async {
      final ana = await Cliente.de('Ana');
      var beto = await Cliente.de('Beto');
      final codigo = await salaCon(ana, [beto]);
      beto.enviar({'tipo': 'listo', 'listo': true});
      await ana.esperarSala((s) => jugador(s, 'Beto')['listo'] == true);

      await beto.cerrar();
      final caido = await ana.esperarSala((s) => jugador(s, 'Beto')['conectado'] == false);
      expect(jugador(caido, 'Beto')['listo'], isFalse, reason: 'pierde el listo al caerse');

      beto = await Cliente.abrir();
      beto.enviar({'tipo': 'auth', 'token': await token('Beto')});
      final auth = await beto.esperar('autenticado');
      expect(auth['sala']['codigo'], codigo, reason: 'vuelve directo a su sala');

      final m = await ana.esperarQue((m) => m['evento']?['tipo'] == 'reconectado', que: 'reconectado');
      expect(jugador(m['sala'], 'Beto')['conectado'], isTrue);

      // Pasada la gracia sigue en la sala.
      await Future<void>.delayed(gracia * 1.5);
      expect(lobby.sala(codigo)!.jugadores, hasLength(2));
    });

    test('no vuelve a tiempo: sale de la sala; si era el último, la sala se borra', () async {
      final ana = await Cliente.de('Ana');
      final beto = await Cliente.de('Beto');
      final codigo = await salaCon(ana, [beto]);

      await beto.cerrar();
      final m = await ana.esperarQue((m) => m['evento']?['tipo'] == 'abandono', que: 'abandono');
      expect(m['evento']['nametag'], 'Beto');
      expect(jugadores(m['sala']).map((j) => j['nametag']), ['Ana']);

      await ana.cerrar();
      await Future<void>.delayed(gracia * 1.5);
      expect(lobby.sala(codigo), isNull);
    });

    test('nadie empieza mientras alguien está desconectado', () async {
      final ana = await Cliente.de('Ana');
      final beto = await Cliente.de('Beto');
      final carla = await Cliente.de('Carla');
      final codigo = await salaCon(ana, [beto, carla]);
      await carla.cerrar();
      await ana.esperarSala((s) => jugador(s, 'Carla')['conectado'] == false);

      ana.enviar({'tipo': 'listo', 'listo': true});
      beto.enviar({'tipo': 'listo', 'listo': true});
      await ana.esperarSala((s) => jugador(s, 'Beto')['listo'] == true);
      expect(lobby.sala(codigo)!.estado, EstadoSala.lobby);
    });

    test('abrir otra conexión con la misma cuenta cierra la vieja (4002)', () async {
      final ana = await Cliente.de('Ana');
      final beto1 = await Cliente.de('Beto');
      final codigo = await salaCon(ana, [beto1]);

      final beto2 = await Cliente.abrir();
      beto2.enviar({'tipo': 'auth', 'token': await token('Beto')});
      expect((await beto2.esperar('autenticado'))['sala']['codigo'], codigo);

      await beto1.esperarError('sesion_reemplazada');
      expect(await beto1.esperarCierre(), CodigoCierre.sesionReemplazada);

      // El cierre de la vieja no lo marca como desconectado.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(lobby.sala(codigo)!.jugador(lobby.sala(codigo)!.jugadores[1].id)!.conectado, isTrue);
      beto2.enviar({'tipo': 'listo', 'listo': true});
      await ana.esperarSala((s) => jugador(s, 'Beto')['listo'] == true);
    });
  });

  group('mensajes malos', () {
    test('JSON inválido: error pero la conexión sigue', () async {
      final ana = await Cliente.de('Ana');
      ana.ws.sink.add('{no es json');
      await ana.esperarError('mensaje_invalido');
      ana.ws.sink.add('[1,2]');
      await ana.esperarError('mensaje_invalido');
      ana.enviar({'tipo': 'ping'});
      await ana.esperar('pong');
    });

    test('mensaje enorme o binario: cierre 4003', () async {
      final ana = await Cliente.de('Ana');
      ana.enviar({'tipo': 'ping', 'relleno': 'x' * 5000});
      expect(await ana.esperarCierre(), CodigoCierre.protocolo);

      final beto = await Cliente.de('Beto');
      beto.ws.sink.add([1, 2, 3]);
      expect(await beto.esperarCierre(), CodigoCierre.protocolo);
    });

    test('demasiados mensajes por segundo: cierre 4003', () async {
      final ana = await Cliente.de('Ana');
      for (var i = 0; i < 30; i++) {
        ana.enviar({'tipo': 'ping'});
      }
      expect(await ana.esperarCierre(), CodigoCierre.protocolo);
    });
  });

  partidaPorWebSocket();
  sesionUnica();
}

/// Iniciales válidos del nivel 1.
const iniciales1 = [[0, 2, 1], [1, 5, 2], [3, 1, 3], [3, 4, 4], [5, 2, 5], [6, 4, 6]];

/// Espera un estado de partida que cumpla [cond].
Future<Msg> esperarPartida(Cliente c, bool Function(Msg p) cond, {String que = 'partida'}) async =>
    (await c.esperarQue((m) => m['tipo'] == 'partida' && cond(m['partida'] as Msg), que: que))['partida']
        as Msg;

Msg jugadorP(Msg partida, String nametag) => (partida['jugadores'] as List)
    .cast<Msg>()
    .firstWhere((j) => j['nametag'] == nametag, orElse: () => {});

/// Sala con [clientes] (nivel 1), todos listos y con sus iniciales puestos.
/// Devuelve el código; la partida queda en la ronda 1.
Future<String> partidaEnRonda1(List<Cliente> clientes) async {
  final codigo = await salaCon(clientes.first, clientes.sublist(1));
  for (final c in clientes) {
    c.enviar({'tipo': 'listo', 'listo': true});
  }
  for (final c in clientes) {
    await esperarPartida(c, (p) => p['fase'] == 'iniciales');
    c.enviar({'tipo': 'iniciales', 'valores': iniciales1});
  }
  for (final c in clientes) {
    await esperarPartida(c, (p) => p['fase'] == 'jugando' && p['ronda'] == 1);
  }
  return codigo;
}

void partidaPorWebSocket() {
  group('partida', () {
    test('flujo completo: iniciales, rondas, conceder y vuelta al lobby', () async {
      final ana = await Cliente.de('Ana');
      final beto = await Cliente.de('Beto');
      final codigo = await partidaEnRonda1([ana, beto]);

      final p = lobby.sala(codigo)!.partida!;
      expect(p.dados, hasLength(2));
      expect(jugadorP(p.toJson().cast(), 'Ana')['celdas'], hasLength(6));

      // Jugada inválida: error solo para quien la mandó.
      ana.enviar({'tipo': 'jugada', 'ancla': [0, 0], 'destino': [0, 1]});
      await ana.esperarError('jugada_invalida');

      ana.enviar({'tipo': 'pasar'});
      beto.enviar({'tipo': 'pasar'});
      await esperarPartida(ana, (p) => p['ronda'] == 2, que: 'ronda 2');

      ana.enviar({'tipo': 'conceder'});
      for (final c in [ana, beto]) {
        final fin = await c.esperar('partida_terminada');
        expect(fin['motivo'], 'rendicion');
        expect((fin['resultados'] as List).first['nametag'], 'Beto');
        // La sala vuelve al lobby para la revancha, sin nadie listo.
        final s = await c.esperarSala((s) => s['estado'] == 'lobby');
        expect(jugadores(s).every((j) => j['listo'] == false), isTrue);
      }
      expect(lobby.sala(codigo)!.partida, isNull);
    });

    test('mensajes de juego sin partida', () async {
      final ana = await Cliente.de('Ana');
      ana.enviar({'tipo': 'pasar'});
      await ana.esperarError('sin_partida');
      ana.enviar({'tipo': 'crear_sala', 'nivel': 1});
      await ana.esperarSala((_) => true);
      ana.enviar({'tipo': 'conceder'});
      await ana.esperarError('sin_partida');
    });

    test('se cae en plena partida: no frena a nadie y al volver sigue donde iba', () async {
      final ana = await Cliente.de('Ana');
      var beto = await Cliente.de('Beto');
      final codigo = await partidaEnRonda1([ana, beto]);

      await beto.cerrar();
      await esperarPartida(ana, (p) => jugadorP(p, 'Beto')['conectado'] == false);

      ana.enviar({'tipo': 'pasar'});
      await esperarPartida(ana, (p) => p['ronda'] == 2, que: 'avanza sin Beto');

      beto = await Cliente.abrir();
      beto.enviar({'tipo': 'auth', 'token': await token('Beto')});
      final auth = await beto.esperar('autenticado');
      expect(auth['sala']['estado'], 'jugando');
      final estado = await esperarPartida(beto, (p) => jugadorP(p, 'Beto')['conectado'] == true);
      expect(estado['ronda'], 2);
      expect(jugadorP(estado, 'Beto')['celdas'], hasLength(6), reason: 'conserva su tablero');
      expect(lobby.sala(codigo)!.partida!.jugador(lobby.sala(codigo)!.jugadores[1].id)!.activo, isTrue);

      // Puede seguir jugando.
      beto.enviar({'tipo': 'pasar'});
      ana.enviar({'tipo': 'pasar'});
      await esperarPartida(beto, (p) => p['ronda'] == 3, que: 'ronda 3');
    });

    test('si no vuelve a tiempo cuenta como abandono y gana el otro', () async {
      final ana = await Cliente.de('Ana');
      final beto = await Cliente.de('Beto');
      final codigo = await partidaEnRonda1([ana, beto]);

      await beto.cerrar();
      final fin = await ana.esperar('partida_terminada');
      expect(fin['motivo'], 'abandono');
      final res = (fin['resultados'] as List).cast<Msg>();
      expect(res.map((r) => [r['nametag'], r['posicion'], r['estado']]), [
        ['Ana', 1, 'jugando'],
        ['Beto', 2, 'abandono'],
      ]);
      final s = await ana.esperarSala((s) => jugadores(s).length == 1);
      expect(s['estado'], 'lobby');
      expect(lobby.sala(codigo)!.jugadores.single.nametag, 'Ana');
    });

    test('con 3 jugadores, si uno abandona los demás siguen', () async {
      final ana = await Cliente.de('Ana');
      final beto = await Cliente.de('Beto');
      final carla = await Cliente.de('Carla');
      final codigo = await partidaEnRonda1([ana, beto, carla]);

      await carla.cerrar();
      await esperarPartida(ana, (p) => jugadorP(p, 'Carla')['estado'] == 'abandono', que: 'abandono');
      expect(lobby.sala(codigo)!.partida!.fase, FasePartida.jugando);
    });

    test('salir de la sala en plena partida es conceder', () async {
      final ana = await Cliente.de('Ana');
      final beto = await Cliente.de('Beto');
      await partidaEnRonda1([ana, beto]);

      beto.enviar({'tipo': 'salir'});
      await beto.esperar('saliste');
      final fin = await ana.esperar('partida_terminada');
      expect(fin['motivo'], 'rendicion');
      expect((fin['resultados'] as List).last, containsPair('estado', 'concedio'));
    });
  });
}

/// Intenta iniciar sesión con [nametag] (ya registrado).
Future<http.Response> intentarLogin(String nametag) => http.post(
  Uri.parse('http://127.0.0.1:${server.port}/auth/login'),
  headers: {'content-type': 'application/json'},
  body: jsonEncode({'nametag': nametag, 'password': 'clave-larga-123'}),
);

Future<http.Response> post(String ruta, {String? token, Object? cuerpo}) => http.post(
  Uri.parse('http://127.0.0.1:${server.port}$ruta'),
  headers: {
    'content-type': 'application/json',
    if (token != null) 'authorization': 'Bearer $token',
  },
  body: cuerpo == null ? null : jsonEncode(cuerpo),
);

/// Registra a [nametag] y devuelve su sesión completa (access y refresh).
Future<Map<String, dynamic>> registrarSesion(String nametag) async {
  final res = await post('/auth/register', cuerpo: {'nametag': nametag, 'password': 'clave-larga-123'});
  expect(res.statusCode, 201, reason: res.body);
  return jsonDecode(res.body) as Map<String, dynamic>;
}

Future<Cliente> conectarCon(String accessToken) async {
  final c = await Cliente.abrir();
  c.enviar({'tipo': 'auth', 'token': accessToken});
  await c.esperar('autenticado');
  return c;
}

void sesionUnica() {
  group('una sola sesión por cuenta', () {
    test('con el multijugador abierto no se puede entrar en otro dispositivo', () async {
      final ana = await Cliente.de('Ana');
      final beto = await Cliente.de('Beto');
      await salaCon(ana, [beto]);

      final r = await intentarLogin('Ana');
      expect(r.statusCode, 409);
      expect(jsonDecode(r.body)['error']['code'], 'sesion_activa');
      ana.enviar({'tipo': 'ping'});
      await ana.esperar('pong'); // sigue conectada, sin cambios
    });

    test('si se cerró la app sin salir, se libera sola y el token viejo deja de servir', () async {
      final ana = await Cliente.de('Ana');
      await ana.cerrar();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Pasó el tiempo sin señales de vida.
      app.db.execute('UPDATE refresh_tokens SET last_seen_at = 1, created_at = 1');

      final r = await intentarLogin('Ana');
      expect(r.statusCode, 200);
      final vieja = await Cliente.abrir();
      vieja.enviar({'tipo': 'auth', 'token': await token('Ana')});
      expect(await vieja.esperarCierre(), CodigoCierre.noAutenticado);
      await conectarCon(jsonDecode(r.body)['accessToken'] as String);
    });

    test('cerrar sesión o borrar la cuenta corta la conexión (4004)', () async {
      final s = await registrarSesion('Ana');
      final ana = await conectarCon(s['accessToken'] as String);
      await post('/auth/logout', cuerpo: {'refreshToken': s['refreshToken']});
      await ana.esperarError('sesion_cerrada');
      expect(await ana.esperarCierre(), CodigoCierre.sesionCerrada);

      final c = await registrarSesion('Carla');
      final carla = await conectarCon(c['accessToken'] as String);
      await post('/account/delete', token: c['accessToken'] as String, cuerpo: {'password': 'clave-larga-123'});
      expect(await carla.esperarCierre(), CodigoCierre.sesionCerrada);
    });

    test('las sesiones de otros usuarios no se tocan', () async {
      final beto = await Cliente.de('Beto');
      final s = await registrarSesion('Ana');
      await conectarCon(s['accessToken'] as String);
      await post('/auth/logout', cuerpo: {'refreshToken': s['refreshToken']});
      beto.enviar({'tipo': 'ping'});
      await beto.esperar('pong');
    });
  });
}

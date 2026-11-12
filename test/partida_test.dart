import 'dart:async';
import 'dart:math';

import 'package:brilliant_reglas/brilliant_reglas.dart';
import 'package:brilliant_server/brilliant_server.dart';
import 'package:test/test.dart';

/// Random con dados fijos: cada `nextInt(6)` saca el siguiente valor - 1.
class DadosFijos implements Random {
  final List<int> valores;
  var _i = 0;
  DadosFijos(this.valores);

  @override
  int nextInt(int max) => valores[_i++ % valores.length] - 1;
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
}

/// Mapa de prueba de 1x8: las 6 primeras casillas son la zona "a" (las
/// iniciales), y luego dos zonas de una casilla, "b" y "c". Verde: 4-3-2 puntos.
final mini = Nivel(
  numero: 1,
  construirTablero: () => tableroDesdeFilas(
    {'a': TipoVerde(), 'b': TipoVerde(), 'c': TipoVerde()},
    [['a', 'a', 'a', 'a', 'a', 'a', 'b', 'c']],
  ),
  casillasIniciales: {for (var c = 0; c < 6; c++) Coordenada(0, c)},
);

/// Iniciales del mapa mini: 1..6 de izquierda a derecha (la casilla 5 tiene un 6).
final inicialesMini = [for (var c = 0; c < 6; c++) [0, c, c + 1]];

/// Iniciales válidos del nivel 1.
final iniciales1 = [[0, 2, 1], [1, 5, 2], [3, 1, 3], [3, 4, 4], [5, 2, 5], [6, 4, 6]];

class Mesa {
  final mensajes = <Map<String, Object?>>[];
  Partida? terminada;
  late final Partida partida;

  Mesa(
    List<String> nombres, {
    Nivel? nivel,
    Random? random,
    ConfigPartida config = const ConfigPartida(),
  }) {
    partida = Partida(
      jugadores: [
        for (final n in nombres) JugadorPartida(id: n, nametag: n, nivel: nivel ?? nivel1),
      ],
      difundir: mensajes.add,
      alTerminar: (p) => terminada = p,
      config: config,
      random: random ?? Random(7),
    );
    partida.iniciar();
  }

  JugadorPartida j(String id) => partida.jugador(id)!;
  void enviar(String id, String tipo, [Map<String, Object?> extra = const {}]) =>
      partida.manejar(id, tipo, {'tipo': tipo, ...extra});

  Map<String, Object?> get ultimo => mensajes.last;
  Map<String, Object?>? get ultimoEvento => ultimo['evento'] as Map<String, Object?>?;

  /// Juega cualquier jugada válida, o pasa si no hay.
  void jugarOPasar(String id) {
    final jug = j(id);
    final dados = partida.dados!;
    final anclas = anclasPosibles(jug.tablero, jug.celdas, dados);
    if (anclas.isEmpty) return enviar(id, 'pasar');
    final ancla = anclas.first;
    final destino = destinosPosibles(
      jug.tablero, jug.celdas, ancla, otroDado(dados, jug.celdas[ancla]!),
    ).first;
    enviar(id, 'jugada', {
      'ancla': [ancla.fila, ancla.columna],
      'destino': [destino.fila, destino.columna],
    });
  }
}

Matcher errorProtocolo(String code) =>
    throwsA(isA<ErrorProtocolo>().having((e) => e.code, 'code', code));

void main() {
  late Mesa m;
  tearDown(() => m.partida.cancelar());

  group('números iniciales', () {
    test('valida y, cuando todos los ponen, empieza la ronda 1', () {
      m = Mesa(['ana', 'beto']);
      expect(m.partida.fase, FasePartida.iniciales);
      expect(m.ultimo['tipo'], 'partida');

      for (final malo in <Object?>[
        null,
        'x',
        [[0, 2]],
        [[0, 2, 1]], // faltan casillas
        [...iniciales1.sublist(1), [0, 2, 2]], // repetido
      ]) {
        expect(() => m.enviar('ana', 'iniciales', {'valores': malo}),
            errorProtocolo('iniciales_invalidos'));
      }
      m.enviar('ana', 'iniciales', {'valores': iniciales1});
      expect(m.j('ana').celdas, hasLength(6));
      expect(() => m.enviar('ana', 'iniciales', {'valores': iniciales1}),
          errorProtocolo('no_es_momento'));
      expect(m.partida.fase, FasePartida.iniciales);

      m.enviar('beto', 'iniciales', {'valores': iniciales1});
      expect(m.partida.fase, FasePartida.jugando);
      expect(m.partida.ronda, 1);
      expect(m.partida.dados, hasLength(2));
      expect(m.ultimoEvento!['tipo'], 'ronda');
    });

    test('si se acaba el tiempo, el servidor pone números válidos al azar', () async {
      m = Mesa(['ana', 'beto'],
          config: const ConfigPartida(tiempoIniciales: Duration(milliseconds: 50)));
      m.enviar('ana', 'iniciales', {'valores': iniciales1});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(m.partida.fase, FasePartida.jugando);
      final beto = m.j('beto');
      expect(beto.celdas, hasLength(6));
      expect(errorEnValoresIniciales(nivel1, beto.celdas), isNull);
    });
  });

  group('rondas', () {
    setUp(() {
      m = Mesa(['ana', 'beto'],
          config: const ConfigPartida(tiempoTurno: Duration(milliseconds: 80)));
      m.enviar('ana', 'iniciales', {'valores': iniciales1});
      m.enviar('beto', 'iniciales', {'valores': iniciales1});
    });

    test('jugada válida, inválida y repetida', () {
      expect(() => m.enviar('ana', 'jugada', {'ancla': [9, 9], 'destino': [0, 0]}),
          errorProtocolo('jugada_invalida'));
      expect(() => m.enviar('ana', 'jugada', {'ancla': 'x'}), errorProtocolo('jugada_invalida'));

      m.jugarOPasar('ana');
      expect(m.j('ana').yaJugo, isTrue);
      expect(() => m.enviar('ana', 'pasar'), errorProtocolo('no_es_momento'));
      expect(m.partida.ronda, 1, reason: 'falta beto');

      m.jugarOPasar('beto');
      expect(m.partida.ronda, 2);
      expect(m.j('ana').yaJugo, isFalse);
    });

    test('si se acaba el turno, los que faltan pasan', () async {
      m.enviar('ana', 'pasar');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(m.partida.ronda, greaterThanOrEqualTo(2));
      final ronda2 = m.mensajes.firstWhere(
        (x) => (x['evento'] as Map?)?['pasaronPorTiempo'] != null,
      );
      expect((ronda2['evento'] as Map)['pasaronPorTiempo'], ['beto']);
    });

    test('ni el reloj le pasa el turno al desconectado: la ronda se estira', () async {
      m.partida.cambiarConexion('beto', false, graciaSegundos: 10);
      m.enviar('ana', 'pasar');
      // Se vence el tiempo de la ronda (80 ms) mientras se espera a beto.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(m.partida.ronda, 1, reason: 'la ronda no se cierra sin beto');
      expect(m.j('beto').yaJugo, isFalse, reason: 'no se le pasa el turno');
      expect(
        m.mensajes.every((x) => (x['evento'] as Map?)?['pasaronPorTiempo'] == null),
        isTrue,
      );

      // Al volver, la ronda sigue su curso normal.
      m.partida.cambiarConexion('beto', true);
      m.enviar('beto', 'pasar');
      expect(m.partida.ronda, 2);
    });

    test('la ronda espera al desconectado: sus turnos no se pasan solos', () {
      m.partida.cambiarConexion('beto', false, graciaSegundos: 10);
      expect(m.ultimoEvento, {
        'tipo': 'desconectado',
        'nametag': 'beto',
        'graciaSegundos': 10,
      });
      m.enviar('ana', 'pasar');
      expect(m.partida.ronda, 1, reason: 'se espera a beto');

      m.partida.cambiarConexion('beto', true);
      expect(m.ultimoEvento, {'tipo': 'reconectado', 'nametag': 'beto'});
      m.enviar('beto', 'pasar');
      expect(m.partida.ronda, 2, reason: 'con beto de vuelta la ronda cierra');
    });

    test('si el desconectado no vuelve (abandono), la ronda sigue sin él', () {
      m = Mesa(['ana', 'beto', 'carla']);
      for (final n in ['ana', 'beto', 'carla']) {
        m.enviar(n, 'iniciales', {'valores': iniciales1});
      }
      m.partida.cambiarConexion('carla', false, graciaSegundos: 10);
      m.enviar('ana', 'pasar');
      m.enviar('beto', 'pasar');
      expect(m.partida.ronda, 1, reason: 'se espera a carla');

      m.partida.abandonar('carla'); // el lobby la saca al vencer la gracia
      expect(m.partida.ronda, 2, reason: 'ya nadie la espera');
      expect(m.partida.fase, FasePartida.jugando);
    });

    test('si no queda nadie conectado no se queman rondas', () {
      m.partida.cambiarConexion('ana', false);
      m.partida.cambiarConexion('beto', false);
      expect(m.partida.ronda, 1);
    });

    test('el JSON trae dados, tiempo restante y los tableros de todos', () {
      final p = m.partida.toJson();
      expect(p['fase'], 'jugando');
      expect(p['msRestantes'], inInclusiveRange(0, 80));
      final jugadores = p['jugadores'] as List;
      expect(jugadores, hasLength(2));
      expect((jugadores.first as Map)['celdas'], hasLength(6));
    });
  });

  group('puntos por lugar', () {
    test('el primero en completar una zona gana más; en la misma ronda comparten lugar', () {
      // Ronda 1: 6 y 1. Ronda 2: 6 y 2.
      m = Mesa(['ana', 'beto'], nivel: mini, random: DadosFijos([6, 1, 6, 2]));
      m.enviar('ana', 'iniciales', {'valores': inicialesMini});
      m.enviar('beto', 'iniciales', {'valores': inicialesMini});
      // La zona "a" se completó con los iniciales, a la vez: 1.er lugar los dos.
      expect(m.j('ana').lugares, {'a': 1});
      expect(m.j('beto').lugares, {'a': 1});

      // Ronda 1: ana completa "b" con el 1; beto pasa.
      m.enviar('ana', 'jugada', {'ancla': [0, 5], 'destino': [0, 6]});
      expect(m.ultimoEvento!['puntosGanados'], 4);
      expect(m.ultimoEvento!['zonas'], [
        {'zona': 'b', 'lugar': 1, 'puntos': 4},
      ]);
      m.enviar('beto', 'pasar');

      // Ronda 2: beto completa "b" después: 2.º lugar.
      m.enviar('beto', 'jugada', {'ancla': [0, 5], 'destino': [0, 6]});
      expect(m.j('beto').lugares['b'], 2);
      expect(m.j('ana').puntos, 4 + 4);
      expect(m.j('beto').puntos, 4 + 3);
    });
  });

  group('fin de la partida', () {
    test('al completar un tablero termina cuando acaba esa ronda', () {
      final mini7 = Nivel(
        numero: 1,
        construirTablero: () => tableroDesdeFilas(
          {'a': TipoVerde(), 'b': TipoVerde()},
          [['a', 'a', 'a', 'a', 'a', 'a', 'b']],
        ),
        casillasIniciales: mini.casillasIniciales,
      );
      m = Mesa(['ana', 'beto'], nivel: mini7, random: DadosFijos([6, 1]));
      m.enviar('ana', 'iniciales', {'valores': inicialesMini});
      m.enviar('beto', 'iniciales', {'valores': [for (var c = 0; c < 6; c++) [0, c, 6 - c]]});

      m.enviar('ana', 'jugada', {'ancla': [0, 5], 'destino': [0, 6]});
      expect(m.j('ana').completo, isTrue);
      expect(m.partida.fase, FasePartida.jugando, reason: 'beto aún tiene su turno');

      m.enviar('beto', 'pasar');
      expect(m.partida.fase, FasePartida.terminada);
      expect(m.terminada, same(m.partida));
      expect(m.ultimo['tipo'], 'partida_terminada');
      expect(m.ultimo['motivo'], 'tablero_completo');
      final res = m.ultimo['resultados'] as List;
      expect(res.map((r) => [r['nametag'], r['posicion'], r['puntos']]), [
        ['ana', 1, 8],
        ['beto', 2, 4],
      ]);
      expect(() => m.enviar('beto', 'pasar'), errorProtocolo('no_es_momento'));
    });

    test('la meta de puntos depende de cuántos juegan', () {
      expect([for (var n = 2; n <= 7; n++) puntosParaGanar(n)], [26, 24, 22, 20, 20, 20]);
      m = Mesa(['ana', 'beto', 'carla']);
      expect(m.partida.puntosMeta, 24);
      expect(m.partida.toJson()['puntosMeta'], 24);
    });

    Nivel conZonaB(int puntosB) => Nivel(
      numero: 1,
      construirTablero: () => tableroDesdeFilas(
        {'a': TipoVerde(), 'b': TipoVerde(puntos(puntosB, 1, 1)), 'c': TipoVerde()},
        [['a', 'a', 'a', 'a', 'a', 'a', 'b', 'c']],
      ),
      casillasIniciales: mini.casillasIniciales,
    );

    void jugarRonda1(Nivel nivel) {
      m = Mesa(['ana', 'beto'], nivel: nivel, random: DadosFijos([6, 1]));
      m.enviar('ana', 'iniciales', {'valores': inicialesMini});
      m.enviar('beto', 'iniciales', {'valores': inicialesMini});
      m.enviar('ana', 'jugada', {'ancla': [0, 5], 'destino': [0, 6]});
      m.enviar('beto', 'pasar');
    }

    test('gana el primero que llega a la meta (2 jugadores: 26)', () {
      jugarRonda1(conZonaB(22)); // ana: 4 (zona a) + 22 = 26
      expect(m.partida.fase, FasePartida.terminada);
      expect(m.partida.motivoFin, 'meta_puntos');
      expect(m.partida.resultados!.map((r) => [r['nametag'], r['posicion'], r['puntos']]), [
        ['ana', 1, 26],
        ['beto', 2, 4],
      ]);
    });

    test('sin llegar a la meta la partida sigue', () {
      jugarRonda1(conZonaB(21)); // ana: 25
      expect(m.j('ana').puntos, 25);
      expect(m.partida.fase, FasePartida.jugando);
      expect(m.partida.ronda, 2);
    });

    test('límite de rondas', () {
      m = Mesa(['ana', 'beto'], config: const ConfigPartida(maxRondas: 2));
      m.enviar('ana', 'iniciales', {'valores': iniciales1});
      m.enviar('beto', 'iniciales', {'valores': iniciales1});
      for (var r = 0; r < 2; r++) {
        m.enviar('ana', 'pasar');
        m.enviar('beto', 'pasar');
      }
      expect(m.partida.fase, FasePartida.terminada);
      expect(m.partida.motivoFin, 'max_rondas');
      final res = m.partida.resultados!;
      expect(res.map((r) => r['posicion']), [1, 1], reason: 'empate en 0 puntos');
    });

    test('conceder: si queda uno solo, gana; los que se van quedan al final', () {
      m = Mesa(['ana', 'beto', 'carla']);
      for (final n in ['ana', 'beto', 'carla']) {
        m.enviar(n, 'iniciales', {'valores': iniciales1});
      }
      m.partida.abandonar('carla');
      expect(m.ultimoEvento, {'tipo': 'abandono', 'nametag': 'carla'});
      expect(m.partida.fase, FasePartida.jugando);
      expect(() => m.enviar('carla', 'pasar'), errorProtocolo('no_es_momento'));

      m.enviar('ana', 'conceder');
      expect(m.partida.fase, FasePartida.terminada);
      expect(m.partida.motivoFin, 'rendicion');
      expect(m.partida.resultados!.map((r) => [r['nametag'], r['posicion'], r['estado']]), [
        ['beto', 1, 'jugando'],
        ['ana', 2, 'concedio'],
        ['carla', 2, 'abandono'],
      ]);
    });

    test('conceder en la fase de iniciales también termina', () {
      m = Mesa(['ana', 'beto']);
      m.enviar('beto', 'conceder');
      expect(m.partida.fase, FasePartida.terminada);
      expect(m.partida.resultados!.first['nametag'], 'ana');
    });
  });
}

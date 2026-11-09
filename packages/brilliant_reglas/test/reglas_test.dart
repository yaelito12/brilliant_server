import 'package:brilliant_reglas/brilliant_reglas.dart';
import 'package:test/test.dart';

/// Valores iniciales válidos del nivel 1 (uno por casilla, del 1 al 6).
final iniciales1 = {
  const Coordenada(0, 2): 1, // azul
  const Coordenada(1, 5): 2, // morado
  const Coordenada(3, 1): 3, // rojo
  const Coordenada(3, 4): 4, // verde
  const Coordenada(5, 2): 5, // morado
  const Coordenada(6, 4): 6, // rojo
};

Tablero tableroCon(Nivel nivel, Map<Coordenada, int> celdas) {
  var t = nivel.construirTablero();
  celdas.forEach((c, n) => t = t.agregarNumero(c, n));
  return t;
}

void main() {
  gruposSinSalida();

  group('otroDado', () {
    test('devuelve el dado que no es el ancla', () {
      expect(otroDado([2, 5], 2), 5);
      expect(otroDado([2, 5], 5), 2);
      expect(otroDado([4, 4], 4), 4);
    });
  });

  group('destinos y anclas (nivel 1)', () {
    final tablero = tableroCon(nivel1, iniciales1);

    test('solo vecinos vacíos cuya zona acepta el número', () {
      // El 1 de la zona azul: abajo es azul (ya tiene un 1, no acepta un 3).
      expect(
        destinosPosibles(tablero, iniciales1, const Coordenada(0, 2), 3),
        {const Coordenada(0, 1), const Coordenada(0, 3)},
      );
    });

    test('anclas: casillas con un número de los dados y algún destino', () {
      expect(
        anclasPosibles(tablero, iniciales1, [1, 3]),
        {const Coordenada(0, 2), const Coordenada(3, 1)},
      );
      expect(anclasPosibles(tablero, iniciales1, [1, 1]), {const Coordenada(0, 2)});
    });

    test('numeroDeJugada valida ancla y destino', () {
      final dados = [1, 3];
      expect(numeroDeJugada(tablero, iniciales1, dados, const Coordenada(0, 2), const Coordenada(0, 1)), 3);
      // Destino que la zona no acepta.
      expect(numeroDeJugada(tablero, iniciales1, dados, const Coordenada(0, 2), const Coordenada(1, 2)), isNull);
      // Destino que no es vecino.
      expect(numeroDeJugada(tablero, iniciales1, dados, const Coordenada(0, 2), const Coordenada(4, 4)), isNull);
      // Ancla cuyo número no salió en los dados.
      expect(numeroDeJugada(tablero, iniciales1, dados, const Coordenada(1, 5), const Coordenada(1, 4)), isNull);
      // Ancla vacía.
      expect(numeroDeJugada(tablero, iniciales1, dados, const Coordenada(0, 0), const Coordenada(0, 1)), isNull);
    });
  });

  group('errorEnValoresIniciales', () {
    test('acepta 6 números distintos en las casillas iniciales', () {
      expect(errorEnValoresIniciales(nivel1, iniciales1), isNull);
    });

    test('rechaza faltantes, casillas ajenas, repetidos y fuera de rango', () {
      final faltante = Map.of(iniciales1)..remove(const Coordenada(0, 2));
      expect(errorEnValoresIniciales(nivel1, faltante), isNotNull);

      final ajena = Map.of(faltante)..[const Coordenada(0, 0)] = 1;
      expect(errorEnValoresIniciales(nivel1, ajena), isNotNull);

      final repetido = Map.of(iniciales1)..[const Coordenada(0, 2)] = 2;
      expect(errorEnValoresIniciales(nivel1, repetido), isNotNull);

      final fuera = Map.of(iniciales1)..[const Coordenada(0, 2)] = 7;
      expect(errorEnValoresIniciales(nivel1, fuera), isNotNull);
    });

    test('rechaza un número que la zona no acepta', () {
      final mini = Nivel(
        numero: 99,
        construirTablero: () => tableroDesdeFilas(
          {'n': TipoNaranjaBajo(), 'v': TipoVerde()},
          [['n', 'v']],
        ),
        casillasIniciales: {const Coordenada(0, 0), const Coordenada(0, 1)},
      );
      expect(errorEnValoresIniciales(mini, {const Coordenada(0, 0): 1, const Coordenada(0, 1): 5}), isNull);
      expect(errorEnValoresIniciales(mini, {const Coordenada(0, 0): 5, const Coordenada(0, 1): 1}), isNotNull);
    });

    test('todos los niveles oficiales tienen 6 casillas iniciales', () {
      for (final n in nivelesOficiales) {
        expect(n.casillasIniciales, hasLength(6), reason: n.nombre);
      }
    });
  });

  test('nivelPorNumero', () {
    expect(nivelPorNumero(1), same(nivel1));
    expect(nivelPorNumero(4), same(nivel4));
    expect(nivelPorNumero(99), isNull);
  });
}

/// Mapa de prueba 1x6: cinco casillas verdes y una naranja 1-3, todas iniciales.
final conNaranja = Nivel(
  numero: 98,
  construirTablero: () => tableroDesdeFilas(
    {'v': TipoVerde(), 'n': TipoNaranjaBajo()},
    [['v', 'v', 'v', 'v', 'v', 'n']],
  ),
  casillasIniciales: {for (var c = 0; c < 6; c++) Coordenada(0, c)},
);

void gruposSinSalida() {
  group('casillas iniciales sin salida', () {
    const naranja = Coordenada(0, 5);

    test('numerosParaInicial: sin repetir y que la zona lo acepte', () {
      expect(numerosParaInicial(conNaranja, {}, naranja), {1, 2, 3});
      expect(numerosParaInicial(conNaranja, {const Coordenada(0, 0): 2}, naranja), {1, 3});
      expect(numerosParaInicial(conNaranja, {const Coordenada(0, 0): 2}, const Coordenada(0, 1)),
          {1, 3, 4, 5, 6});
    });

    test('si el 1, 2 y 3 ya se usaron, la naranja 1-3 queda sin salida y dice qué mover', () {
      final valores = {
        const Coordenada(0, 0): 1,
        const Coordenada(0, 1): 2,
        const Coordenada(0, 2): 3,
        const Coordenada(0, 3): 4,
      };
      expect(numerosParaInicial(conNaranja, valores, naranja), isEmpty);
      final b = bloqueoInicial(conNaranja, valores, naranja)!;
      expect(b.zona.tipo, isA<TipoNaranjaBajo>());
      expect(b.aceptaLaZona, {1, 2, 3});
      expect(b.usadoEn, {1: const Coordenada(0, 0), 2: const Coordenada(0, 1), 3: const Coordenada(0, 2)});
      expect(inicialesSinSalida(conNaranja, valores), [naranja]);

      // Mover cualquiera de ellos lo arregla.
      final arreglado = Map.of(valores)
        ..remove(const Coordenada(0, 0))
        ..[naranja] = 1;
      expect(inicialesSinSalida(conNaranja, arreglado), isEmpty);
      expect(numerosParaInicial(conNaranja, arreglado, const Coordenada(0, 0)), {5, 6});
    });

    test('con números disponibles no hay bloqueo', () {
      expect(bloqueoInicial(conNaranja, {const Coordenada(0, 0): 1}, naranja), isNull);
      expect(inicialesSinSalida(conNaranja, {const Coordenada(0, 0): 1}), isEmpty);
    });
  });
}

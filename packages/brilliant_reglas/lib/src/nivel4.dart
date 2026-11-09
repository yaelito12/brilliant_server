import 'nivel.dart';
import 'tablero.dart';
import 'tipo.dart';

/// Las 6 casillas marcadas en el tablero del Nivel 4.
/// La de la fila de arriba solo admite 4-6 y la de abajo solo 1-3.
final Set<Coordenada> casillasInicialesNivel4 = {
  Coordenada(0, 4), // Fila 0, Col 4 - Zona Naranja 4-6
  Coordenada(2, 2), // Fila 2, Col 2 - Zona Morada
  Coordenada(2, 5), // Fila 2, Col 5 - Zona Roja
  Coordenada(3, 0), // Fila 3, Col 0 - Zona Amarilla
  Coordenada(5, 4), // Fila 5, Col 4 - Zona Azul
  Coordenada(6, 1), // Fila 6, Col 1 - Zona Naranja 1-3
};

/// Construye el tablero vacío del Nivel 4.
///
/// La fila de arriba es una zona naranja 4-6 y la de abajo una naranja 1-3.
/// Las casillas amarillas, azules y verdes sueltas forman una zona por
/// color; las rojas forman 2 zonas (izquierda y derecha).
Tablero construirTableroNivel4() {
  return tableroDesdeFilas(
    {
      'na': TipoNaranjaAlto(puntos(6, 4, 3)),
      'nb': TipoNaranjaBajo(puntos(6, 4, 3)),
      'am': TipoAmarillo(puntos(8, 6, 4)),
      'az': TipoAzul(puntos(8, 6, 4)),
      've': TipoVerde(puntos(3, 2, 1)),
      'mo': TipoMorado(puntos(7, 5, 3)),
      'ro1': TipoRojo(puntos(6, 4, 2)),
      'ro2': TipoRojo(puntos(6, 4, 2)),
    },
    [
      ['na', 'na', 'na', 'na', 'na', 'na', 'na'],
      ['am', 'ro1', 'az', 've', 'az', 'ro2', 'am'],
      ['ro1', 'ro1', 'mo', 'mo', 'mo', 'ro2', 'ro2'],
      ['am', 've', 'az', 'mo', 'az', 've', 'am'],
      ['ro1', 'ro1', 'mo', 'mo', 'mo', 'ro2', 'ro2'],
      ['am', 'ro1', 'az', 've', 'az', 'ro2', 'am'],
      ['nb', 'nb', 'nb', 'nb', 'nb', 'nb', 'nb'],
    ],
  );
}

final Nivel nivel4 = Nivel(
  numero: 4,
  construirTablero: construirTableroNivel4,
  casillasIniciales: casillasInicialesNivel4,
  indicadoresIzquierda: ['mo', 'az', 'ro1', 'nb'],
  indicadoresDerecha: ['na', 'ro2', 'am', 've'],
);

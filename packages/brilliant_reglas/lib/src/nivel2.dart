import 'nivel.dart';
import 'tablero.dart';
import 'tipo.dart';

/// Las 6 casillas marcadas en el tablero del Nivel 2.
final Set<Coordenada> casillasInicialesNivel2 = {
  Coordenada(0, 4), // Fila 0, Col 4 - Zona Verde
  Coordenada(2, 0), // Fila 2, Col 0 - Zona Morada
  Coordenada(3, 2), // Fila 3, Col 2 - Zona Roja
  Coordenada(4, 5), // Fila 4, Col 5 - Zona Roja
  Coordenada(5, 1), // Fila 5, Col 1 - Zona Amarilla
  Coordenada(6, 4), // Fila 6, Col 4 - Zona Morada
};

/// Construye el tablero vacío del Nivel 2.
///
/// Aparece la zona gris: las 2 casillas blancas del centro de la primera
/// y la última fila, que forman una sola zona.
Tablero construirTableroNivel2() {
  return tableroDesdeFilas(
    {
      // 5 casillas amarillas sueltas, una sola zona (como en el nivel 1)
      'am': TipoAmarillo(puntos(6, 4, 2)),
      've1': TipoVerde(puntos(4, 3, 2)),
      've2': TipoVerde(puntos(4, 3, 2)),
      'az1': TipoAzul(puntos(7, 5, 3)),
      'az2': TipoAzul(puntos(7, 5, 3)),
      'mo1': TipoMorado(puntos(6, 4, 2)),
      'mo2': TipoMorado(puntos(6, 4, 2)),
      'ro1': TipoRojo(puntos(6, 4, 2)),
      'ro2': TipoRojo(puntos(6, 4, 2)),
      'gr': TipoGris(puntos(3, 2, 1)),
    },
    [
      ['mo1', 'mo1', 'mo1', 'gr', 've1', 've1', 've1'],
      ['mo1', 'am', 'az1', 'az1', 'az1', 'am', 've1'],
      ['mo1', 'ro1', 'ro1', 'az1', 'az1', 'ro2', 've1'],
      ['ro1', 'ro1', 'ro1', 'am', 'ro2', 'ro2', 'ro2'],
      ['ve2', 'ro1', 'az2', 'az2', 'ro2', 'ro2', 'mo2'],
      ['ve2', 'am', 'az2', 'az2', 'az2', 'am', 'mo2'],
      ['ve2', 've2', 've2', 'gr', 'mo2', 'mo2', 'mo2'],
    ],
  );
}

final Nivel nivel2 = Nivel(
  numero: 2,
  construirTablero: construirTableroNivel2,
  casillasIniciales: casillasInicialesNivel2,
  indicadoresIzquierda: ['am', 'mo1', 'ro1', 'az2', 've2'],
  indicadoresDerecha: ['ve1', 'az1', 'ro2', 'mo2', 'gr'],
);

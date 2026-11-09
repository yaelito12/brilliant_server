import 'nivel.dart';
import 'tablero.dart';
import 'tipo.dart';

/// Las 6 casillas marcadas en el tablero del Nivel 3.
final Set<Coordenada> casillasInicialesNivel3 = {
  Coordenada(1, 2), // Fila 1, Col 2 - Zona Morada
  Coordenada(1, 5), // Fila 1, Col 5 - Zona Amarilla
  Coordenada(3, 3), // Fila 3, Col 3 - Zona Gris
  Coordenada(4, 1), // Fila 4, Col 1 - Zona Azul
  Coordenada(4, 6), // Fila 4, Col 6 - Zona Verde
  Coordenada(6, 2), // Fila 6, Col 2 - Zona Morada
};

/// Construye el tablero vacío del Nivel 3.
///
/// Las 2 esquinas amarillas de arriba están unidas en la hoja y forman una
/// sola zona; lo mismo las 5 casillas grises y las 2 mitades moradas de
/// la última fila.
Tablero construirTableroNivel3() {
  return tableroDesdeFilas(
    {
      'am': TipoAmarillo(puntos(7, 5, 3)),
      've': TipoVerde(puntos(6, 5, 4)),
      'az': TipoAzul(puntos(7, 5, 3)),
      'mo1': TipoMorado(puntos(7, 5, 3)),
      'mo2': TipoMorado(puntos(7, 5, 3)),
      'ro1': TipoRojo(puntos(6, 4, 2)),
      'ro2': TipoRojo(puntos(6, 4, 2)),
      'gr': TipoGris(puntos(8, 6, 4)),
    },
    [
      ['am', 'am', 'mo1', 'gr', 'mo1', 'am', 'am'],
      ['gr', 'am', 'mo1', 'mo1', 'mo1', 'am', 'gr'],
      ['ro1', 'ro1', 'ro1', 'mo1', 'ro2', 'ro2', 'ro2'],
      ['ro1', 'ro1', 'ro1', 'gr', 'ro2', 'ro2', 'ro2'],
      ['ve', 'az', 'az', 'az', 'az', 'az', 've'],
      ['ve', 've', 've', 've', 've', 've', 've'],
      ['mo2', 'mo2', 'mo2', 'gr', 'mo2', 'mo2', 'mo2'],
    ],
  );
}

final Nivel nivel3 = Nivel(
  numero: 3,
  construirTablero: construirTableroNivel3,
  casillasIniciales: casillasInicialesNivel3,
  indicadoresIzquierda: ['mo1', 'ro1', 'az', 'mo2'],
  indicadoresDerecha: ['am', 'ro2', 've', 'gr'],
);

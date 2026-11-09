import 'nivel.dart';
import 'tablero.dart';
import 'zona.dart';
import 'tipo.dart';

final Nivel nivel1 = Nivel(
  numero: 1,
  construirTablero: construirTableroNivel1,
  casillasIniciales: casillasInicialesNivel1,
  indicadoresIzquierda: ['az1', 've1', 'ro1', 'mo2'],
  indicadoresDerecha: ['mo1', 'am', 've2', 'az2', 'ro2'],
);

/// Las 6 casillas marcadas con X en el tablero del Nivel 1.
/// El jugador debe rellenarlas con números del 1 al 6 sin repetir.
final Set<Coordenada> casillasInicialesNivel1 = {
  Coordenada(0, 2), // Fila 0, Col 2 - Zona Azul
  Coordenada(1, 5), // Fila 1, Col 5 - Zona Morada
  Coordenada(3, 1), // Fila 3, Col 1 - Zona Roja
  Coordenada(3, 4), // Fila 3, Col 4 - Zona Verde
  Coordenada(5, 2), // Fila 5, Col 2 - Zona Morada
  Coordenada(6, 4), // Fila 6, Col 4 - Zona Roja
};

/// Construye el tablero vacío del Nivel 1.
Tablero construirTableroNivel1() {
  final zonas = {
    // Las 5 casillas amarillas (esquinas y centro) forman una sola zona:
    // solo puntúa cuando están todas llenas.
    'am': Zona(id: 'am', tipo: TipoAmarillo(), capacidad: 5),
    've1': Zona(id: 've1', tipo: TipoVerde(), capacidad: 6),
    've2': Zona(id: 've2', tipo: TipoVerde(), capacidad: 6),
    'az1': Zona(id: 'az1', tipo: TipoAzul(), capacidad: 4),
    'az2': Zona(id: 'az2', tipo: TipoAzul(), capacidad: 4),
    'mo1': Zona(id: 'mo1', tipo: TipoMorado(), capacidad: 6),
    'mo2': Zona(id: 'mo2', tipo: TipoMorado(), capacidad: 6),
    'ro1': Zona(id: 'ro1', tipo: TipoRojo(), capacidad: 6),
    'ro2': Zona(id: 'ro2', tipo: TipoRojo(), capacidad: 6),
  };

  final mapeo = <Coordenada, String>{};
  void mapear(String id, List<List<int>> coords) {
    for (var c in coords) {
      mapeo[Coordenada(c[0], c[1])] = id;
    }
  }

  mapear('am', [[0, 0], [0, 6], [3, 3], [6, 0], [6, 6]]);
  mapear('ve1', [[0, 1], [1, 0], [1, 1], [2, 0], [3, 0], [4, 0]]);
  mapear('ve2', [[1, 6], [2, 5], [2, 6], [3, 4], [3, 5], [3, 6]]);
  mapear('az1', [[0, 2], [1, 2], [1, 3], [2, 3]]);
  mapear('az2', [[4, 6], [5, 5], [5, 6], [6, 5]]);
  mapear('mo1', [[0, 3], [0, 4], [0, 5], [1, 4], [1, 5], [2, 4]]);
  mapear('mo2', [[3, 2], [4, 2], [4, 3], [5, 2], [6, 1], [6, 2]]);
  mapear('ro1', [[2, 1], [2, 2], [3, 1], [4, 1], [5, 0], [5, 1]]);
  mapear('ro2', [[4, 4], [4, 5], [5, 3], [5, 4], [6, 3], [6, 4]]);

  return Tablero(filas: 7, columnas: 7, zonas: zonas, mapeo: mapeo);
}

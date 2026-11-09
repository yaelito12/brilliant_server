import 'tablero.dart';
import 'tipo.dart';
import 'zona.dart';

/// Arma un tablero a partir de sus filas, escritas como en la hoja del
/// nivel: cada casilla lleva el id de su zona y [tipos] dice el tipo de
/// cada id. La capacidad de cada zona es la cantidad de casillas que tiene.
Tablero tableroDesdeFilas(
  Map<String, Tipo> tipos,
  List<List<String>> filas,
) {
  final mapeo = <Coordenada, String>{};
  for (var f = 0; f < filas.length; f++) {
    for (var c = 0; c < filas[f].length; c++) {
      mapeo[Coordenada(f, c)] = filas[f][c];
    }
  }

  final zonas = {
    for (final MapEntry(key: id, value: tipo) in tipos.entries)
      id: Zona(
        id: id,
        tipo: tipo,
        capacidad: mapeo.values.where((z) => z == id).length,
      ),
  };

  return Tablero(
    filas: filas.length,
    columnas: filas.first.length,
    zonas: zonas,
    mapeo: mapeo,
  );
}

/// Un mapa oficial del juego: su tablero vacío y las 6 casillas donde el
/// jugador pone los números iniciales antes de empezar.
class Nivel {
  final int numero;

  /// Crea el tablero vacío del nivel (uno nuevo en cada partida).
  final Tablero Function() construirTablero;

  final Set<Coordenada> casillasIniciales;

  /// IDs de las zonas cuyo indicador (regla y puntos) va a la izquierda
  /// del tablero, de arriba a abajo, como en la hoja del nivel.
  final List<String> indicadoresIzquierda;

  /// IDs de las zonas cuyo indicador va a la derecha del tablero.
  final List<String> indicadoresDerecha;

  const Nivel({
    required this.numero,
    required this.construirTablero,
    required this.casillasIniciales,
    this.indicadoresIzquierda = const [],
    this.indicadoresDerecha = const [],
  });

  String get nombre => 'Nivel $numero';
}

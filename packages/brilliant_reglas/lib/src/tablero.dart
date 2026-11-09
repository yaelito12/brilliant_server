import 'zona.dart';

/// Representa una posición física en la cuadrícula del tablero.
class Coordenada {
  final int fila;
  final int columna;

  const Coordenada(this.fila, this.columna);

  @override
  bool operator ==(Object other) =>
      other is Coordenada && other.fila == fila && other.columna == columna;

  @override
  int get hashCode => Object.hash(fila, columna);

  @override
  String toString() => '($fila, $columna)';
}

/// Representa el estado completo del juego en una cuadrícula de 7x7.
class Tablero {
  final int filas;
  final int columnas;
  
  /// Diccionario con todas las zonas del nivel, accesibles por su ID.
  final Map<String, Zona> zonas;
  
  /// Mapeo de qué coordenada pertenece a qué ID de Zona.
  final Map<Coordenada, String> mapeo;

  /// IDs de las zonas en el orden en que se fueron completando.
  final List<String> ordenCompletadas;

  const Tablero({
    this.filas = 7,
    this.columnas = 7,
    required this.zonas,
    required this.mapeo,
    this.ordenCompletadas = const [],
  });

  /// Verifica si una coordenada está dentro de los límites de 7x7.
  bool esCoordenadaValida(Coordenada c) {
    return c.fila >= 0 && c.fila < filas && c.columna >= 0 && c.columna < columnas;
  }

  /// Retorna la Zona correspondiente a una coordenada específica.
  Zona? zonaEn(Coordenada coordenada) {
    if (!esCoordenadaValida(coordenada)) return null;
    
    final zonaId = mapeo[coordenada];
    if (zonaId == null) return null;
    return zonas[zonaId];
  }

  /// Retorna true si todas las zonas han alcanzado su capacidad[cite: 6].
  bool get estaCompleto {
    return zonas.values.every((zona) => zona.estaCompleta);
  }

  /// Puntos de la zona [zonaId]: cada zona es independiente, así que al
  /// llenarla da los puntos completos de su color (ej. cada verde da 4),
  /// o 0 si aún no está completa.
  ///
  /// El 2º y 3er lugar (ej. verde 3 y 2) son para cuando otro jugador ya
  /// llenó esa misma zona antes; se usarán con el multijugador.
  int puntosDe(String zonaId) {
    return zonas[zonaId]!.puntuacion(lugar: 1);
  }

  /// Puntuación total: suma de los puntos de cada zona completa.
  int get puntuacion {
    return zonas.keys.fold(0, (total, id) => total + puntosDe(id));
  }

  /// Casillas vecinas (arriba, abajo, izquierda, derecha) dentro del tablero.
  List<Coordenada> vecinos(Coordenada c) {
    return [
      Coordenada(c.fila - 1, c.columna),
      Coordenada(c.fila + 1, c.columna),
      Coordenada(c.fila, c.columna - 1),
      Coordenada(c.fila, c.columna + 1),
    ].where(esCoordenadaValida).toList();
  }

  /// Intenta agregar un número en una coordenada.
  /// Si la jugada es válida, retorna un nuevo Tablero actualizado.
  /// Si es inválida o está fuera de límites, retorna el mismo Tablero sin cambios.
  Tablero agregarNumero(Coordenada coordenada, int numero) {
    final zona = zonaEn(coordenada);
    
    if (zona == null) return this;

    // Verificamos si la zona permite agregar este número según su Tipo[cite: 5, 6].
    if (zona.puedeAgregar(numero)) {
      final zonaActualizada = zona.agregar(numero);
      
      final nuevasZonas = Map<String, Zona>.from(zonas);
      nuevasZonas[zonaActualizada.id] = zonaActualizada;

      return Tablero(
        filas: filas,
        columnas: columnas,
        zonas: nuevasZonas,
        mapeo: mapeo,
        ordenCompletadas: zonaActualizada.estaCompleta
            ? [...ordenCompletadas, zonaActualizada.id]
            : ordenCompletadas,
      );
    }
    
    return this; 
  }
}
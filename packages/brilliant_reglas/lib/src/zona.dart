import 'tipo.dart';

/// Una zona del tablero: un bloque completo de un color específico.
///
/// A diferencia de una celda individual, [Zona] representa todo el
/// bloque junto, con los números que ya se han colocado en él.
class Zona {
  final String id;
  final Tipo tipo;
  final int capacidad;
  final List<int> valores;

  const Zona({
    required this.id,
    required this.tipo,
    required this.capacidad,
    this.valores = const [],
  });

  /// true si la zona ya alcanzó su capacidad máxima de casillas.
  bool get estaCompleta => valores.length >= capacidad;

  /// true si [numero] se puede agregar a esta zona en este momento,
  /// según la regla de [tipo] y el espacio disponible.
  bool puedeAgregar(int numero) {
    if (estaCompleta) {
      return false;
    }
    return tipo.esPosibleAgregar(valores, numero);
  }

  /// Puntos que otorga la zona. Solo puntúa si está completa, y vale
  /// lo que indique [Tipo.puntuaciones] para el [lugar] en que se
  /// completó (1 = primero en completarla).
  int puntuacion({int lugar = 1}) {
    if (!estaCompleta) return 0;
    return tipo.puntuaciones[lugar] ?? 0;
  }

  /// Retorna una nueva Zona con [numero] agregado al final de
  /// [valores]. No valida la regla del [tipo] ni la capacidad;
  /// usa [puedeAgregar] antes de llamar a este método para asegurar
  /// que la jugada es válida.
  Zona agregar(int numero) {
    return copyWith(valores: [...valores, numero]);
  }

  /// Retorna una nueva Zona con [valores] reemplazado. El resto de
  /// los campos (id, tipo, capacidad) se mantienen igual.
  Zona copyWith({List<int>? valores}) {
    return Zona(
      id: id,
      tipo: tipo,
      capacidad: capacidad,
      valores: valores ?? this.valores,
    );
  }

  @override
  String toString() =>
      'Zona(id: $id, tipo: ${tipo.runtimeType}, capacidad: $capacidad, valores: $valores)';

  @override
  bool operator ==(Object other) =>
      other is Zona &&
      other.id == id &&
      other.tipo.runtimeType == tipo.runtimeType &&
      other.capacidad == capacidad &&
      _mismaLista(other.valores, valores);

  @override
  int get hashCode => Object.hash(id, tipo.runtimeType, capacidad, Object.hashAll(valores));

  static bool _mismaLista(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
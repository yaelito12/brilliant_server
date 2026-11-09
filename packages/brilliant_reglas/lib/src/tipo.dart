abstract class Tipo {
  /// Puntos de este nivel para el 1º, 2º y 3º en llenar la zona. Cada mapa
  /// trae los suyos (ej. el amarillo da 8-6-4 en el nivel 1 y 6-4-2 en el
  /// nivel 2); si es null se usan [puntuacionesBase].
  final Map<int, int>? puntosNivel;

  Tipo([this.puntosNivel]);

  String get descripcion;
  bool esPosibleAgregar(List<int> actuales, int posible);

  /// Puntos por defecto del color (los del nivel 1).
  Map<int, int> get puntuacionesBase => const {};

  Map<int, int> get puntuaciones => puntosNivel ?? puntuacionesBase;
}

/// Puntos para el 1º, 2º y 3º lugar, ej. `puntos(6, 4, 2)`.
Map<int, int> puntos(int primero, int segundo, int tercero) =>
    {1: primero, 2: segundo, 3: tercero};

class TipoVerde extends Tipo {
  TipoVerde([super.puntosNivel]);

  @override
  String get descripcion => 'Se puede colocar cualquier número';

  @override
  bool esPosibleAgregar(List<int> actuales, int posible) {
    return true;
  }

  @override
  Map<int, int> get puntuacionesBase => {
        1: 4,
        2: 3,
        3: 2,
      };
}

class TipoAzul extends Tipo {
  TipoAzul([super.puntosNivel]);

  @override
  String get descripcion => 'Todos los números deben de ser iguales';

  @override
  bool esPosibleAgregar(List<int> actuales, int posible) {
    return actuales.isEmpty || actuales.every((element) => element == posible);
  }

  @override
  Map<int, int> get puntuacionesBase => {
        1: 7,
        2: 5,
        3: 3,
      };
}

class TipoMorado extends Tipo {
  TipoMorado([super.puntosNivel]);

  @override
  String get descripcion => 'Máximo dos números diferentes por zona';

  @override
  bool esPosibleAgregar(List<int> actuales, int posible) {
    final distintos = actuales.toSet()..add(posible);
    return distintos.length <= 2;
  }

  @override
  Map<int, int> get puntuacionesBase => {
        1: 6,
        2: 4,
        3: 2,
      };
}

class TipoRojo extends Tipo {
  TipoRojo([super.puntosNivel]);

  @override
  String get descripcion => 'Todos los números deben ser diferentes';

  @override
  bool esPosibleAgregar(List<int> actuales, int posible) {
    if (actuales.contains(posible)) {
      return false;
    }
    return actuales.toSet().length == actuales.length;
  }

  @override
  Map<int, int> get puntuacionesBase => {
        1: 6,
        2: 4,
        3: 2,
      };
}

class TipoAmarillo extends Tipo {
  TipoAmarillo([super.puntosNivel]);

  @override
  String get descripcion => 'Todos los números deben ser diferentes';

  @override
  bool esPosibleAgregar(List<int> actuales, int posible) {
    if (actuales.contains(posible)) {
      return false;
    }
    return actuales.toSet().length == actuales.length;
  }

  @override
  Map<int, int> get puntuacionesBase => {
        1: 8,
        2: 6,
        3: 4,
      };
}

/// Zona gris (casillas blancas del tablero, aparece desde el nivel 2):
/// como el azul, todos los números iguales.
class TipoGris extends Tipo {
  TipoGris([super.puntosNivel]);

  @override
  String get descripcion => 'Todos los números deben de ser iguales';

  @override
  bool esPosibleAgregar(List<int> actuales, int posible) {
    return actuales.isEmpty || actuales.every((element) => element == posible);
  }

  @override
  Map<int, int> get puntuacionesBase => {
        1: 3,
        2: 2,
        3: 1,
      };
}

/// Zona naranja (aparece en el nivel 4): solo acepta números dentro de
/// un rango, repetidos o no.
abstract class TipoNaranja extends Tipo {
  TipoNaranja([super.puntosNivel]);

  int get minimo;
  int get maximo;

  @override
  String get descripcion => 'Solo números del $minimo al $maximo';

  @override
  bool esPosibleAgregar(List<int> actuales, int posible) {
    return posible >= minimo && posible <= maximo;
  }

  @override
  Map<int, int> get puntuacionesBase => {
        1: 6,
        2: 4,
        3: 3,
      };
}

/// Naranja "1-3": solo números del 1 al 3.
class TipoNaranjaBajo extends TipoNaranja {
  TipoNaranjaBajo([super.puntosNivel]);

  @override
  int get minimo => 1;

  @override
  int get maximo => 3;
}

/// Naranja "4-6": solo números del 4 al 6.
class TipoNaranjaAlto extends TipoNaranja {
  TipoNaranjaAlto([super.puntosNivel]);

  @override
  int get minimo => 4;

  @override
  int get maximo => 6;
}

import 'nivel.dart';
import 'niveles.dart';
import 'tablero.dart';
import 'zona.dart';

/// Reglas de un turno, sin estado. Las usan la app (para marcar jugadas
/// posibles) y el servidor (para validar las jugadas del multijugador), así
/// ambos aplican exactamente las mismas reglas.
///
/// Regla de colocación: el ancla es una casilla con número igual a uno de
/// los dados; el otro dado se coloca en una casilla vacía vecina (arriba,
/// abajo, izquierda o derecha) cuya zona acepte ese número.

/// Valor que se coloca si el ancla tiene [valorAncla]: el del otro dado.
int otroDado(List<int> dados, int valorAncla) =>
    valorAncla == dados[0] ? dados[1] : dados[0];

/// Casillas vacías vecinas de [ancla] donde la zona acepta [numero].
Set<Coordenada> destinosPosibles(
  Tablero tablero,
  Map<Coordenada, int> celdas,
  Coordenada ancla,
  int numero,
) {
  return tablero
      .vecinos(ancla)
      .where((c) => !celdas.containsKey(c))
      .where((c) => tablero.zonaEn(c)?.puedeAgregar(numero) ?? false)
      .toSet();
}

/// Casillas con número igual a un dado que tienen al menos un destino válido.
Set<Coordenada> anclasPosibles(
  Tablero tablero,
  Map<Coordenada, int> celdas,
  List<int> dados,
) {
  return celdas.entries
      .where((e) => dados.contains(e.value))
      .where(
        (e) => destinosPosibles(tablero, celdas, e.key, otroDado(dados, e.value))
            .isNotEmpty,
      )
      .map((e) => e.key)
      .toSet();
}

/// true si con [dados] se puede usar [ancla] para poner un número en [destino].
/// Devuelve el número que se colocaría, o null si la jugada no es válida.
int? numeroDeJugada(
  Tablero tablero,
  Map<Coordenada, int> celdas,
  List<int> dados,
  Coordenada ancla,
  Coordenada destino,
) {
  final valorAncla = celdas[ancla];
  if (valorAncla == null || !dados.contains(valorAncla)) return null;
  final numero = otroDado(dados, valorAncla);
  return destinosPosibles(tablero, celdas, ancla, numero).contains(destino)
      ? numero
      : null;
}

/// Revisa los 6 números iniciales que pone el jugador antes de empezar:
/// uno en cada casilla inicial del nivel, del 1 al 6, sin repetir, y que la
/// zona de cada casilla lo acepte. Devuelve el error o null si están bien.
String? errorEnValoresIniciales(Nivel nivel, Map<Coordenada, int> valores) {
  if (valores.length != nivel.casillasIniciales.length ||
      !valores.keys.every(nivel.casillasIniciales.contains)) {
    return 'Hay que poner un número en cada casilla inicial.';
  }
  if (valores.values.any((n) => n < 1 || n > 6)) {
    return 'Los números iniciales van del 1 al 6.';
  }
  if (valores.values.toSet().length != valores.length) {
    return 'Los números iniciales no se pueden repetir.';
  }
  var tablero = nivel.construirTablero();
  for (final MapEntry(key: c, value: n) in valores.entries) {
    if (!(tablero.zonaEn(c)?.puedeAgregar(n) ?? false)) {
      return 'La zona de la casilla $c no acepta el $n.';
    }
    tablero = tablero.agregarNumero(c, n);
  }
  return null;
}

/// Números (1 a 6) que se pueden poner en la casilla inicial [c], con los
/// [valores] que ya hay en las demás: sin repetir y que la zona los acepte.
Set<int> numerosParaInicial(Nivel nivel, Map<Coordenada, int> valores, Coordenada c) {
  final tablero = nivel.construirTablero();
  final zona = tablero.zonaEn(c);
  if (zona == null) return const {};
  final usados = {
    for (final e in valores.entries)
      if (e.key != c) e.value,
  };
  final enLaZona = [
    for (final e in valores.entries)
      if (e.key != c && tablero.zonaEn(e.key)?.id == zona.id) e.value,
  ];
  return {
    for (var n = 1; n <= 6; n++)
      if (!usados.contains(n) && zona.tipo.esPosibleAgregar(enLaZona, n)) n,
  };
}

/// Por qué una casilla inicial se quedó sin ningún número posible y cómo
/// arreglarlo.
class BloqueoInicial {
  /// Zona de la casilla.
  final Zona zona;

  /// Números que la zona aceptaría (si no estuvieran usados en otro lado).
  final Set<int> aceptaLaZona;

  /// Dónde está usado cada uno de esos números. Para arreglarlo basta con
  /// mover cualquiera de ellos a esta casilla.
  final Map<int, Coordenada> usadoEn;

  const BloqueoInicial({
    required this.zona,
    required this.aceptaLaZona,
    required this.usadoEn,
  });
}

/// Si en la casilla inicial [c] ya no cabe ningún número (por ejemplo, una
/// zona naranja 1-3 cuando el 1, el 2 y el 3 ya se usaron en otras casillas),
/// dice por qué y qué números se podrían mover ahí. Si cabe alguno, null.
BloqueoInicial? bloqueoInicial(Nivel nivel, Map<Coordenada, int> valores, Coordenada c) {
  if (numerosParaInicial(nivel, valores, c).isNotEmpty) return null;
  final tablero = nivel.construirTablero();
  final zona = tablero.zonaEn(c);
  if (zona == null) return null;
  final enLaZona = [
    for (final e in valores.entries)
      if (e.key != c && tablero.zonaEn(e.key)?.id == zona.id) e.value,
  ];
  final acepta = {
    for (var n = 1; n <= 6; n++)
      if (zona.tipo.esPosibleAgregar(enLaZona, n)) n,
  };
  return BloqueoInicial(
    zona: zona,
    aceptaLaZona: acepta,
    usadoEn: {
      for (final e in valores.entries)
        if (e.key != c && acepta.contains(e.value)) e.value: e.key,
    },
  );
}

/// Casillas iniciales todavía vacías en las que ya no cabe ningún número.
/// Sirve para avisar en cuanto pasa, no recién al llegar a esa casilla.
List<Coordenada> inicialesSinSalida(Nivel nivel, Map<Coordenada, int> valores) => [
  for (final c in nivel.casillasIniciales)
    if (!valores.containsKey(c) && numerosParaInicial(nivel, valores, c).isEmpty) c,
]..sort((a, b) => a.fila != b.fila ? a.fila - b.fila : a.columna - b.columna);

/// Nivel oficial con ese número, o null si no existe.
Nivel? nivelPorNumero(int numero) {
  for (final n in nivelesOficiales) {
    if (n.numero == numero) return n;
  }
  return null;
}

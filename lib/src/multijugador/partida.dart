import 'dart:async';
import 'dart:math';

import 'package:brilliant_reglas/brilliant_reglas.dart';

import 'protocolo.dart';

enum FasePartida {
  /// Cada jugador pone sus 6 números iniciales.
  iniciales,

  /// Rondas de dados.
  jugando,
  terminada,
}

enum EstadoJugador {
  jugando,

  /// Se rindió (o salió de la sala). Queda al final de la clasificación.
  concedio,

  /// Se desconectó y no volvió a tiempo.
  abandono,
}

/// Puntos que hay que alcanzar para ganar según cuántos [jugadores] empiezan
/// la partida: 2 → 26, 3 → 24, 4 → 22 y 5 o más → 20.
int puntosParaGanar(int jugadores) => switch (jugadores) {
  <= 2 => 26,
  3 => 24,
  4 => 22,
  _ => 20,
};

class ConfigPartida {
  final Duration tiempoIniciales;
  final Duration tiempoTurno;
  final int maxRondas;

  const ConfigPartida({
    this.tiempoIniciales = const Duration(seconds: 90),
    this.tiempoTurno = const Duration(seconds: 60),
    this.maxRondas = 100,
  });
}

class JugadorPartida {
  final String id;
  final String nametag;
  final Nivel nivel;
  Tablero tablero;
  final Map<Coordenada, int> celdas = {};
  EstadoJugador estado = EstadoJugador.jugando;
  bool conectado = true;

  /// Ya jugó (o pasó) en esta ronda; en la fase de iniciales: ya los puso.
  bool yaJugo = false;

  /// Lugar en que completó cada zona (1 = primero de todos).
  final Map<String, int> lugares = {};

  JugadorPartida({required this.id, required this.nametag, required this.nivel})
    : tablero = nivel.construirTablero();

  bool get activo => estado == EstadoJugador.jugando;
  bool get completo => tablero.estaCompleto;

  int get puntos => lugares.entries.fold(
    0,
    (total, e) => total + (tablero.zonas[e.key]!.tipo.puntuaciones[e.value] ?? 0),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'nametag': nametag,
    'nivel': nivel.numero,
    'estado': estado.name,
    'conectado': conectado,
    'yaJugo': yaJugo,
    'puntos': puntos,
    'completo': completo,
    'celdas': [
      for (final MapEntry(key: c, value: n) in celdas.entries) [c.fila, c.columna, n],
    ],
    'lugares': lugares,
  };
}

/// Una partida multijugador en curso. Cada jugador tiene su propio tablero
/// (su mapa) y todos usan los mismos dados en cada ronda.
///
/// El servidor tira los dados y valida cada jugada con `brilliant_reglas`: la
/// app solo propone, nunca decide la puntuación.
class Partida {
  final ConfigPartida config;
  final List<JugadorPartida> jugadores;
  final Random _random;
  final void Function(Map<String, Object?> mensaje) _difundir;
  final void Function(Partida partida) _alTerminar;

  FasePartida fase = FasePartida.iniciales;
  int ronda = 0;
  List<int>? dados;
  String? motivoFin;
  List<Map<String, Object?>>? resultados;

  Timer? _reloj;
  DateTime? _limite;

  /// Cuánto se espera a quien pierde la conexión (lo dice el lobby al avisar
  /// la desconexión). La ronda se estira ese rato en vez de pasarle el turno.
  Duration _esperaPorDesconexion = const Duration(seconds: 10);

  /// Veces que se estiró esta ronda esperando a alguien desconectado (por si
  /// el lobby nunca lo saca, la partida no se queda congelada para siempre).
  int _prorrogas = 0;

  /// Cuántos jugadores completaron cada zona en rondas anteriores.
  final _completadasAntes = <String, int>{};

  /// Cuántos la completaron en esta ronda (comparten lugar).
  final _completadasEnRonda = <String, int>{};

  Partida({
    required this.jugadores,
    required void Function(Map<String, Object?> mensaje) difundir,
    required void Function(Partida partida) alTerminar,
    this.config = const ConfigPartida(),
    Random? random,
  }) : _difundir = difundir,
       _alTerminar = alTerminar,
       _random = random ?? Random.secure();

  JugadorPartida? jugador(String id) {
    for (final j in jugadores) {
      if (j.id == id) return j;
    }
    return null;
  }

  Iterable<JugadorPartida> get _activos => jugadores.where((j) => j.activo);

  /// Puntos para ganar según cuántos empezaron la partida.
  int get puntosMeta => puntosParaGanar(jugadores.length);

  /// Empieza la fase de números iniciales.
  void iniciar() {
    _programar(config.tiempoIniciales, _alVencerIniciales);
    _emitir();
  }

  /// Detiene los relojes sin anunciar nada (la sala se borró).
  void cancelar() {
    _reloj?.cancel();
    _reloj = null;
  }

  // ---------------------------------------------------------------------------
  // Mensajes de los jugadores
  // ---------------------------------------------------------------------------

  void manejar(String userId, String tipo, Map<String, Object?> msg) {
    final j = jugador(userId);
    if (j == null) throw ErrorProtocolo('sin_partida', 'No estás en esta partida.');
    if (fase == FasePartida.terminada) {
      throw ErrorProtocolo('no_es_momento', 'La partida ya terminó.');
    }
    if (!j.activo) throw ErrorProtocolo('no_es_momento', 'Ya no estás jugando.');

    switch (tipo) {
      case 'iniciales':
        _ponerIniciales(j, msg);
      case 'jugada':
        _jugar(j, msg);
      case 'pasar':
        _pasar(j);
      case 'conceder':
        rendir(userId);
      default:
        throw ErrorProtocolo('mensaje_desconocido', 'Tipo de mensaje desconocido.');
    }
  }

  void _ponerIniciales(JugadorPartida j, Map<String, Object?> msg) {
    if (fase != FasePartida.iniciales || j.yaJugo) {
      throw ErrorProtocolo('no_es_momento', 'Ya no se pueden poner números iniciales.');
    }
    final lista = msg['valores'];
    final valores = <Coordenada, int>{};
    if (lista is List && lista.length <= 10) {
      for (final v in lista) {
        if (v is List && v.length == 3 && v.every((x) => x is int)) {
          valores[Coordenada(v[0] as int, v[1] as int)] = v[2] as int;
        } else {
          valores.clear();
          break;
        }
      }
    }
    final error = valores.isEmpty
        ? 'Formato: {"valores": [[fila, columna, número], ...]}.'
        : errorEnValoresIniciales(j.nivel, valores);
    if (error != null) throw ErrorProtocolo('iniciales_invalidos', error);

    _colocarIniciales(j, valores);
    _emitir(evento: {'tipo': 'iniciales', 'nametag': j.nametag});
    _quizasAvanzar();
  }

  void _jugar(JugadorPartida j, Map<String, Object?> msg) {
    if (fase != FasePartida.jugando || j.yaJugo || j.completo) {
      throw ErrorProtocolo('no_es_momento', 'Ya jugaste en esta ronda.');
    }
    final ancla = _coordenada(msg['ancla']);
    final destino = _coordenada(msg['destino']);
    final numero = ancla == null || destino == null
        ? null
        : numeroDeJugada(j.tablero, j.celdas, dados!, ancla, destino);
    if (numero == null) {
      throw ErrorProtocolo('jugada_invalida', 'Esa jugada no es válida con estos dados.');
    }
    final antes = j.puntos;
    final zonasAntes = Set.of(j.lugares.keys);
    _colocar(j, destino!, numero);
    j.yaJugo = true;
    // Zonas que esta jugada dejó completas, con el lugar y los puntos que
    // dieron (para que la app avise a todos y tache los puntos ganados).
    final zonas = [
      for (final MapEntry(key: id, value: lugar) in j.lugares.entries)
        if (!zonasAntes.contains(id))
          {
            'zona': id,
            'lugar': lugar,
            'puntos': j.tablero.zonas[id]!.tipo.puntuaciones[lugar] ?? 0,
          },
    ];
    _emitir(evento: {
      'tipo': 'jugada',
      'nametag': j.nametag,
      'puntosGanados': j.puntos - antes,
      if (zonas.isNotEmpty) 'zonas': zonas,
      if (j.completo) 'completo': true,
    });
    _quizasAvanzar();
  }

  void _pasar(JugadorPartida j) {
    if (fase != FasePartida.jugando || j.yaJugo) {
      throw ErrorProtocolo('no_es_momento', 'Ya jugaste en esta ronda.');
    }
    j.yaJugo = true;
    _emitir(evento: {'tipo': 'paso', 'nametag': j.nametag});
    _quizasAvanzar();
  }

  // ---------------------------------------------------------------------------
  // Conexión, rendición y abandono (los llama el lobby)
  // ---------------------------------------------------------------------------

  /// [graciaSegundos] (al desconectarse): cuántos segundos tiene para volver
  /// antes de quedar fuera; se manda en el evento para que la app lo avise.
  void cambiarConexion(String userId, bool conectado, {int? graciaSegundos}) {
    final j = jugador(userId);
    if (j == null || j.conectado == conectado || fase == FasePartida.terminada) return;
    j.conectado = conectado;
    if (!conectado && graciaSegundos != null) {
      _esperaPorDesconexion = Duration(seconds: graciaSegundos);
    }
    _emitir(evento: {
      'tipo': conectado ? 'reconectado' : 'desconectado',
      'nametag': j.nametag,
      if (!conectado && graciaSegundos != null) 'graciaSegundos': graciaSegundos,
    });
    // Al reconectarse puede que ya hayan jugado todos los demás.
    if (conectado) _quizasAvanzar();
  }

  /// El jugador se rinde (o sale de la sala).
  void rendir(String userId) => _sacar(userId, EstadoJugador.concedio);

  /// El jugador se desconectó y no volvió a tiempo.
  void abandonar(String userId) => _sacar(userId, EstadoJugador.abandono);

  void _sacar(String userId, EstadoJugador estado) {
    final j = jugador(userId);
    if (j == null || !j.activo || fase == FasePartida.terminada) return;
    j.estado = estado;
    if (estado == EstadoJugador.abandono) j.conectado = false;
    _emitir(evento: {'tipo': estado.name, 'nametag': j.nametag});
    if (_activos.length <= 1) {
      _terminar(estado == EstadoJugador.concedio ? 'rendicion' : 'abandono');
    } else {
      _quizasAvanzar();
    }
  }

  // ---------------------------------------------------------------------------
  // Rondas
  // ---------------------------------------------------------------------------

  /// Si ya jugaron todos los que pueden, pasa a lo siguiente. Si no queda
  /// nadie conectado se espera al reloj (para no quemar rondas de golpe).
  ///
  /// Un jugador desconectado pero todavía en juego también frena la ronda:
  /// no se le pasan los turnos solos. Tiene unos segundos de gracia para
  /// volver; si no vuelve, el lobby lo saca (abandono) y la ronda sigue.
  void _quizasAvanzar() {
    if (fase == FasePartida.terminada) return;
    if (_activos.where((j) => j.conectado).isEmpty) return;
    final faltan = _activos.where((j) => !j.yaJugo && !j.completo);
    if (faltan.isNotEmpty) return;
    fase == FasePartida.iniciales ? _alVencerIniciales() : _cerrarRonda();
  }

  void _alVencerIniciales() {
    if (fase != FasePartida.iniciales) return;
    for (final j in _activos.where((j) => !j.yaJugo)) {
      _colocarIniciales(j, _inicialesAlAzar(j.nivel));
    }
    fase = FasePartida.jugando;
    _nuevaRonda();
  }

  void _alVencerTurno() {
    if (fase != FasePartida.jugando) return;
    // A nadie se le pasa el turno por haberse salido: mientras se espere a
    // alguien que perdió la conexión, la ronda se estira. El lobby lo saca al
    // vencer su tiempo de gracia (abandono) y entonces la ronda sigue sin él.
    final esperados = _activos.where((j) => !j.conectado && !j.yaJugo && !j.completo);
    if (esperados.isNotEmpty && _prorrogas < 3) {
      _prorrogas++;
      _programar(_esperaPorDesconexion + const Duration(seconds: 2), _alVencerTurno);
      _emitir();
      return;
    }
    final pasan = _activos.where((j) => !j.yaJugo && !j.completo).toList();
    for (final j in pasan) {
      j.yaJugo = true;
    }
    _cerrarRonda(pasaronPorTiempo: [for (final j in pasan) j.nametag]);
  }

  void _cerrarRonda({List<String> pasaronPorTiempo = const []}) {
    _completadasEnRonda.forEach((zona, n) {
      _completadasAntes[zona] = (_completadasAntes[zona] ?? 0) + n;
    });
    _completadasEnRonda.clear();

    // Se revisa al cerrar la ronda (todos juegan a la vez con los mismos
    // dados): si varios llegan en la misma ronda, gana el de más puntos.
    if (_activos.any((j) => j.puntos >= puntosMeta)) return _terminar('meta_puntos');
    if (_activos.any((j) => j.completo)) return _terminar('tablero_completo');
    if (ronda >= config.maxRondas) return _terminar('max_rondas');
    _nuevaRonda(pasaronPorTiempo: pasaronPorTiempo);
  }

  void _nuevaRonda({List<String> pasaronPorTiempo = const []}) {
    ronda++;
    _prorrogas = 0;
    dados = [_random.nextInt(6) + 1, _random.nextInt(6) + 1];
    for (final j in jugadores) {
      j.yaJugo = false;
    }
    _programar(config.tiempoTurno, _alVencerTurno);
    _emitir(evento: {
      'tipo': 'ronda',
      if (pasaronPorTiempo.isNotEmpty) 'pasaronPorTiempo': pasaronPorTiempo,
    });
  }

  void _terminar(String motivo) {
    _reloj?.cancel();
    _reloj = null;
    _limite = null;
    fase = FasePartida.terminada;
    motivoFin = motivo;
    resultados = _clasificacion();
    _difundir({
      'tipo': 'partida_terminada',
      'motivo': motivo,
      'resultados': resultados,
      'partida': toJson(),
    });
    _alTerminar(this);
  }

  /// Primero los que siguen en juego por puntos; después los que se rindieron
  /// o abandonaron. Empates en puntos comparten posición.
  List<Map<String, Object?>> _clasificacion() {
    final orden = [...jugadores]
      ..sort((a, b) {
        final grupo = (a.activo ? 0 : 1) - (b.activo ? 0 : 1);
        return grupo != 0 ? grupo : b.puntos - a.puntos;
      });
    final res = <Map<String, Object?>>[];
    for (var i = 0; i < orden.length; i++) {
      final j = orden[i];
      final anterior = i > 0 ? orden[i - 1] : null;
      final empata = anterior != null &&
          anterior.activo == j.activo &&
          anterior.puntos == j.puntos;
      res.add({
        'id': j.id,
        'nametag': j.nametag,
        'nivel': j.nivel.numero,
        'puntos': j.puntos,
        'estado': j.estado.name,
        'posicion': empata ? res.last['posicion'] : i + 1,
      });
    }
    return res;
  }

  // ---------------------------------------------------------------------------
  // Ayudas
  // ---------------------------------------------------------------------------

  void _colocarIniciales(JugadorPartida j, Map<Coordenada, int> valores) {
    valores.forEach((c, n) => _colocar(j, c, n));
    j.yaJugo = true;
  }

  /// Pone [numero] en [c]. Si con eso se completa la zona, se le asigna el
  /// lugar: 1 + cuántos la completaron en rondas anteriores.
  void _colocar(JugadorPartida j, Coordenada c, int numero) {
    j.tablero = j.tablero.agregarNumero(c, numero);
    j.celdas[c] = numero;
    final zona = j.tablero.zonaEn(c);
    if (zona != null && zona.estaCompleta && !j.lugares.containsKey(zona.id)) {
      j.lugares[zona.id] = 1 + (_completadasAntes[zona.id] ?? 0);
      _completadasEnRonda[zona.id] = (_completadasEnRonda[zona.id] ?? 0) + 1;
    }
  }

  Map<Coordenada, int> _inicialesAlAzar(Nivel nivel) {
    final casillas = nivel.casillasIniciales.toList();
    for (var intento = 0; intento < 5000; intento++) {
      final numeros = [1, 2, 3, 4, 5, 6]..shuffle(_random);
      final valores = {
        for (var i = 0; i < casillas.length; i++) casillas[i]: numeros[i % 6],
      };
      if (errorEnValoresIniciales(nivel, valores) == null) return valores;
    }
    throw StateError('El nivel ${nivel.numero} no admite números iniciales válidos.');
  }

  Coordenada? _coordenada(Object? v) {
    if (v is List && v.length == 2 && v[0] is int && v[1] is int) {
      return Coordenada(v[0] as int, v[1] as int);
    }
    return null;
  }

  void _programar(Duration d, void Function() alVencer) {
    _reloj?.cancel();
    _limite = DateTime.now().add(d);
    _reloj = Timer(d, alVencer);
  }

  void _emitir({Map<String, Object?>? evento}) =>
      _difundir({'tipo': 'partida', 'partida': toJson(), 'evento': ?evento});

  Map<String, Object?> toJson() {
    final limite = _limite;
    return {
      'fase': fase.name,
      'ronda': ronda,
      'maxRondas': config.maxRondas,
      'puntosMeta': puntosMeta,
      'dados': dados,
      'msRestantes': limite == null
          ? null
          : max(0, limite.difference(DateTime.now()).inMilliseconds),
      'jugadores': [for (final j in jugadores) j.toJson()],
    };
  }
}

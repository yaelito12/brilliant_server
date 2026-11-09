import 'dart:async';
import 'dart:math';

import 'package:brilliant_reglas/brilliant_reglas.dart' show nivelPorNumero;

import '../app.dart' show Usuario;
import 'partida.dart';
import 'protocolo.dart';
import 'sala.dart';

/// Lo que el lobby necesita de una conexión. Así la lógica no depende de
/// WebSocket y se puede probar sola.
abstract class Conexion {
  void enviar(Map<String, Object?> mensaje);
  void cerrar(int codigo, String razon);
}

class ConfigMultijugador {
  final int minJugadores;
  final int maxJugadores;

  /// Tiempo que se guarda el lugar de un jugador desconectado antes de
  /// sacarlo de la sala.
  final Duration graciaReconexion;

  /// Tiempo para mandar el mensaje `auth` después de conectarse.
  final Duration tiempoAuth;

  /// Cada cuánto se manda un ping de WebSocket. Si el otro lado no
  /// responde, la conexión se da por perdida (detecta Wi-Fi caído, app
  /// cerrada a la fuerza, etc.).
  final Duration intervaloPing;

  final int maxBytesMensaje;
  final int maxMensajesPorSegundo;

  /// Tiempos y límite de rondas de cada partida.
  final ConfigPartida partida;

  const ConfigMultijugador({
    this.minJugadores = 2,
    this.maxJugadores = 6,
    this.graciaReconexion = const Duration(seconds: 30),
    this.tiempoAuth = const Duration(seconds: 10),
    this.intervaloPing = const Duration(seconds: 15),
    this.maxBytesMensaje = 4096,
    this.maxMensajesPorSegundo = 20,
    this.partida = const ConfigPartida(),
  });

  factory ConfigMultijugador.desdeEnv(Map<String, String> env) {
    int valor(String clave, int porDefecto) {
      final n = int.tryParse(env[clave] ?? '');
      return n != null && n > 0 ? n : porDefecto;
    }

    return ConfigMultijugador(
      graciaReconexion: Duration(seconds: valor('RECONNECT_GRACE_SECONDS', 30)),
      partida: ConfigPartida(
        tiempoIniciales: Duration(seconds: valor('INITIAL_VALUES_SECONDS', 90)),
        tiempoTurno: Duration(seconds: valor('TURN_SECONDS', 60)),
        maxRondas: valor('MAX_ROUNDS', 100),
      ),
    );
  }
}

/// Salas y jugadores conectados. Toda la lógica del lobby vive aquí:
/// crear sala, unirse con código, elegir mapa, listo, salir, desconexiones.
/// Cuando todos están listos crea la [Partida] y le pasa los mensajes de juego.
class Lobby {
  final ConfigMultijugador config;
  final Random _random;
  final _salas = <String, Sala>{};
  final _salaDe = <String, Sala>{}; // userId -> sala
  final _conexionDe = <String, Conexion>{}; // userId -> conexión activa
  final _usuarioDe = Map<Conexion, Usuario>.identity();

  Lobby({this.config = const ConfigMultijugador(), Random? random})
    : _random = random ?? Random.secure();

  int get cantidadSalas => _salas.length;
  Sala? sala(String codigo) => _salas[codigo];
  Sala? salaDe(String userId) => _salaDe[userId];

  // ---------------------------------------------------------------------------
  // Conexiones
  // ---------------------------------------------------------------------------

  /// Un usuario se autenticó en [c]. Si ya tenía otra conexión, la vieja se
  /// cierra. Si estaba en una sala (se había caído), vuelve a ella.
  void conectar(Usuario u, Conexion c) {
    final vieja = _conexionDe[u.id];
    if (vieja != null && !identical(vieja, c)) {
      _usuarioDe.remove(vieja);
      vieja.enviar(mensajeError(
        'sesion_reemplazada',
        'Se abrió tu cuenta en otra conexión.',
      ));
      vieja.cerrar(CodigoCierre.sesionReemplazada, 'sesion_reemplazada');
    }
    _conexionDe[u.id] = c;
    _usuarioDe[c] = u;

    final sala = _salaDe[u.id];
    final j = sala?.jugador(u.id);
    c.enviar({
      'tipo': 'autenticado',
      'user': {'id': u.id, 'nametag': u.nametag},
      'sala': sala?.toJson(),
    });
    if (sala != null && j != null && !j.conectado) {
      j.conectado = true;
      j.temporizadorSalida?.cancel();
      j.temporizadorSalida = null;
      _difundir(sala, evento: {'tipo': 'reconectado', 'nametag': j.nametag});
      sala.partida?.cambiarConexion(u.id, true);
    }
    // Si hay partida en curso, se le manda el estado completo para seguir
    // donde iba (su tablero, los dados de la ronda y si ya jugó).
    final partida = sala?.partida;
    if (partida != null) c.enviar({'tipo': 'partida', 'partida': partida.toJson()});
  }

  /// La conexión [c] se cerró (o se perdió). Si su dueño estaba en una sala,
  /// se le guarda el lugar durante [ConfigMultijugador.graciaReconexion].
  void desconectar(Conexion c) {
    final u = _usuarioDe.remove(c);
    if (u == null || !identical(_conexionDe[u.id], c)) return; // ya reemplazada
    _conexionDe.remove(u.id);

    final sala = _salaDe[u.id];
    final j = sala?.jugador(u.id);
    if (sala == null || j == null) return;

    j.conectado = false;
    j.listo = false; // nadie empieza con un jugador caído
    j.temporizadorSalida?.cancel();
    j.temporizadorSalida = Timer(config.graciaReconexion, () {
      if (!j.conectado && identical(_salaDe[u.id], sala)) {
        sala.partida?.abandonar(u.id); // en partida: cuenta como abandono
        _quitar(sala, j, motivo: 'abandono');
      }
    });
    _difundir(sala, evento: {'tipo': 'desconectado', 'nametag': j.nametag});
    sala.partida?.cambiarConexion(u.id, false);
  }

  /// Procesa un mensaje del cliente. Los errores de negocio se le contestan
  /// solo a él como `{"tipo":"error"}`; la conexión sigue abierta.
  void manejar(Conexion c, Map<String, Object?> msg) {
    final u = _usuarioDe[c];
    if (u == null) return;
    final tipo = msg['tipo'];
    try {
      switch (tipo) {
        case 'crear_sala':
          _crearSala(u, c, _nivel(msg));
        case 'unirse':
          // El mapa es opcional: basta el código para unirse.
          _unirse(u, c, _codigo(msg), msg['nivel'] == null ? null : _nivel(msg));
        case 'elegir_mapa':
          _elegirMapa(u, _nivel(msg));
        case 'listo':
          final v = msg['listo'];
          if (v is! bool) throw ErrorProtocolo('mensaje_invalido', 'Falta "listo" (true o false).');
          _listo(u, v);
        case 'salir':
          _salir(u, c);
        case 'ping':
          c.enviar({'tipo': 'pong'});
        case 'iniciales' || 'jugada' || 'pasar' || 'conceder':
          final partida = _salaDe[u.id]?.partida;
          if (partida == null) {
            throw ErrorProtocolo('sin_partida', 'No hay una partida en curso.');
          }
          partida.manejar(u.id, tipo as String, msg);
        default:
          throw ErrorProtocolo('mensaje_desconocido', 'Tipo de mensaje desconocido.');
      }
    } on ErrorProtocolo catch (e) {
      c.enviar(mensajeError(e.code, e.message, en: tipo is String ? tipo : null));
    }
  }

  /// Cierra todo (al apagar el servidor).
  void cerrar() {
    for (final s in _salas.values) {
      s.partida?.cancelar();
      for (final j in s.jugadores) {
        j.temporizadorSalida?.cancel();
      }
    }
    for (final c in _conexionDe.values.toList()) {
      c.cerrar(CodigoCierre.apagando, 'apagando');
    }
    _salas.clear();
    _salaDe.clear();
    _conexionDe.clear();
    _usuarioDe.clear();
  }

  // ---------------------------------------------------------------------------
  // Acciones
  // ---------------------------------------------------------------------------

  void _crearSala(Usuario u, Conexion c, int nivel) {
    if (_salaDe.containsKey(u.id)) {
      throw ErrorProtocolo('ya_en_sala', 'Ya estás en una sala. Sal de ella primero.');
    }
    final sala = Sala(
      codigo: _nuevoCodigo(),
      minJugadores: config.minJugadores,
      maxJugadores: config.maxJugadores,
    );
    sala.jugadores.add(JugadorSala(u, nivel));
    _salas[sala.codigo] = sala;
    _salaDe[u.id] = sala;
    _difundir(sala, evento: {'tipo': 'creada', 'nametag': u.nametag});
  }

  /// Si no se dice [nivel], el jugador empieza con el mapa de quien creó la
  /// sala (el primero de la lista); lo puede cambiar después en el lobby.
  void _unirse(Usuario u, Conexion c, String codigo, int? nivel) {
    final actual = _salaDe[u.id];
    if (actual != null) {
      if (actual.codigo == codigo) {
        c.enviar({'tipo': 'sala', 'sala': actual.toJson()}); // reintento: no pasa nada
        return;
      }
      throw ErrorProtocolo('ya_en_sala', 'Ya estás en una sala. Sal de ella primero.');
    }
    final sala = _salas[codigo];
    if (sala == null) {
      throw ErrorProtocolo('sala_no_encontrada', 'No existe una sala con ese código.');
    }
    if (sala.estado != EstadoSala.lobby) {
      throw ErrorProtocolo('partida_en_curso', 'Esa partida ya empezó.');
    }
    if (sala.llena) {
      throw ErrorProtocolo('sala_llena', 'La sala ya tiene ${sala.maxJugadores} jugadores.');
    }
    sala.jugadores.add(JugadorSala(u, nivel ?? sala.jugadores.first.nivel));
    _salaDe[u.id] = sala;
    _difundir(sala, evento: {'tipo': 'unido', 'nametag': u.nametag});
  }

  void _elegirMapa(Usuario u, int nivel) {
    final (sala, j) = _enLobby(u);
    if (j.nivel == nivel) return;
    j.nivel = nivel;
    j.listo = false; // cambió algo: tiene que volver a confirmar
    _difundir(sala);
  }

  void _listo(Usuario u, bool listo) {
    final (sala, j) = _enLobby(u);
    if (j.listo == listo) return;
    j.listo = listo;
    _difundir(sala);
    _intentarIniciar(sala);
  }

  void _salir(Usuario u, Conexion c) {
    final sala = _salaDe[u.id];
    final j = sala?.jugador(u.id);
    if (sala == null || j == null) {
      throw ErrorProtocolo('no_en_sala', 'No estás en ninguna sala.');
    }
    sala.partida?.rendir(u.id); // salir en plena partida = conceder
    _quitar(sala, j, motivo: 'salio');
    c.enviar({'tipo': 'saliste'});
  }

  // ---------------------------------------------------------------------------
  // Ayudas
  // ---------------------------------------------------------------------------

  (Sala, JugadorSala) _enLobby(Usuario u) {
    final sala = _salaDe[u.id];
    final j = sala?.jugador(u.id);
    if (sala == null || j == null) {
      throw ErrorProtocolo('no_en_sala', 'No estás en ninguna sala.');
    }
    if (sala.estado != EstadoSala.lobby) {
      throw ErrorProtocolo('partida_en_curso', 'La partida ya empezó.');
    }
    return (sala, j);
  }

  void _quitar(Sala sala, JugadorSala j, {required String motivo}) {
    j.temporizadorSalida?.cancel();
    sala.jugadores.remove(j);
    _salaDe.remove(j.id);
    if (sala.jugadores.isEmpty) {
      sala.partida?.cancelar();
      _salas.remove(sala.codigo);
      return;
    }
    _difundir(sala, evento: {'tipo': motivo, 'nametag': j.nametag});
    // Si el que se fue era el único que faltaba, los demás ya pueden empezar.
    _intentarIniciar(sala);
  }

  void _intentarIniciar(Sala sala) {
    if (sala.estado != EstadoSala.lobby || !sala.todosListos) return;
    sala.estado = EstadoSala.jugando;
    _difundir(sala, tipo: 'partida_iniciada');
    sala.partida = Partida(
      config: config.partida,
      random: _random,
      jugadores: [
        for (final j in sala.jugadores)
          JugadorPartida(id: j.id, nametag: j.nametag, nivel: nivelPorNumero(j.nivel)!),
      ],
      difundir: (msg) => _enviarATodos(sala, msg),
      alTerminar: (_) => _finDePartida(sala),
    )..iniciar();
  }

  /// Al terminar la partida la sala vuelve al lobby (para la revancha).
  /// Los que abandonaron ya no están; los demás tienen que volver a dar "listo".
  void _finDePartida(Sala sala) {
    sala.partida = null;
    sala.estado = EstadoSala.lobby;
    for (final j in sala.jugadores) {
      j.listo = false;
    }
    if (sala.jugadores.isNotEmpty) _difundir(sala, evento: {'tipo': 'fin_partida'});
  }

  /// Manda el estado de la sala a todos sus jugadores conectados.
  void _difundir(Sala sala, {String tipo = 'sala', Map<String, Object?>? evento}) =>
      _enviarATodos(sala, {'tipo': tipo, 'sala': sala.toJson(), 'evento': ?evento});

  void _enviarATodos(Sala sala, Map<String, Object?> msg) {
    for (final j in sala.jugadores) {
      _conexionDe[j.id]?.enviar(msg);
    }
  }

  int _nivel(Map<String, Object?> msg) {
    final n = msg['nivel'];
    if (n is! int || nivelPorNumero(n) == null) {
      throw ErrorProtocolo('mapa_invalido', 'Ese mapa no existe.');
    }
    return n;
  }

  String _codigo(Map<String, Object?> msg) {
    final c = msg['codigo'];
    final codigo = c is String ? c.trim().toUpperCase() : '';
    if (!formatoCodigo.hasMatch(codigo)) {
      throw ErrorProtocolo('sala_no_encontrada', 'No existe una sala con ese código.');
    }
    return codigo;
  }

  String _nuevoCodigo() {
    while (true) {
      final codigo = String.fromCharCodes(List.generate(
        largoCodigo,
        (_) => alfabetoCodigo.codeUnitAt(_random.nextInt(alfabetoCodigo.length)),
      ));
      if (!_salas.containsKey(codigo)) return codigo;
    }
  }
}

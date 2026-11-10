import 'dart:async';

import '../app.dart' show Usuario;
import 'partida.dart';

enum EstadoSala { lobby, jugando }

/// Un jugador dentro de una sala.
class JugadorSala {
  final String id;
  final String nametag;

  /// Número del mapa (nivel oficial). Es el mismo para toda la sala.
  int nivel;
  bool listo = false;
  bool conectado = true;

  /// Mientras está desconectado: cuenta atrás para sacarlo de la sala.
  Timer? temporizadorSalida;

  JugadorSala(Usuario u, this.nivel) : id = u.id, nametag = u.nametag;

  Map<String, Object?> toJson() => {
    'id': id,
    'nametag': nametag,
    'nivel': nivel,
    'listo': listo,
    'conectado': conectado,
  };
}

/// Una sala de juego. Se crea con un código de invitación y empieza cuando
/// hay entre [minJugadores] y [maxJugadores] y todos dieron "listo".
class Sala {
  final String codigo;
  final int minJugadores;
  final int maxJugadores;
  EstadoSala estado = EstadoSala.lobby;

  /// En orden de llegada.
  final List<JugadorSala> jugadores = [];

  /// La partida en curso (solo con [estado] == jugando).
  Partida? partida;

  Sala({
    required this.codigo,
    required this.minJugadores,
    required this.maxJugadores,
  });

  JugadorSala? jugador(String userId) {
    for (final j in jugadores) {
      if (j.id == userId) return j;
    }
    return null;
  }

  bool get llena => jugadores.length >= maxJugadores;

  /// Mapa de la sala: todos juegan el mismo (el que eligió el anfitrión,
  /// que es el primero de [jugadores]).
  int get nivel => jugadores.first.nivel;

  /// true si ya se puede empezar: suficientes jugadores, todos conectados y listos.
  bool get todosListos =>
      jugadores.length >= minJugadores &&
      jugadores.every((j) => j.listo && j.conectado);

  Map<String, Object?> toJson() => {
    'codigo': codigo,
    'estado': estado.name,
    'minJugadores': minJugadores,
    'maxJugadores': maxJugadores,
    if (jugadores.isNotEmpty) 'nivel': nivel,
    'jugadores': [for (final j in jugadores) j.toJson()],
  };
}

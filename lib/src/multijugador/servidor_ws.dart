import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../app.dart' show Usuario;
import 'lobby.dart';
import 'protocolo.dart';

class _ConexionWs implements Conexion {
  final WebSocketChannel ws;
  bool cerrada = false;

  /// Dueño y sesión de la conexión (después de autenticarse).
  String? userId;
  String? sesion;
  _ConexionWs(this.ws);

  @override
  void enviar(Map<String, Object?> mensaje) {
    if (!cerrada) ws.sink.add(jsonEncode(mensaje));
  }

  @override
  void cerrar(int codigo, String razon) {
    if (cerrada) return;
    cerrada = true;
    ws.sink.close(codigo, razon);
  }
}

/// Puerta de entrada `/ws`: autentica, filtra mensajes malos y le pasa el
/// resto al [Lobby].
///
/// Autenticación: el primer mensaje debe ser `{"tipo":"auth","token":"<access>"}`.
/// Así funciona en todas las plataformas (Flutter Web no deja poner
/// cabeceras al WebSocket) y el token nunca va en la URL (que queda en logs).
class ServidorWs {
  final Lobby lobby;
  final ({Usuario usuario, String sesion})? Function(String? token) autenticar;

  /// true si la sesión sigue abierta (ver [revisarSesiones]).
  final bool Function(String userId, String sesion) sesionActiva;
  final _abiertas = <_ConexionWs>{};

  ServidorWs({required this.lobby, required this.autenticar, required this.sesionActiva});

  /// Corta las conexiones de [userId] cuya sesión ya se cerró (por ejemplo,
  /// porque entró con su cuenta en otro dispositivo). La app recibe el
  /// código 4004 y vuelve a la pantalla de inicio de sesión.
  /// true si [userId] tiene una conexión abierta (cuenta como sesión en uso).
  bool tieneConexion(String userId) =>
      _abiertas.any((c) => c.userId == userId && !c.cerrada);

  void revisarSesiones(String userId) {
    for (final c in _abiertas.toList()) {
      final sesion = c.sesion;
      if (c.userId != userId || sesion == null || sesionActiva(userId, sesion)) continue;
      c.enviar(mensajeError(
        'sesion_cerrada',
        'Se inició sesión con tu cuenta en otro dispositivo.',
      ));
      c.cerrar(CodigoCierre.sesionCerrada, 'sesion_cerrada');
    }
  }

  ConfigMultijugador get _config => lobby.config;

  Handler get handler => webSocketHandler(
    (WebSocketChannel ws, String? _) => _alConectar(ws),
    pingInterval: _config.intervaloPing,
  );

  void _alConectar(WebSocketChannel ws) {
    final con = _ConexionWs(ws);
    _abiertas.add(con);
    var autenticado = false;

    void cortar(int codigo, String code, String mensaje) {
      con.enviar(mensajeError(code, mensaje));
      con.cerrar(codigo, code);
    }

    final relojAuth = Timer(_config.tiempoAuth, () {
      if (!autenticado) {
        cortar(CodigoCierre.noAutenticado, 'no_autenticado', 'No te autenticaste a tiempo.');
      }
    });

    // Límite de mensajes por segundo (ventana fija de 1 s).
    var inicioVentana = DateTime.now();
    var enVentana = 0;

    ws.stream.listen(
      (dato) {
        if (con.cerrada) return;

        final ahora = DateTime.now();
        if (ahora.difference(inicioVentana) >= const Duration(seconds: 1)) {
          inicioVentana = ahora;
          enVentana = 0;
        }
        if (++enVentana > _config.maxMensajesPorSegundo) {
          return cortar(CodigoCierre.protocolo, 'demasiados_mensajes', 'Demasiados mensajes.');
        }
        if (dato is! String || dato.length > _config.maxBytesMensaje) {
          return cortar(CodigoCierre.protocolo, 'mensaje_invalido', 'Mensaje demasiado grande o binario.');
        }

        Map<String, Object?> msg;
        try {
          final d = jsonDecode(dato);
          if (d is! Map<String, Object?>) throw const FormatException();
          msg = d;
        } on FormatException {
          con.enviar(mensajeError('mensaje_invalido', 'El mensaje no es un objeto JSON.'));
          return;
        }

        if (!autenticado) {
          final token = msg['token'];
          final s = msg['tipo'] == 'auth' && token is String ? autenticar(token) : null;
          if (s == null) {
            return cortar(CodigoCierre.noAutenticado, 'no_autenticado', 'Sesión inválida o vencida.');
          }
          autenticado = true;
          relojAuth.cancel();
          con
            ..userId = s.usuario.id
            ..sesion = s.sesion;
          lobby.conectar(s.usuario, con);
          return;
        }
        if (msg['tipo'] == 'auth') return; // ya autenticado: se ignora
        lobby.manejar(con, msg);
      },
      onDone: () {
        relojAuth.cancel();
        con.cerrada = true;
        _abiertas.remove(con);
        lobby.desconectar(con);
      },
      onError: (_) {}, // un socket roto termina en onDone
      cancelOnError: false,
    );
  }

  /// Cierra todas las conexiones (al apagar el servidor).
  void cerrar() {
    lobby.cerrar();
    for (final c in _abiertas.toList()) {
      c.cerrar(CodigoCierre.apagando, 'apagando');
    }
  }
}

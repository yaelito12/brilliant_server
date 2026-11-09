/// Protocolo del WebSocket `/ws`. Todos los mensajes son objetos JSON con un
/// campo `tipo`. Ver `server/MULTIJUGADOR.md` para la lista completa.
library;

/// Códigos de cierre propios (rango 4000-4999 reservado para aplicaciones).
abstract final class CodigoCierre {
  /// Token ausente, inválido o vencido: la app debe renovarlo y reconectar.
  static const noAutenticado = 4001;

  /// El mismo usuario abrió otra conexión (otra pestaña u otro dispositivo).
  static const sesionReemplazada = 4002;

  /// Mensaje demasiado grande, binario o demasiados mensajes por segundo.
  static const protocolo = 4003;

  /// La sesión se cerró (se entró con la cuenta en otro dispositivo, se cerró
  /// sesión o se borró la cuenta). La app debe volver al inicio de sesión.
  static const sesionCerrada = 4004;

  /// El servidor se está apagando.
  static const apagando = 4000;
}

/// Letras y números sin los que se confunden (0/O, 1/I/L).
const alfabetoCodigo = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const largoCodigo = 6;
final formatoCodigo = RegExp('^[$alfabetoCodigo]{$largoCodigo}\$');

/// Error que se manda al cliente como `{"tipo":"error","code":...}`.
class ErrorProtocolo implements Exception {
  final String code;
  final String message;
  ErrorProtocolo(this.code, this.message);

  @override
  String toString() => 'ErrorProtocolo($code)';
}

Map<String, Object?> mensajeError(String code, String message, {Object? en}) => {
  'tipo': 'error',
  'code': code,
  'message': message,
  'en': ?en,
};

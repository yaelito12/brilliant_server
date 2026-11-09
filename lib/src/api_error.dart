/// Error de negocio que se convierte en `{"error": {"code", "message", ...extra}}`.
class ApiError implements Exception {
  final int status;
  final String code;
  final String message;
  final Map<String, Object?> extra;

  ApiError(this.status, this.code, this.message, [this.extra = const {}]);

  Map<String, Object?> toJson() => {
    'error': {'code': code, 'message': message, ...extra},
  };

  @override
  String toString() => 'ApiError($status, $code)';
}

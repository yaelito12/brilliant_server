import 'api_error.dart';

// Con contraseñas de solo 6 caracteres esta lista importa más: evita las más obvias.
const _contrasenasComunes = {
  '123456', '1234567', '12345678', '123456789', '1234567890', '654321', '111111',
  '000000', '123123', '121212', '123321', '112233', 'abc123', 'abcdef', 'qwerty',
  'qwerty1', 'qwerty123', 'qwertyuiop', 'password', 'password1', 'password123',
  'contraseña', 'contrasena', 'contrasena1', 'iloveyou', 'admin123', 'letmein',
  'brilliant', 'brilliant1', 'brilliant123',
};

const minPassword = 6;
const maxPassword = 128;

// 3 a 20 caracteres: letras sin acentos, números, punto, guion y guion bajo.
// Sin espacios ni letras raras, para que nadie pueda hacerse pasar por otro
// usando caracteres que se ven iguales.
final _formatoNametag = RegExp(r'^[A-Za-z0-9_.-]+$');
final _repetida = RegExp(r'^(.)\1+$');

/// Junta los errores por campo (solo el primero de cada uno) y, si hay alguno,
/// lanza un 400 `validacion` con `{campos: {...}}`.
class _Errores {
  final campos = <String, String>{};
  void add(String campo, String mensaje) => campos.putIfAbsent(campo, () => mensaje);
  void lanzarSiHay() {
    if (campos.isNotEmpty) {
      throw ApiError(400, 'validacion', 'Hay datos inválidos.', {'campos': campos});
    }
  }
}

/// Devuelve el texto si es un String, o registra [obligatorio] y devuelve null.
String? _texto(Map<String, Object?> d, String campo, _Errores e, String obligatorio) {
  final v = d[campo];
  if (v is String) return v;
  e.add(campo, obligatorio);
  return null;
}

String? _largo(String v, int min, int max, String msgMin, String msgMax) {
  if (v.length < min) return msgMin;
  if (v.length > max) return msgMax;
  return null;
}

typedef Credenciales = ({String nametag, String password});

Credenciales validarRegistro(Map<String, Object?> d) {
  final e = _Errores();
  final nametag = _texto(d, 'nametag', e, 'El nametag es obligatorio.')?.trim();
  final password = _texto(d, 'password', e, 'La contraseña es obligatoria.');

  if (nametag != null) {
    final error = _largo(
          nametag,
          3,
          20,
          'El nametag debe tener al menos 3 caracteres.',
          'El nametag no puede pasar de 20 caracteres.',
        ) ??
        (_formatoNametag.hasMatch(nametag)
            ? null
            : 'El nametag solo puede tener letras, números, punto, guion y guion bajo.');
    if (error != null) e.add('nametag', error);
  }
  if (password != null) {
    final error = _largo(
      password,
      minPassword,
      maxPassword,
      'La contraseña debe tener al menos $minPassword caracteres.',
      'La contraseña no puede pasar de $maxPassword caracteres.',
    );
    if (error != null) e.add('password', error);
  }
  e.lanzarSiHay();

  final p = password!.toLowerCase();
  if (_contrasenasComunes.contains(p) || p == nametag!.toLowerCase() || _repetida.hasMatch(p)) {
    e.add('password', 'Esa contraseña es demasiado fácil de adivinar.');
  }
  e.lanzarSiHay();
  return (nametag: nametag!, password: password);
}

// Al iniciar sesión no se revisa el formato (solo que no sea absurdo): así nunca
// se revela qué reglas tiene un nametag y se evita trabajo inútil.
Credenciales validarLogin(Map<String, Object?> d) {
  final e = _Errores();
  final nametag = _texto(d, 'nametag', e, 'El nametag es obligatorio.')?.trim();
  final password = _texto(d, 'password', e, 'La contraseña es obligatoria.');
  if (nametag != null && (nametag.isEmpty || nametag.length > 40)) {
    e.add('nametag', 'El nametag es obligatorio.');
  }
  if (password != null && (password.isEmpty || password.length > maxPassword)) {
    e.add('password', 'La contraseña es obligatoria.');
  }
  e.lanzarSiHay();
  return (nametag: nametag!, password: password!);
}

String validarRefresh(Map<String, Object?> d) {
  final e = _Errores();
  final t = _texto(d, 'refreshToken', e, 'El refresh token es obligatorio.');
  if (t != null && (t.length < 20 || t.length > 200)) {
    e.add('refreshToken', 'El refresh token no es válido.');
  }
  e.lanzarSiHay();
  return t!;
}

String validarBorrarCuenta(Map<String, Object?> d) {
  final e = _Errores();
  final p = _texto(d, 'password', e, 'La contraseña es obligatoria.');
  if (p != null && (p.isEmpty || p.length > maxPassword)) {
    e.add('password', 'La contraseña es obligatoria.');
  }
  e.lanzarSiHay();
  return p!;
}

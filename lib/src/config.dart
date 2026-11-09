// Configuración del servidor. Todo sale de variables de entorno (ver .env.example).
// Si falta algo crítico (por ejemplo JWT_SECRET) el servidor NO arranca.

const minSecretLength = 32;

class ParametrosArgon2 {
  final int memoriaKiB;
  final int iteraciones;
  final int paralelismo;
  const ParametrosArgon2({
    required this.memoriaKiB,
    required this.iteraciones,
    required this.paralelismo,
  });
}

class Config {
  final bool produccion;
  final int puerto;
  final String dbPath;
  final String jwtSecret;

  /// Pepper opcional: secreto extra que se mezcla con el hash de Argon2.
  /// OJO: si lo cambias, todas las contraseñas existentes dejan de funcionar.
  final String? passwordPepper;

  final int accessTtlSeg;
  final int refreshTtlSeg;
  final ParametrosArgon2 argon2;

  /// Bloqueo de cuenta por intentos fallidos (por nametag, exista o no).
  final int maxIntentosFallidos;
  final int bloqueoSeg;

  /// Límite de peticiones por IP (por ventana de 15 min).
  final int limiteGlobal;
  final int limiteAuth;

  /// Orígenes permitidos para CORS (solo necesario si usas Flutter Web).
  final List<String> corsOrigins;

  /// Detrás de un proxy inverso (nginx, Caddy, Render, Fly...) pon TRUST_PROXY=1
  /// para que el límite por IP y la detección de HTTPS usen la IP/protocolo reales.
  /// Es el número de proxies de confianza (0 = ninguno).
  final int trustProxy;
  final bool requireHttps;

  /// Una sesión cuenta como "en uso" si dio señales de vida (la app avisa cada
  /// minuto) en estos segundos. Mientras esté en uso no se puede entrar con
  /// la misma cuenta en otro dispositivo.
  final int sesionActivaSeg;

  const Config({
    required this.produccion,
    required this.puerto,
    required this.dbPath,
    required this.jwtSecret,
    required this.passwordPepper,
    required this.accessTtlSeg,
    required this.refreshTtlSeg,
    required this.argon2,
    required this.maxIntentosFallidos,
    required this.bloqueoSeg,
    required this.limiteGlobal,
    required this.limiteAuth,
    required this.corsOrigins,
    required this.trustProxy,
    required this.requireHttps,
    this.sesionActivaSeg = 150,
  });

  Config copyWith({
    ParametrosArgon2? argon2,
    int? limiteGlobal,
    int? limiteAuth,
    bool? requireHttps,
    int? sesionActivaSeg,
    List<String>? corsOrigins,
  }) => Config(
    produccion: produccion,
    puerto: puerto,
    dbPath: dbPath,
    jwtSecret: jwtSecret,
    passwordPepper: passwordPepper,
    accessTtlSeg: accessTtlSeg,
    refreshTtlSeg: refreshTtlSeg,
    argon2: argon2 ?? this.argon2,
    maxIntentosFallidos: maxIntentosFallidos,
    bloqueoSeg: bloqueoSeg,
    limiteGlobal: limiteGlobal ?? this.limiteGlobal,
    limiteAuth: limiteAuth ?? this.limiteAuth,
    corsOrigins: corsOrigins ?? this.corsOrigins,
    trustProxy: trustProxy,
    requireHttps: requireHttps ?? this.requireHttps,
    sesionActivaSeg: sesionActivaSeg ?? this.sesionActivaSeg,
  );
}

class ConfigInvalida implements Exception {
  final String mensaje;
  ConfigInvalida(this.mensaje);
  @override
  String toString() => mensaje;
}

int _entero(String? valor, int porDefecto) {
  if (valor == null || valor.isEmpty) return porDefecto;
  final n = int.tryParse(valor.trim());
  if (n == null || n <= 0) {
    throw ConfigInvalida('Valor numérico inválido en la configuración: "$valor"');
  }
  return n;
}

Config cargarConfig(Map<String, String> env) {
  final produccion = env['NODE_ENV'] == 'production' || env['ENV'] == 'production';

  final jwtSecret = env['JWT_SECRET'] ?? '';
  if (jwtSecret.length < minSecretLength) {
    throw ConfigInvalida(
      'JWT_SECRET es obligatorio y debe tener al menos $minSecretLength caracteres. '
      'Genera uno con: dart run bin/gen_secret.dart',
    );
  }

  final pepper = env['PASSWORD_PEPPER'];
  final requireHttps = env['REQUIRE_HTTPS'];

  return Config(
    produccion: produccion,
    puerto: _entero(env['PORT'], 3000),
    dbPath: (env['DB_PATH'] ?? '').isEmpty ? './data/brilliant.db' : env['DB_PATH']!,
    jwtSecret: jwtSecret,
    passwordPepper: (pepper == null || pepper.isEmpty) ? null : pepper,
    accessTtlSeg: _entero(env['ACCESS_TOKEN_TTL_SECONDS'], 15 * 60), // 15 min
    refreshTtlSeg: _entero(env['REFRESH_TOKEN_TTL_SECONDS'], 30 * 24 * 3600), // 30 días
    // Argon2id. OWASP recomienda como mínimo m=19 MiB, t=2, p=1.
    argon2: ParametrosArgon2(
      memoriaKiB: _entero(env['ARGON2_MEMORY_KIB'], 19456),
      iteraciones: _entero(env['ARGON2_TIME_COST'], 2),
      paralelismo: _entero(env['ARGON2_PARALLELISM'], 1),
    ),
    maxIntentosFallidos: _entero(env['MAX_FAILED_LOGINS'], 5),
    bloqueoSeg: _entero(env['LOCKOUT_SECONDS'], 15 * 60),
    limiteGlobal: _entero(env['RATE_LIMIT_GLOBAL'], 300),
    limiteAuth: _entero(env['RATE_LIMIT_AUTH'], 20),
    corsOrigins: (env['CORS_ORIGINS'] ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(),
    trustProxy: (env['TRUST_PROXY'] ?? '').isEmpty ? 0 : _entero(env['TRUST_PROXY'], 1),
    requireHttps: requireHttps != null && requireHttps.isNotEmpty
        ? requireHttps == 'true'
        : produccion,
    sesionActivaSeg: _entero(env['SESSION_ACTIVE_SECONDS'], 150),
  );
}

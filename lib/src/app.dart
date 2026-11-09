import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import 'api_error.dart';
import 'config.dart';
import 'http_util.dart';
import 'seguridad.dart';
import 'validacion.dart';

typedef Usuario = ({String id, String nametag});

int _ahora() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Servidor HTTP de cuentas: crear cuenta, iniciar/cerrar sesión, borrar cuenta.
class AppAuth {
  final Config config;
  final Database db;
  final Seguridad seg;
  final LimitePorIp _limiteGlobal;
  final LimitePorIp _limiteAuth;
  late final Handler handler;

  /// Manejador de `/ws` (partidas en tiempo real). Se asigna después de crear
  /// la app porque necesita [autenticarToken].
  Handler? webSocket;

  /// Se llama cuando se cierran sesiones de un usuario (otro inicio de
  /// sesión, cerrar sesión, borrar la cuenta). El multijugador lo usa para
  /// cortar al instante las conexiones de esas sesiones.
  void Function(String userId)? alCerrarSesiones;

  /// true si el usuario tiene una conexión abierta en el multijugador (la
  /// asigna el servidor de partidas). Cuenta como "sesión en uso".
  bool Function(String userId)? tieneConexionAbierta;

  AppAuth({required this.config, required this.db, this.webSocket})
    : seg = Seguridad(config),
      _limiteGlobal = LimitePorIp(
        ventana: const Duration(minutes: 15),
        limite: config.limiteGlobal,
      ),
      _limiteAuth = LimitePorIp(
        ventana: const Duration(minutes: 15),
        limite: config.limiteAuth,
      ) {
    // CORS va por fuera de todo: así también las respuestas de error (401,
    // 409, 429...) llevan el permiso. Si no, el navegador las bloquea y la
    // app en la web solo ve "no se pudo conectar" en vez del mensaje real.
    var pipeline = const Pipeline();
    if (config.corsOrigins.isNotEmpty) {
      pipeline = pipeline.addMiddleware(cors(config.corsOrigins));
    }
    pipeline = pipeline.addMiddleware(manejarErrores());
    if (config.requireHttps) pipeline = pipeline.addMiddleware(exigirHttps(config));
    handler = pipeline
        .addMiddleware(limitarPorIp(_limiteGlobal, config))
        .addHandler(_rutas().call);
    limpiar();
  }

  // ---------- Consultas ----------

  Map<String, Object?>? _fila(String sql, List<Object?> p) {
    final r = db.select(sql, p);
    return r.isEmpty ? null : r.first;
  }

  Map<String, Object?>? _usuarioPorNametag(String clave) =>
      _fila('SELECT * FROM users WHERE nametag_lower = ?', [clave]);

  Usuario? _usuarioPorId(String id) {
    final f = _fila('SELECT id, nametag FROM users WHERE id = ?', [id]);
    return f == null ? null : (id: f['id'] as String, nametag: f['nametag'] as String);
  }

  /// Si [fn] termina bien se guarda todo (incluso si devuelve un "error" de
  /// negocio); si lanza, se deshace. [fn] es síncrona: nadie más toca la base
  /// mientras corre.
  T _enTransaccion<T>(T Function() fn) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final r = fn();
      db.execute('COMMIT');
      return r;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ---------- Bloqueo por intentos fallidos ----------

  int _segundosDeBloqueo(String clave) {
    final f = _fila('SELECT * FROM login_failures WHERE clave = ?', [seg.hashClaveUsuario(clave)]);
    final hasta = (f?['locked_until'] as int?) ?? 0;
    return hasta > _ahora() ? hasta - _ahora() : 0;
  }

  void _registrarFallo(String clave) {
    final key = seg.hashClaveUsuario(clave);
    final f = _fila('SELECT * FROM login_failures WHERE clave = ?', [key]);
    final hasta = (f?['locked_until'] as int?) ?? 0;
    // Si el bloqueo anterior ya venció, se empieza de cero.
    final previos = f != null && !(hasta != 0 && hasta <= _ahora()) ? f['count'] as int : 0;
    final cuenta = previos + 1;
    final lock = cuenta >= config.maxIntentosFallidos ? _ahora() + config.bloqueoSeg : 0;
    db.execute(
      '''INSERT INTO login_failures (clave, count, locked_until, updated_at) VALUES (?, ?, ?, ?)
         ON CONFLICT(clave) DO UPDATE SET count = excluded.count,
           locked_until = excluded.locked_until, updated_at = excluded.updated_at''',
      [key, lock != 0 ? 0 : cuenta, lock, _ahora()],
    );
  }

  void _limpiarFallos(String clave) =>
      db.execute('DELETE FROM login_failures WHERE clave = ?', [seg.hashClaveUsuario(clave)]);

  ApiError _bloqueado(int segundos) => ApiError(
    429,
    'cuenta_bloqueada',
    'Demasiados intentos fallidos. Inténtalo de nuevo más tarde.',
    {'reintentarEnSegundos': segundos},
  );

  // ---------- Sesiones (access + refresh con rotación) ----------

  /// Crea (o renueva, si se da [familyId]) una sesión. La "familia" de
  /// refresh tokens es la sesión: su id va en el access token como `sid`.
  Map<String, Object?> _emitirSesion(Usuario u, [String? familyId]) {
    final sesion = familyId ?? nuevoUuid();
    final refreshToken = seg.nuevoRefreshToken();
    db.execute(
      '''INSERT INTO refresh_tokens (user_id, family_id, token_hash, expires_at, created_at, last_seen_at)
         VALUES (?, ?, ?, ?, ?, ?)''',
      [u.id, sesion, seg.hashToken(refreshToken), _ahora() + config.refreshTtlSeg, _ahora(), _ahora()],
    );
    return {
      'accessToken': seg.crearAccessToken(u.id, sesion),
      'refreshToken': refreshToken,
      'expiresIn': config.accessTtlSeg,
      'user': {'id': u.id, 'nametag': u.nametag},
    };
  }

  /// La sesión dio señales de vida (cualquier petición con su token).
  void _marcarActividad(String sesion) => db.execute(
    'UPDATE refresh_tokens SET last_seen_at = ? WHERE family_id = ? AND revoked_at IS NULL',
    [_ahora(), sesion],
  );

  /// Si [userId] tiene una sesión en uso en otro dispositivo, devuelve en
  /// cuántos segundos se liberaría sola si ese dispositivo dejara de dar
  /// señales de vida; null si no hay ninguna en uso.
  ///
  /// "En uso" = conectada al multijugador, o con actividad en los últimos
  /// [Config.sesionActivaSeg] segundos (la app avisa cada minuto). Así, si se
  /// cierra la app sin salir o se pierde el teléfono, la cuenta se libera
  /// sola en un par de minutos en vez de quedar bloqueada.
  int? _segundosSesionEnUso(String userId) {
    if (tieneConexionAbierta?.call(userId) ?? false) return config.sesionActivaSeg;
    final visto = _fila(
      '''SELECT MAX(COALESCE(last_seen_at, created_at)) AS visto FROM refresh_tokens
         WHERE user_id = ? AND revoked_at IS NULL AND expires_at >= ?''',
      [userId, _ahora()],
    )?['visto'] as int?;
    if (visto == null) return null;
    final libre = visto + config.sesionActivaSeg - _ahora();
    return libre > 0 ? libre : null;
  }

  /// Sesiones viejas que ya no están en uso (app cerrada sin salir): se
  /// cierran al entrar en otro dispositivo. Si ese dispositivo vuelve, verá
  /// que su sesión se cerró porque se entró en otro lado.
  void _cerrarOtrasSesiones(String userId) {
    db.execute(
      '''UPDATE refresh_tokens SET revoked_at = ?, revoke_reason = 'otro_dispositivo'
         WHERE user_id = ? AND revoked_at IS NULL''',
      [_ahora(), userId],
    );
  }

  void _avisarSesionesCerradas(String userId) => alCerrarSesiones?.call(userId);

  /// `activa`, `reemplazada` (se entró en otro dispositivo) o `cerrada`.
  String _estadoSesion(String userId, String sesion) {
    final filas = db.select(
      'SELECT revoked_at, revoke_reason, expires_at FROM refresh_tokens WHERE family_id = ? AND user_id = ?',
      [sesion, userId],
    );
    if (filas.any((f) => f['revoked_at'] == null && (f['expires_at'] as int) >= _ahora())) {
      return 'activa';
    }
    return filas.any((f) => f['revoke_reason'] == 'otro_dispositivo') ? 'reemplazada' : 'cerrada';
  }

  /// true si la sesión [sesion] de [userId] sigue abierta.
  bool sesionActiva(String userId, String sesion) => _estadoSesion(userId, sesion) == 'activa';

  ({Usuario? usuario, String? sesion, String estado}) _resolver(String? token) {
    const nada = (usuario: null, sesion: null, estado: 'invalido');
    if (token == null || !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(token)) return nada;
    final t = seg.verificarAccessToken(token);
    if (t == null) return nada;
    final u = _usuarioPorId(t.userId);
    if (u == null) return nada;
    return (usuario: u, sesion: t.sesion, estado: _estadoSesion(u.id, t.sesion));
  }

  /// Usuario y sesión de un access token, o null si no sirve. Se consulta la
  /// base en cada uso: si la cuenta se borró o la sesión se cerró (por
  /// ejemplo, porque se entró en otro dispositivo) el token deja de servir al
  /// instante, aunque todavía no haya vencido.
  ({Usuario usuario, String sesion})? autenticarSesion(String? token) {
    final r = _resolver(token);
    if (r.estado != 'activa') return null;
    _marcarActividad(r.sesion!);
    return (usuario: r.usuario!, sesion: r.sesion!);
  }

  Usuario? autenticarToken(String? token) => autenticarSesion(token)?.usuario;

  Usuario _requiereAuth(Request req) {
    final m = RegExp(r'^Bearer (.+)$').firstMatch(req.headers['authorization'] ?? '');
    final r = _resolver(m?.group(1));
    if (r.estado == 'reemplazada') throw _sesionReemplazada();
    if (r.estado != 'activa') throw ApiError(401, 'no_autenticado', 'Sesión inválida o vencida.');
    _marcarActividad(r.sesion!);
    return r.usuario!;
  }

  ApiError _sesionReemplazada() => ApiError(
    401,
    'sesion_reemplazada',
    'Se inició sesión con tu cuenta en otro dispositivo.',
  );

  Handler _conLimiteAuth(Handler h) => (req) {
    final espera = _limiteAuth.registrar(ipCliente(req, config.trustProxy));
    if (espera != null) {
      throw ApiError(
        429,
        'demasiadas_peticiones',
        'Demasiadas peticiones. Espera unos minutos.',
        {'reintentarEnSegundos': espera},
      );
    }
    return h(req);
  };

  // ---------- Rutas ----------

  Router _rutas() {
    final r = Router(
      notFoundHandler: (_) =>
          throw ApiError(404, 'no_encontrado', 'Ruta no encontrada.'),
    );
    r.get('/health', (Request _) => respuestaJson(200, {'ok': true}));
    r.post('/auth/register', _conLimiteAuth(_registrar));
    r.post('/auth/login', _conLimiteAuth(_login));
    r.post('/auth/refresh', _conLimiteAuth(_refresh));
    r.post('/auth/logout', _conLimiteAuth(_logout));
    r.post('/auth/logout-all', _logoutAll);
    r.get('/account/me', (Request req) {
      final u = _requiereAuth(req);
      return respuestaJson(200, {'user': {'id': u.id, 'nametag': u.nametag}});
    });
    r.post('/account/delete', _conLimiteAuth(_borrarCuenta));
    r.get('/ws', (Request req) {
      final ws = webSocket;
      if (ws == null) throw ApiError(404, 'no_encontrado', 'Ruta no encontrada.');
      return ws(req);
    });
    return r;
  }

  Future<Response> _registrar(Request req) async {
    final d = validarRegistro(await leerJson(req));
    final clave = d.nametag.toLowerCase();
    final enUso = ApiError(409, 'nametag_en_uso', 'Ese nametag ya está en uso.');

    if (_usuarioPorNametag(clave) != null) throw enUso;
    final hash = await seg.hashearPassword(d.password);
    final u = (id: nuevoUuid(), nametag: d.nametag);
    try {
      db.execute(
        'INSERT INTO users (id, nametag, nametag_lower, password_hash, created_at) VALUES (?, ?, ?, ?, ?)',
        [u.id, u.nametag, clave, hash, _ahora()],
      );
    } on SqliteException catch (e) {
      // Dos registros simultáneos del mismo nametag: gana el primero.
      if (e.message.contains('UNIQUE constraint failed')) throw enUso;
      rethrow;
    }
    return respuestaJson(201, _emitirSesion(u)); // cuenta nueva: no hay otras sesiones
  }

  Future<Response> _login(Request req) async {
    final d = validarLogin(await leerJson(req));
    final clave = d.nametag.toLowerCase();

    final espera = _segundosDeBloqueo(clave);
    if (espera > 0) throw _bloqueado(espera);

    final fila = _usuarioPorNametag(clave);
    var ok = false;
    if (fila != null) {
      ok = await seg.verificarPassword(fila['password_hash'] as String, d.password);
    } else {
      await seg.verificarContraSenuelo(d.password); // mismo coste de tiempo
    }
    if (!ok) {
      _registrarFallo(clave);
      throw ApiError(401, 'credenciales_invalidas', 'Nametag o contraseña incorrectos.');
    }
    _limpiarFallos(clave);
    final u = (id: fila!['id'] as String, nametag: fila['nametag'] as String);

    // Una sola sesión por cuenta: si está abierta y en uso en otro
    // dispositivo, no se deja entrar. (Se revisa después de la contraseña
    // para no revelar a nadie más si la cuenta está conectada.)
    final enUso = _segundosSesionEnUso(u.id);
    if (enUso != null) {
      final minutos = (enUso / 60).ceil();
      throw ApiError(
        409,
        'sesion_activa',
        'Esta cuenta ya tiene una sesión abierta en otro dispositivo. '
            'Cierra sesión allí para entrar aquí. Si ese dispositivo ya está '
            'cerrado, podrás entrar en $minutos ${minutos == 1 ? 'minuto' : 'minutos'}.',
        {'reintentarEnSegundos': enUso},
      );
    }
    _cerrarOtrasSesiones(u.id);
    final sesion = _emitirSesion(u);
    _avisarSesionesCerradas(u.id); // corta el multijugador del dispositivo anterior
    return respuestaJson(200, sesion);
  }

  Future<Response> _refresh(Request req) async {
    final refreshToken = validarRefresh(await leerJson(req));
    final hash = seg.hashToken(refreshToken);

    // Rotación: cada refresh token sirve UNA vez. Si alguien reutiliza uno ya
    // usado, se asume robo y se revoca toda la familia de sesiones.
    final resultado = _enTransaccion<({String userId, String familyId})?>(() {
      final t = _fila('SELECT * FROM refresh_tokens WHERE token_hash = ?', [hash]);
      if (t == null) return null;
      // Sesión cerrada porque se entró en otro dispositivo: se dice tal cual.
      if (t['revoke_reason'] == 'otro_dispositivo') throw _sesionReemplazada();
      if (t['revoked_at'] != null || t['used_at'] != null) {
        db.execute(
          'UPDATE refresh_tokens SET revoked_at = ? WHERE family_id = ? AND revoked_at IS NULL',
          [_ahora(), t['family_id']],
        );
        return null;
      }
      if ((t['expires_at'] as int) < _ahora()) return null;
      db.execute(
        'UPDATE refresh_tokens SET used_at = ? WHERE id = ? AND used_at IS NULL',
        [_ahora(), t['id']],
      );
      if (db.updatedRows != 1) return null;
      return (userId: t['user_id'] as String, familyId: t['family_id'] as String);
    });

    final invalido = ApiError(401, 'refresh_invalido', 'Sesión inválida o vencida.');
    if (resultado == null) throw invalido;
    final u = _usuarioPorId(resultado.userId);
    if (u == null) throw invalido;
    return respuestaJson(200, _emitirSesion(u, resultado.familyId)); // marca actividad
  }

  Future<Response> _logout(Request req) async {
    final refreshToken = validarRefresh(await leerJson(req));
    final t = _fila(
      'SELECT family_id, user_id FROM refresh_tokens WHERE token_hash = ?',
      [seg.hashToken(refreshToken)],
    );
    if (t != null) {
      db.execute(
        'UPDATE refresh_tokens SET revoked_at = ? WHERE family_id = ? AND revoked_at IS NULL',
        [_ahora(), t['family_id']],
      );
      _avisarSesionesCerradas(t['user_id'] as String);
    }
    return Response(204); // siempre 204: no revela si el token existía
  }

  Response _logoutAll(Request req) {
    final u = _requiereAuth(req);
    db.execute(
      'UPDATE refresh_tokens SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL',
      [_ahora(), u.id],
    );
    _avisarSesionesCerradas(u.id);
    return Response(204);
  }

  // Borrar la cuenta exige la contraseña otra vez (re-autenticación): un token
  // robado por sí solo no basta para destruir la cuenta.
  Future<Response> _borrarCuenta(Request req) async {
    final u = _requiereAuth(req);
    final password = validarBorrarCuenta(await leerJson(req));
    final clave = u.nametag.toLowerCase();

    final espera = _segundosDeBloqueo(clave);
    if (espera > 0) throw _bloqueado(espera);

    final hash = _fila('SELECT password_hash FROM users WHERE id = ?', [u.id])?['password_hash'];
    if (hash is! String || !await seg.verificarPassword(hash, password)) {
      _registrarFallo(clave);
      throw ApiError(403, 'password_incorrecta', 'La contraseña es incorrecta.');
    }
    _limpiarFallos(clave);
    db.execute('DELETE FROM users WHERE id = ?', [u.id]); // ON DELETE CASCADE borra sus tokens
    _avisarSesionesCerradas(u.id);
    return Response(204);
  }

  /// Limpieza periódica de datos vencidos.
  void limpiar() {
    final t = _ahora();
    db.execute(
      'DELETE FROM refresh_tokens WHERE expires_at < ? OR (revoked_at IS NOT NULL AND revoked_at < ?)',
      [t, t - 7 * 24 * 3600],
    );
    db.execute('DELETE FROM login_failures WHERE updated_at < ?', [t - 24 * 3600]);
    _limiteGlobal.limpiar();
    _limiteAuth.limpiar();
  }
}

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Abre (o crea) la base de datos SQLite y aplica el esquema.
/// Usa `:memory:` para una base temporal (pruebas).
Database abrirDb(String dbPath) {
  final Database db;
  if (dbPath == ':memory:') {
    db = sqlite3.openInMemory();
  } else {
    File(dbPath).parent.createSync(recursive: true);
    db = sqlite3.open(dbPath);
    db.execute('PRAGMA journal_mode = WAL;');
  }
  db.execute('PRAGMA foreign_keys = ON;');

  // Las primeras versiones del proyecto iniciaban sesión con correo. Si la base
  // de datos es de esa época (tiene la columna "email") se reinicia: eran solo
  // cuentas de prueba y el esquema nuevo no es compatible.
  final columnas = db.select('PRAGMA table_info(users)');
  if (columnas.any((c) => c['name'] == 'email')) {
    stderr.writeln('AVISO: base de datos con el esquema antiguo (correo). Se reinicia.');
    db.execute(
      'DROP TABLE IF EXISTS refresh_tokens; DROP TABLE IF EXISTS login_failures; DROP TABLE users;',
    );
  }

  db.execute('''
    -- "nametag" es el nombre público (con sus mayúsculas) y también el usuario
    -- con el que se inicia sesión. "nametag_lower" es lo mismo en minúsculas y es
    -- único: así "Ana" y "ana" no pueden existir a la vez.
    CREATE TABLE IF NOT EXISTS users (
      id            TEXT PRIMARY KEY,
      nametag       TEXT NOT NULL,
      nametag_lower TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      created_at    INTEGER NOT NULL
    );

    -- Solo se guarda el SHA-256 del refresh token: si se filtra la base de datos
    -- los tokens no se pueden usar.
    CREATE TABLE IF NOT EXISTS refresh_tokens (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      family_id  TEXT NOT NULL,
      token_hash TEXT NOT NULL UNIQUE,
      expires_at INTEGER NOT NULL,
      used_at    INTEGER,
      revoked_at INTEGER,
      created_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_refresh_user   ON refresh_tokens(user_id);
    CREATE INDEX IF NOT EXISTS idx_refresh_family ON refresh_tokens(family_id);

    -- Intentos de login fallidos por nametag (exista o no en la base, para
    -- no revelar qué nametags están registrados).
    CREATE TABLE IF NOT EXISTS login_failures (
      clave        TEXT PRIMARY KEY,
      count        INTEGER NOT NULL,
      locked_until INTEGER NOT NULL DEFAULT 0,
      updated_at   INTEGER NOT NULL
    );
  ''');

  // Motivo por el que se cerró una sesión ('otro_dispositivo' = se inició
  // sesión con la cuenta en otro lado). Bases anteriores no tenían la columna.
  final colsRefresh = db.select('PRAGMA table_info(refresh_tokens)');
  if (!colsRefresh.any((c) => c['name'] == 'revoke_reason')) {
    db.execute('ALTER TABLE refresh_tokens ADD COLUMN revoke_reason TEXT');
  }
  // Última señal de vida de la sesión (para saber si está en uso).
  if (!colsRefresh.any((c) => c['name'] == 'last_seen_at')) {
    db.execute('ALTER TABLE refresh_tokens ADD COLUMN last_seen_at INTEGER');
  }
  return db;
}

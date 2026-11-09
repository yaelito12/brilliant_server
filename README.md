# Servidor de autenticación de Brilliant

Servidor aparte (Dart + shelf + SQLite) donde se registran los clientes
(la app Flutter, que está en su propia carpeta `brilliant`). Permite **crear cuenta, iniciar sesión,
cerrar sesión y borrar la cuenta**.

## Arranque rápido

```bash
cd brilliant_server
dart pub get
cp .env.example .env
dart run bin/gen_secret.dart   # copia el resultado en JWT_SECRET dentro de .env
dart run bin/server.dart       # http://localhost:3000
dart test                      # 77 pruebas
```

Requiere Dart 3.9 o superior (el que trae Flutter sirve). SQLite viene dentro del paquete
`sqlite3`; no hay que instalar nada aparte.

Para producción se compila a un ejecutable:

```bash
dart build cli -t bin/server.dart
# resultado: build/cli/<plataforma>/bundle/  (bin/server[.exe] + lib/ con la librería de SQLite)
```

> `dart compile exe` **no** sirve aquí (el paquete `sqlite3` usa *build hooks*). Usa
> `dart build cli` y copia la carpeta `bundle/` completa.

## API

Todas las respuestas son JSON. Los errores tienen la forma
`{"error": {"code": "...", "message": "..."}}`.

| Método | Ruta | Cuerpo | Respuesta |
|---|---|---|---|
| POST | `/auth/register` | `nametag`, `password` | 201 + sesión |
| POST | `/auth/login` | `nametag`, `password` | 200 + sesión |
| POST | `/auth/refresh` | `refreshToken` | 200 + sesión nueva |
| POST | `/auth/logout` | `refreshToken` | 204 |
| POST | `/auth/logout-all` | — (Bearer) | 204 |
| GET | `/account/me` | — (Bearer) | 200 `{user}` |
| POST | `/account/delete` | `password` (Bearer) | 204 |
| GET | `/health` | — | 200 |
| GET | `/ws` | WebSocket del multijugador | ver [MULTIJUGADOR.md](MULTIJUGADOR.md) |

"Sesión" = `{accessToken, refreshToken, expiresIn, user: {id, nametag}}`.
Las rutas protegidas llevan `Authorization: Bearer <accessToken>`.

## Qué hace para ser seguro

| Amenaza | Medida |
|---|---|
| Robo de la base de datos | Contraseñas con **Argon2id** (64 MiB, t=3) y sal propia por usuario; pepper opcional fuera de la BD. Los refresh tokens se guardan como SHA-256. |
| Fuerza bruta | Bloqueo de 15 min tras 5 fallos por nametag (existan o no) + límite por IP (20 peticiones/15 min en rutas de auth). |
| Enumeración de usuarios | Mismo mensaje y mismo tiempo de respuesta si el nametag no existe (hash señuelo). El bloqueo también aplica a nametags inexistentes. |
| Robo de tokens | Access token JWT de 15 min (HS256, con `iss`/`aud`/`exp`, algoritmo fijado). Refresh token aleatorio de 256 bits, **de un solo uso con rotación**: si se reutiliza uno viejo se revoca toda la sesión. |
| Cuenta borrada | El access token se valida contra la BD en cada petición, así que deja de servir al instante. Borrar la cuenta exige la contraseña de nuevo. |
| Cuenta abierta en dos lugares | **Una sola sesión por cuenta:** si la cuenta está en uso en otro dispositivo (conectado al multijugador o con actividad en los últimos 150 s; la app avisa cada minuto), el login responde 409 `sesion_activa`. Se revisa después de la contraseña para no revelar si alguien está conectado. Cerrar sesión libera la cuenta al instante; si el otro dispositivo se cerró sin salir, se libera sola en unos 2,5 min (así nadie queda fuera de su cuenta por perder el teléfono) y esa sesión vieja se cierra con el código `sesion_reemplazada`. El access token lleva el id de su sesión (`sid`) y deja de servir al instante cuando la sesión se cierra. |
| Inyección / abuso | Consultas SQL con parámetros, validación de cada campo, cuerpo máximo 10 KB, cabeceras de seguridad (las mismas que `helmet`), sin `X-Powered-By`, `Cache-Control: no-store`. |
| Tráfico en claro | En `ENV=production` (o `NODE_ENV=production`) rechaza peticiones que no lleguen por HTTPS. |
| Mala configuración | No arranca sin `JWT_SECRET` de 32+ caracteres. Errores internos solo van al log. |

Criptografía de paquetes conocidos (no se implementó criptografía propia): Argon2id de
`pointycastle` (se calcula en otro *isolate* para no frenar al servidor) y HMAC-SHA256 / SHA-256
de `crypto`. El JWT solo acepta `HS256` y compara la firma en tiempo constante.

**Compatibilidad con el servidor anterior (Node):** misma API, misma base de datos y los hashes
usan el formato PHC estándar (`$argon2id$v=19$m=...`), así que las cuentas que ya existían siguen
funcionando. Los parámetros por defecto pasan a m=19 MiB, t=2 (mínimo de OWASP); cada hash viejo
guarda sus propios parámetros y se verifica con ellos.

## Puesta en producción

1. Pon el servidor detrás de un proxy con **TLS** (Caddy, nginx, Render, Fly...).
2. Variables: `ENV=production`, `TRUST_PROXY=1`, `JWT_SECRET=...`.
3. Respalda el archivo `DB_PATH` y no lo expongas.
4. Si cambias `JWT_SECRET` los access tokens vigentes dejan de valer, pero la app los renueva
   sola con el refresh token (que no depende de ese secreto); nadie tiene que volver a entrar.

## Límites conocidos (a propósito, para esta entrega)

- **No hay correo:** la cuenta es solo nametag y contraseña, así que **no existe "olvidé mi
  contraseña"**. Si alguien la pierde, pierde la cuenta.
- **Contraseña mínima de 6 caracteres** (se rechazan las más obvias como `123456` o `qwerty`).
  Es una política débil a propósito; lo que la protege es Argon2id, el bloqueo tras 5 fallos y el
  límite por IP. Si algún día quieres más seguridad, basta subir el mínimo en
  `lib/src/validacion.dart` (aquí) y en `lib/auth/validadores.dart` (en la app).
- El nametag es público y único (sin distinguir mayúsculas), así que registrar uno ya usado responde
  409. Es inevitable en cualquier juego con nombres públicos; está protegido por el límite por IP.
- El bloqueo por nametag permite que alguien bloquee 15 min a otra persona a propósito; es el
  coste habitual de este tipo de protección.
- SQLite sirve para un solo servidor. Para varias instancias habría que pasar a PostgreSQL.

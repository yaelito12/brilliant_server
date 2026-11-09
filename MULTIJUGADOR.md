# Multijugador

Las partidas multijugador usan un WebSocket en `/ws` (en producción, `wss://…/ws`).
Todos los mensajes son objetos JSON con un campo `tipo`.

Estado: **completo** (servidor y app: lobby, partida, desconexiones y resultados).

## Conexión y autenticación

1. Abrir `ws://servidor:3000/ws`.
2. Antes de 10 s, mandar `{"tipo":"auth","token":"<accessToken>"}`.
   El token va en un mensaje, no en la URL (las URLs quedan en logs) ni en una cabecera
   (Flutter Web no deja poner cabeceras a un WebSocket).
3. Respuesta: `{"tipo":"autenticado","user":{id,nametag},"sala":<sala>|null}`.
   Si `sala` no es null, el jugador ya estaba en una sala (se había caído) y vuelve a ella.

## Mensajes del cliente

| tipo | campos | qué hace |
|---|---|---|
| `crear_sala` | `nivel` (1-4) | Crea una sala con código y entra en ella. |
| `unirse` | `codigo`, `nivel` (opcional) | Entra a una sala (el código no distingue mayúsculas ni espacios). Sin `nivel` se usa el mapa de quien creó la sala. |
| `elegir_mapa` | `nivel` | Cambia el mapa propio. Quita el "listo". |
| `listo` | `listo` (bool) | Marca o desmarca "listo". |
| `salir` | — | Sale de la sala. Responde `{"tipo":"saliste"}`. |
| `ping` | — | Responde `{"tipo":"pong"}` (además del ping propio de WebSocket). |
| `iniciales` | `valores`: `[[fila, columna, número], …]` (6) | Pone los números iniciales (fase `iniciales`). |
| `jugada` | `ancla`: `[fila, columna]`, `destino`: `[fila, columna]` | Coloca el otro dado junto al ancla. |
| `pasar` | — | Pasa la ronda sin colocar. |
| `conceder` | — | Se rinde. Sigue viendo la partida. |

## Mensajes del servidor

- `{"tipo":"sala","sala":<sala>,"evento":<evento>?}` cada vez que cambia algo, a todos los de la sala.
- `{"tipo":"partida_iniciada","sala":<sala>}` cuando todos están listos.
- `{"tipo":"partida","partida":<partida>,"evento":<evento>?}` cada vez que cambia la partida.
  También se manda al reconectarse, con todo lo necesario para seguir.
- `{"tipo":"partida_terminada","motivo","resultados":[…],"partida":<partida>}` y después un
  `sala` con `estado: "lobby"` (evento `fin_partida`): se puede jugar la revancha.
- `{"tipo":"error","code","message","en":<tipo del mensaje que lo causó>}`. La conexión sigue abierta.

`<sala>`:
```json
{
  "codigo": "K7M2QX", "estado": "lobby" | "jugando",
  "minJugadores": 2, "maxJugadores": 6,
  "jugadores": [{"id": "...", "nametag": "Ana", "nivel": 2, "listo": true, "conectado": true}]
}
```

`<evento>` (para mostrar avisos): `{"tipo": "creada"|"unido"|"salio"|"desconectado"|"reconectado"|"abandono", "nametag": "..."}`.

`<partida>`:
```json
{
  "fase": "iniciales" | "jugando" | "terminada",
  "ronda": 3, "maxRondas": 100, "puntosMeta": 26, "dados": [2, 5], "msRestantes": 41250,
  "jugadores": [{
    "id": "...", "nametag": "Ana", "nivel": 2,
    "estado": "jugando" | "concedio" | "abandono",
    "conectado": true, "yaJugo": false, "puntos": 11, "completo": false,
    "celdas": [[0, 2, 1], [1, 5, 2]],          // [fila, columna, número]
    "lugares": {"az1": 1, "ve2": 2}            // lugar en que completó cada zona
  }]
}
```

`resultados`: `[{"id","nametag","nivel","puntos","estado","posicion"}]`, ya ordenados.

Eventos de partida: `iniciales`, `ronda` (con `pasaronPorTiempo` si a alguien se le acabó el
tiempo), `jugada` (con `puntosGanados` y `completo`), `paso`, `desconectado`, `reconectado`,
`concedio`, `abandono`.

Códigos de error: `mapa_invalido`, `sala_no_encontrada`, `sala_llena`, `partida_en_curso`,
`ya_en_sala`, `no_en_sala`, `mensaje_invalido`, `mensaje_desconocido`, `sin_partida`,
`no_es_momento`, `iniciales_invalidos`, `jugada_invalida`.

## Reglas del lobby

- Cada jugador elige **su propio mapa** (pueden ser distintos).
- Entre **2 y 6** jugadores. El 7.º recibe `sala_llena`.
- La partida empieza sola cuando hay al menos 2 jugadores, **todos conectados y con "listo"**.
  Si el único que faltaba sale de la sala, los demás empiezan.
- Un usuario solo puede estar en una sala a la vez.
- La sala se borra cuando se va el último jugador.

## Reglas de la partida

- **Cada jugador tiene su propio tablero** (su mapa) y **todos usan los mismos dados**.
  Los tira el servidor (`Random.secure`) y nunca manda una semilla: nadie puede saber los próximos.
- **Números iniciales:** 90 s (`INITIAL_VALUES_SECONDS`) para poner los 6. Si no, el servidor pone
  números válidos al azar.
- **Rondas simultáneas:** cada uno coloca o pasa. La ronda termina cuando todos los conectados
  jugaron, o a los 60 s (`TURN_SECONDS`): los que faltan pasan.
- **El servidor valida cada jugada** con `brilliant_reglas` (el mismo código de la app) y calcula
  los puntos. Lo que diga la app sobre puntos se ignora.
- **Puntos por lugar:** el 1.º en completar una zona (mismo id, por ejemplo `az1`) gana los puntos
  de 1.er lugar de su color, el siguiente los de 2.º, etc. Si la completan en la misma ronda,
  comparten lugar.
- **Fin:** cuando alguien completa su tablero (al terminar esa ronda, para que todos hayan tenido
  los mismos turnos), al llegar a 100 rondas (`MAX_ROUNDS`), o si queda un solo jugador en juego.
- **Clasificación:** primero los que siguen en juego, por puntos; después los que concedieron o
  abandonaron. Con los mismos puntos se comparte posición.
- **Conceder** (o salir de la sala): pasas al final de la clasificación. Si solo queda uno, gana.

## Desconexiones

| Situación | Qué pasa |
|---|---|
| Se cae la conexión (Wi-Fi, app cerrada, sin batería) | El servidor lo detecta (cierre o ping de WebSocket sin respuesta cada 15 s). El jugador queda `conectado: false` y **pierde el "listo"**, así nadie empieza con un jugador caído. Los demás reciben el evento `desconectado`. |
| Vuelve antes de 30 s (`RECONNECT_GRACE_SECONDS`) | Al autenticarse recibe su sala en `autenticado.sala` y los demás reciben `reconectado`. |
| No vuelve a tiempo | Sale de la sala (evento `abandono`). |
| Se cae **en plena partida** | No frena a nadie: sus rondas se pasan solas. Si no queda nadie conectado, las rondas avanzan solo por tiempo. |
| Vuelve a la partida | Recibe `autenticado` y un `partida` con su tablero, los dados de la ronda y si ya jugó; sigue jugando. |
| No vuelve a la partida a tiempo | Cuenta como **abandono**: queda al final de la clasificación. Si solo queda un jugador, gana. |
| Se reinicia el servidor | Las salas y partidas viven en memoria y se pierden (las cuentas no). |
| Abre la cuenta en otra conexión | La vieja recibe el error `sesion_reemplazada` y se cierra con código 4002; la nueva conserva la sala. |
| Intenta entrar con su cuenta en **otro dispositivo** | No se puede mientras esta conexión esté abierta (login 409 `sesion_activa`). Si cierra sesión o borra la cuenta, esta conexión recibe el error `sesion_cerrada` y el cierre 4004. |
| Token vencido al reconectar | Cierre 4001: la app debe renovar el token (`/auth/refresh`) y volver a conectar. |

## Códigos de cierre

| Código | Motivo | Qué debe hacer la app |
|---|---|---|
| 4000 | El servidor se apaga | Reintentar más tarde. |
| 4001 | No autenticado (token inválido/vencido o no llegó a tiempo) | Renovar token y reconectar. |
| 4002 | Sesión reemplazada por otra conexión | No reconectar automáticamente. |
| 4003 | Mensaje inválido: >4 KB, binario o >20 mensajes/s | Es un error de la app. |
| 4004 | La sesión se cerró (se entró con la cuenta en otro dispositivo, se cerró sesión o se borró la cuenta) | Volver al inicio de sesión. No reconectar. |
| otro / sin código | Se cortó la red | Reconectar con espera creciente (1 s, 2 s, 4 s… máx. 15 s). |

## Seguridad

- Cada mensaje: máximo 4 KB, solo texto JSON, máximo 20 por segundo por conexión.
- Códigos de sala de 6 caracteres aleatorios (`Random.secure`) de un alfabeto de 31 símbolos
  (887 millones de combinaciones), sin caracteres que se confundan (0/O, 1/I/L).
- `/ws` pasa por los mismos filtros que la API: HTTPS obligatorio en producción y límite por IP.
- Las jugadas se validan en el servidor con el paquete `brilliant_reglas`, que está copiado en `packages/brilliant_reglas`
  (es el mismo código que usa la app: si cambian las reglas, hay que copiarlas en los dos lados).

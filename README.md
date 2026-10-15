# AndesStay Messaging Infrastructure

Infraestructura local de mensajería de AndesStay basada en RabbitMQ.

## Servicios

- RabbitMQ AMQP: localhost:5672
- RabbitMQ Management: http://localhost:15672 (usuario `andesstay` / clave `andesstay_dev`)

## Iniciar

```bash
docker compose up -d
```

## Detener

```bash
docker compose down
```

## Detener y eliminar datos

```bash
docker compose down -v
```

## Topología del sistema

Las colas, exchanges y bindings los declaran los propios microservicios al iniciar (beans `Queue`, `Exchange` y `Binding`). Los nombres están en el `application.yaml` de cada uno (`andesstay.messaging`).

| Exchange | Tipo | Routing key | Cola | DLQ | Consumidor |
|---|---|---|---|---|---|
| `andesstay.commands` | direct | `email.send` | `notify.email.q` | `notify.email.dlq` | ms-andesstay-notify (8083) |
| `andesstay.commands` | direct | `housekeeping.ticket` | `catalog.housekeeping.q` | `catalog.housekeeping.dlq` | ms-andesstay-catalog (8082) |
| `andesstay.commands` | direct | `voucher.gen` | `report.voucher.q` | `report.voucher.dlq` | ms-andesstay-report (8084) |
| `andesstay.events` | topic | `reservation.#` | `audit.reservation.q` | `audit.reservation.dlq` | ms-andesstay-audit (8085) |

- Productor: **ms-andesstay-reservations** (8081), después de confirmar cada transacción.
- Dead Letter Exchange: `andesstay.dlx` (direct). Cada cola principal envía sus mensajes rechazados al DLX usando el nombre de su DLQ como routing key.
- Administración por API: **ms-andesstay-rabbit-admin** (8086).

### Qué mensajes genera cada cambio de estado

| Estado nuevo | Mensajes |
|---|---|
| CREADA | evento `reservation.creada` (audit) |
| CONFIRMADA | correo + ticket `PREPARE_ROOM` + voucher + evento |
| CHECKIN_PENDIENTE | correo recordatorio + evento |
| EN_ESTADIA | evento |
| CHECKOUT | correo + ticket `CLEAN_ROOM` + evento |
| CANCELADA | evento |

## Probar errores y DLQ desde la consola (http://localhost:15672)

En **Exchanges → andesstay.commands → Publish message**, con la propiedad `content_type = application/json`:

- **Error no recuperable** (va directo a `notify.email.dlq`), routing key `email.send`:
  ```json
  {"type":"email.send","eventId":"11111111-1111-1111-1111-111111111111","timestamp":"2026-10-15T12:00:00Z","traceId":"t1","correlationId":"reservation-99","payload":{"reservationId":99,"recipient":"correo-invalido","notificationType":"RESERVATION_CONFIRMED"}}
  ```
- **Error recuperable** (3 intentos y luego DLQ), routing key `email.send`:
  ```json
  {"type":"email.send","eventId":"22222222-2222-2222-2222-222222222222","timestamp":"2026-10-15T12:00:00Z","traceId":"t2","correlationId":"reservation-99","payload":{"reservationId":99,"recipient":"cliente@falla-temporal.test","notificationType":"RESERVATION_CONFIRMED"}}
  ```
- **JSON inválido** (el contenedor lo rechaza y va a la DLQ): publicar `hola` como texto.

# infra-andesstay-messaging

Infraestructura de AndesStay en Docker: **RabbitMQ** (clúster de 2 nodos), **Kafka**
(3 ZooKeeper + 3 brokers + Kafka UI) y los **8 microservicios**. Está separada en tres
archivos, igual que en el caso, para poder levantar cada parte en su propia EC2 de AWS:

```
infra-andesstay-messaging/
├── mq/
│   ├── compose.yml          RabbitMQ 4.2: rabbitmq-1 y rabbitmq-2 en clúster      (EC2 ec2-mq)
│   └── rabbitmq.conf        cómo se encuentran los dos nodos (classic_config)
├── kafka/
│   ├── compose.yml          zookeeper-1..3, kafka-1..3, kafka-ui, kafka-init      (EC2 ec2-kafka)
│   └── create-topics.sh     crea los tópicos (3 particiones, 3 réplicas)
├── apps/
│   ├── compose.yml          bff, reservations, catalog, notify, report, audit,
│   │                        rabbit-admin, kafka-admin                              (EC2 ec2-apps)
│   └── compose.local-wait.yml   solo en el PC: las apps esperan a RabbitMQ y Kafka
├── compose.local.yml        junta los tres para levantar TODO en un PC
├── .env.example             plantilla de claves y direcciones (copiar a .env)
└── docs/
    ├── GUIA-DESPLIEGUE-AWS-CSR.md   paso a paso para AWS (arquitectura CSR)
    └── GUIA-PRESENTACION-EP6.md     qué mostrar en la presentación y con qué comando
```

## Arquitectura

```
 Navegador (Angular, CSR)
      │  login con Azure AD (MSAL) -> token JWT
      ▼
 API Gateway (JWT authorizer) ──► BFF :8080 ──┬──► reservations :8081 ──► RabbitMQ (comandos) ──► notify / catalog / report
                                              │         │
                                              │         └──────────────► Kafka reservations.events ──► audit / report
                                              ├──► catalog :8082                       audit ──► Kafka audit.timeline ──► report
                                              ├──► report :8084  (KPIs, vouchers)
                                              ├──► audit :8085   (auditoría)
                                              ├──► rabbit-admin :8086 ──► RabbitMQ
                                              └──► kafka-admin :8087  ──► Kafka
```

- **RabbitMQ = comandos** ("haz esto"): enviar correo, crear ticket de limpieza, generar voucher/boleta.
  Cada comando lo procesa un solo consumidor y se borra de la cola al hacer ACK.
- **Kafka = eventos** ("esto pasó"): cada cambio de estado de una reserva queda guardado en
  `reservations.events` (7 días). Varios consumer groups lo leen cada uno a su ritmo
  (auditoría y reportería) y se puede volver a leer (replay).

## 1. Levantar todo en el PC

Requisitos: Docker Desktop (con al menos **8 GB de RAM** asignados), Git y Node.js 22 para el frontend.

1. Clonar los repositorios **uno al lado del otro** (los compose usan `../../ms-andesstay-...`):

   ```
   andesstay/
     infra-andesstay-messaging/   <- este repo
     frontend-andesstay/
     ms-andesstay-bff/
     ms-andesstay-reservations/
     ms-andesstay-catalog/
     ms-andesstay-notify/
     ms-andesstay-report/
     ms-andesstay-audit/
     ms-andesstay-rabbit-admin/
     ms-andesstay-kafka-admin/
   ```

2. Crear el archivo `.env` y cambiar las claves:

   ```powershell
   cd infra-andesstay-messaging
   copy .env.example .env        # Linux/Mac: cp .env.example .env
   ```

   En el PC **no** hay que descomentar `RABBITMQ_ADDRESSES` ni `KAFKA_BOOTSTRAP_SERVERS`
   (se usan los nombres de los contenedores).

3. Levantar (la primera vez demora varios minutos porque Maven descarga las dependencias de cada microservicio):

   ```powershell
   docker compose -f compose.local.yml up -d --build
   docker compose -f compose.local.yml ps
   ```

   Todo debe quedar `running` / `healthy`, excepto `kafka-init`, que debe quedar **`Exited (0)`**
   (es el contenedor que crea los tópicos y termina). Para ver qué tópicos creó:

   ```powershell
   docker logs kafka-init
   ```

4. Levantar el frontend:

   ```powershell
   cd ..\frontend-andesstay
   npm install
   npm start                     # http://localhost:4200
   ```

### URLs y puertos

| Qué | URL / puerto | Usuario |
|---|---|---|
| Frontend | http://localhost:4200 | cuenta de Azure AD |
| BFF (única entrada de la API) | http://localhost:8080/actuator/health | token JWT |
| RabbitMQ nodo 1 (consola) | http://localhost:15672 | `RABBITMQ_USER` / `RABBITMQ_PASSWORD` del `.env` |
| RabbitMQ nodo 2 (consola) | http://localhost:15673 | mismo usuario |
| RabbitMQ AMQP | 5672 (nodo 1), 5673 (nodo 2) | |
| Kafka UI | http://localhost:8090 | `KAFKA_UI_USER` / `KAFKA_UI_PASSWORD` del `.env` |
| Kafka brokers (desde fuera de Docker) | localhost:9092, 9093, 9094 | |
| Microservicios | 127.0.0.1:8081 … 8087 (solo para pruebas en el mismo PC) | token JWT |

### Comandos útiles

```powershell
docker compose -f compose.local.yml logs -f reservations notify      # ver logs
docker compose -f compose.local.yml restart report                   # reiniciar uno
docker compose -f compose.local.yml up -d --build audit              # recompilar uno después de un cambio
docker compose -f compose.local.yml down                             # apagar (los datos se guardan)
docker compose -f compose.local.yml down -v                          # apagar y BORRAR datos (colas, tópicos, H2)
```

> Si corres un microservicio fuera de Docker (`mvnw spring-boot:run`), por defecto se conecta a
> `localhost:5672,localhost:5673` y `localhost:9092,9093,9094`. Define `RABBITMQ_PASSWORD`
> con la misma clave del `.env`.

## 2. RabbitMQ: clúster de 2 nodos

`mq/rabbitmq.conf` le dice a cada nodo quiénes son los miembros del clúster
(`classic_config`) y la variable `RABBITMQ_ERLANG_COOKIE` es el secreto que comparten.
El nodo 2 parte cuando el nodo 1 ya está sano y se une solo.

```powershell
docker exec rabbitmq-1 rabbitmqctl cluster_status        # deben aparecer rabbit@rabbitmq-1 y rabbit@rabbitmq-2 en "Running Nodes"
docker exec rabbitmq-1 rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers
docker exec rabbitmq-1 rabbitmqctl list_exchanges name type
docker exec rabbitmq-1 rabbitmqctl list_bindings source_name destination_name routing_key
```

Los microservicios se conectan con `spring.rabbitmq.addresses` (los dos nodos): si el primero no
responde, usan el segundo. Los exchanges, colas y bindings se ven igual desde las dos consolas
porque la definición se comparte en todo el clúster.

> Las colas son *classic* y cada una vive en el nodo donde se declaró (columna **Node** de la consola).
> En RabbitMQ 4 ya no existen las colas espejo; para que una cola sobreviva a la caída de su nodo
> habría que usar colas *quorum* con 3 nodos. Para este caso, con 2 nodos, se usan classic.

### Topología (nombres del caso)

Las declaran los propios microservicios al iniciar (`RabbitMQConfig` con `Declarables`).
Los nombres están en el `application.yaml` de cada uno (`andesstay.messaging`).

| Exchange | Tipo | Binding | Cola | DLQ | Consumidor |
|---|---|---|---|---|---|
| `cmd.direct` | direct | `email.send` | `q.cmd.email` | `q.cmd.email.dlq` | notify |
| `cmd.direct` | direct | `housekeeping.ticket` | `q.cmd.housekeeping` | `q.cmd.housekeeping.dlq` | catalog |
| `cmd.direct` | direct | `voucher.gen` | `q.cmd.voucher` | `q.cmd.voucher.dlq` | report |
| `cmd.topic` | topic | `email.*` | `q.cmd.email` | | notify |
| `cmd.topic` | topic | `housekeeping.#` | `q.cmd.housekeeping` | | catalog |
| `cmd.topic` | topic | `voucher.*` | `q.cmd.voucher` | | report |
| `cmd.dead.dlx` | direct | nombre de la DLQ | `q.cmd.*.dlq` | | (revisión manual) |

- **direct** = la routing key tiene que ser exactamente igual al binding.
- **topic** = la routing key se compara con un patrón: `*` es una palabra y `#` es cero o más palabras
  (por eso `housekeeping.clean.3` llega a `q.cmd.housekeeping`).
- Productor: **reservations**, siempre **después del commit** de la base de datos
  (`@TransactionalEventListener(AFTER_COMMIT)`), con *publisher confirms* y *returns*.

| Estado nuevo de la reserva | Comandos RabbitMQ | Evento Kafka |
|---|---|---|
| CREADA | — | `reservation.creada` |
| CONFIRMADA | `cmd.direct`: `email.send` (correo), `housekeeping.ticket` (PREPARE_ROOM), `voucher.gen` (voucher) | `reservation.confirmada` |
| CHECKIN_PENDIENTE | `cmd.topic`: `email.checkin` (recordatorio) | `reservation.checkin_pendiente` |
| EN_ESTADIA | — | `reservation.en_estadia` |
| CHECKOUT | `cmd.topic`: `email.checkout`, `housekeeping.clean.<idAlojamiento>` (CLEAN_ROOM), `voucher.boleta` (boleta) | `reservation.checkout` |
| CANCELADA | `cmd.topic`: `email.cancel` | `reservation.cancelada` |

### Por qué los mensajes "se quedan" unos segundos en la cola

Cada consumidor (notify, catalog y report) tiene **prefetch = 1** y **retiene cada mensaje
`RABBIT_PROCESSING_DELAY_MS` milisegundos (10 s por defecto)** antes de procesarlo. Así, al
confirmar una reserva en la página, en la consola de RabbitMQ (pestaña **Queues**) se alcanza a ver:

1. el mensaje como **Unacked** (el consumidor lo tomó y lo está "procesando"),
2. si se hacen varias acciones seguidas, los siguientes como **Ready** (esperando su turno),
3. y después la cola vuelve a 0 cuando el consumidor hace **ACK**.

En la pestaña **Overview** también se ven los gráficos de *Message rates* (publish / deliver / ack).
Para trabajar sin espera, pon `RABBIT_PROCESSING_DELAY_MS=0` en el `.env` y reinicia las apps.

### Probar errores y DLQ desde la consola

En **Exchanges → cmd.direct → Publish message**, routing key `email.send` y en *Properties*
`content_type = application/json`:

- **Error no recuperable** (va directo a `q.cmd.email.dlq`):
  ```json
  {"type":"email.send","eventId":"11111111-1111-1111-1111-111111111111","timestamp":"2026-10-15T12:00:00Z","traceId":"t1","correlationId":"reservation-99","payload":{"reservationId":99,"recipient":"correo-invalido","notificationType":"RESERVATION_CONFIRMED"}}
  ```
- **Error recuperable** (3 intentos y luego DLQ; con la espera de 10 s se demora unos 30 s):
  ```json
  {"type":"email.send","eventId":"22222222-2222-2222-2222-222222222222","timestamp":"2026-10-15T12:00:00Z","traceId":"t2","correlationId":"reservation-99","payload":{"reservationId":99,"recipient":"cliente@falla-temporal.test","notificationType":"RESERVATION_CONFIRMED"}}
  ```
- **JSON inválido** (se rechaza sin reintentar y va a la DLQ): publicar `hola` como texto.

Para probar el exchange topic: **Exchanges → cmd.topic**, routing key `email.cualquiercosa` con el
primer JSON → llega a `q.cmd.email` porque calza con `email.*`.

## 3. Kafka: 3 ZooKeeper + 3 brokers

- **ZooKeeper (3 nodos)**: guarda los metadatos del clúster y elige el broker *controller*.
  Con 3 nodos hay quórum (mayoría = 2), así que sigue funcionando si se cae uno.
- **Brokers (3)**: cada partición tiene **1 líder + 2 réplicas**. `min.insync.replicas=2` y los
  productores usan `acks=all`, así que se puede seguir escribiendo con 1 broker caído sin perder datos.
- `auto.create.topics.enable=false`: los tópicos se crean a propósito (`kafka-init`, Kafka UI o kafka-admin).
- Cada broker tiene dos *listeners*: `kafka-N:29092` para los contenedores y
  `${KAFKA_ADVERTISED_HOST}:9092/9093/9094` para conectarse desde fuera de Docker
  (en AWS es la IP privada de la EC2 de Kafka).

### Tópicos

| Tópico | Productor | Consumer group (consumidor) | Particiones / réplicas | Política | Retención |
|---|---|---|---|---|---|
| `reservations.events` | reservations | `andesstay-audit` (audit), `andesstay-report-kpis` (report) | 3 / 3 | delete | 7 días |
| `audit.timeline` | audit | `andesstay-report-activity` (report) | 3 / 3 | compact,delete | 30 días |
| `reservations.events.audit.DLT` | audit (errores) | — | 3 / 3 | delete | 14 días |
| `reservations.events.report.DLT` | report (errores) | — | 3 / 3 | delete | 14 días |
| `audit.timeline.report.DLT` | report (errores) | — | 3 / 3 | delete | 14 días |

- **Key = id de la reserva**: todos los eventos de una misma reserva caen en la misma partición,
  así se procesan **en orden** (CREADA → CONFIRMADA → … → CHECKOUT).
- **Retención**: `reservations.events` guarda 7 días de historia (se puede reprocesar desde el inicio).
  `audit.timeline` es *compact,delete*: durante 7 días (`min.compaction.lag.ms`) guarda todo; después la
  compactación deja solo el último registro de cada reserva y a los 30 días se borra.
- **Errores**: el consumidor reintenta 2 veces (cada 2 s) y si sigue fallando manda el mensaje al
  **DLT** (`<tópico>.<consumidor>.DLT`). Un JSON inválido va directo al DLT, sin reintentos.
- **Idempotencia**: audit y report guardan el `eventId`; si un evento llega dos veces no se duplica.

Ejemplo de evento en `reservations.events` (key `"42"`):

```json
{
  "type": "reservation.confirmada",
  "eventId": "7d1c1b3e-2f0a-4c55-9a43-5b0f7a3c9e11",
  "timestamp": "2026-11-22T15:04:05.123Z",
  "traceId": "c0a8017e-3b9f-4f5e-a1d2-8e7f6a5b4c3d",
  "correlationId": "reservation-42",
  "payload": {
    "reservationId": 42, "userEmail": "cliente@andesstay.cl", "accommodationId": 3,
    "checkInDate": "2026-12-20", "checkOutDate": "2026-12-23", "guests": 2, "totalAmount": 255000,
    "previousStatus": "CREADA", "newStatus": "CONFIRMADA",
    "performedBy": "operador@andesstay.cl", "performedRole": "OPERADOR", "sourceIp": "190.100.20.30"
  }
}
```

### Verificar

```powershell
docker exec kafka-1 kafka-topics --bootstrap-server kafka-1:29092 --describe --topic reservations.events
docker exec kafka-1 kafka-consumer-groups --bootstrap-server kafka-1:29092 --list
docker exec kafka-1 kafka-consumer-groups --bootstrap-server kafka-1:29092 --describe --group andesstay-report-kpis
docker exec kafka-1 kafka-console-consumer --bootstrap-server kafka-1:29092 --topic reservations.events --from-beginning --property print.key=true --property print.partition=true
```

En **Kafka UI** (http://localhost:8090): *Brokers* (3 brokers y el controller), *Topics* (particiones,
réplicas, mensajes y configuración), *Consumers* (grupos, miembros, offsets y **lag**).

Para mostrar el **lag**: `docker compose -f compose.local.yml stop report`, crear y confirmar reservas,
ver en Kafka UI cómo sube el lag de `andesstay-report-kpis`, y `docker compose -f compose.local.yml start report`
para ver cómo baja a 0. También se puede poner `KAFKA_PROCESSING_DELAY_MS=3000` en el `.env`.

## 4. Variables del archivo `.env`

| Variable | Para qué |
|---|---|
| `RABBITMQ_USER`, `RABBITMQ_PASSWORD` | Usuario de RabbitMQ (consola y microservicios) |
| `RABBITMQ_ERLANG_COOKIE` | Secreto del clúster RabbitMQ (igual en los 2 nodos) |
| `KAFKA_ADVERTISED_HOST` | `localhost` en el PC; IP privada de ec2-kafka en AWS |
| `KAFKA_UI_USER`, `KAFKA_UI_PASSWORD` | Login de Kafka UI |
| `RABBITMQ_ADDRESSES`, `KAFKA_BOOTSTRAP_SERVERS` | Solo en AWS (ec2-apps): IP privadas de ec2-mq y ec2-kafka |
| `RABBIT_PROCESSING_DELAY_MS` | Espera de cada consumidor RabbitMQ (10000 = 10 s) |
| `KAFKA_PROCESSING_DELAY_MS` | Retardo del consumidor Kafka de reportería (0 = tiempo real) |
| `CORS_ALLOWED_ORIGINS` | Orígenes del frontend que pueden llamar al BFF |
| `REGISTRATION_*`, `GRAPH_*` | Registro público con Microsoft Graph (apagado) |

**El archivo `.env` no se sube a GitHub** (está en `.gitignore`).

## 5. Despliegue en AWS

Ver [`docs/GUIA-DESPLIEGUE-AWS-CSR.md`](docs/GUIA-DESPLIEGUE-AWS-CSR.md): frontend en S3 + CloudFront
(CSR), API Gateway con JWT authorizer y 3 EC2 (`ec2-apps`, `ec2-mq`, `ec2-kafka`).

Para la presentación: [`docs/GUIA-PRESENTACION-EP6.md`](docs/GUIA-PRESENTACION-EP6.md).

## 6. Problemas comunes

| Síntoma | Qué hacer |
|---|---|
| `kafka-init` terminó con `Exited (1)` y las apps no parten | Los brokers tardaron en partir. Volver a ejecutar `docker compose -f compose.local.yml up -d` (el script usa `--if-not-exists`, se puede correr las veces que sea). |
| En `cluster_status` solo aparece un nodo | Unir el nodo 2 a mano: `docker exec rabbitmq-2 rabbitmqctl stop_app`, `docker exec rabbitmq-2 rabbitmqctl join_cluster rabbit@rabbitmq-1`, `docker exec rabbitmq-2 rabbitmqctl start_app`. |
| Un broker queda `unhealthy` o se reinicia | Falta memoria. En Windows (WSL2) se sube en `%UserProfile%\.wslconfig` con `[wsl2]` y `memory=8GB` (luego `wsl --shutdown`); en Mac/Linux en Docker Desktop → Settings → Resources. |
| Un microservicio aparece `Exited` | `docker compose -f compose.local.yml logs <servicio>`. Casi siempre es una variable del `.env` mal escrita. |
| El frontend dice "No fue posible conectar con el BFF" | Revisar que el BFF esté arriba (`http://localhost:8080/actuator/health`) y que `CORS_ALLOWED_ORIGINS` tenga `http://localhost:4200`. |
| Puerto ocupado al levantar (8080, 5672, 9092…) | Cerrar el programa que lo usa (otro Docker, Tomcat, etc.) o cambiar el puerto publicado en el compose. |
| Quiero partir de cero | `docker compose -f compose.local.yml down -v` borra colas, tópicos y bases H2. |

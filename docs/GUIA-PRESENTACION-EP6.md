# Guía para la presentación EP6 (DSY1107) — AndesStay

Duración: **5 a 10 minutos**, con preguntas del profe. Aunque se presenta en grupo, la nota es
**individual**: cada uno tiene que poder explicar cualquier parte. Esta guía junta (1) lo que la pauta
pide mostrar, (2) qué decir en cada indicador y (3) los comandos exactos.

---

## 1. Preparación (15 minutos antes)

- [ ] Encender **ec2-mq** y **ec2-kafka**, esperar 2-3 minutos y después **ec2-apps**.
- [ ] `curl http://<ELASTIC_IP>:8080/actuator/health` → `{"status":"UP"}`.
- [ ] Pestañas abiertas en el navegador:
  1. Frontend (`https://<cloudfront>`), con sesión de un usuario **ADMIN**.
  2. Consola RabbitMQ `http://<ip-ec2-mq>:15672`.
  3. Kafka UI `http://<ip-ec2-kafka>:8090`.
  4. Consola AWS: API Gateway (`rp7b03v3rd`), EC2, CloudFront.
  5. Portal de Azure: Microsoft Entra ID (tenant y usuarios).
  6. https://jwt.ms
- [ ] Terminales SSH abiertas en ec2-mq, ec2-kafka y ec2-apps.
- [ ] Un token copiado (F12 → *Network* → header `Authorization`) para los `curl` del API Manager.
- [ ] Usuarios de prueba con los roles **CLIENTE**, **OPERADOR**, **ADMIN** y **AUDITOR**.
- [ ] Postman con las colecciones de `ms-andesstay-rabbit-admin/postman` y `ms-andesstay-kafka-admin/postman`
      apuntando al BFF/API Gateway (opcional).

---

## 2. Guion sugerido (≈ 9 minutos)

| Min | Tema | Qué se muestra |
|---|---|---|
| 0:00 | Arquitectura general y CSR | Diagrama de `GUIA-DESPLIEGUE-AWS-CSR.md` (paso 0) |
| 1:00 | Identidad + API Manager | Login con Azure, token en jwt.ms, `curl` 401/200, rutas y authorizer en API Gateway |
| 2:30 | RabbitMQ | Clúster de 2 nodos, exchanges direct/topic, 3 colas + DLQ, confirmar una reserva y ver los mensajes Unacked |
| 4:00 | Kafka: arquitectura y tópicos | `docker compose ps`, ZooKeeper/brokers, Kafka UI: 2 tópicos 3×3 |
| 5:30 | Flujo de eventos y tiempo real | Confirmar/checkout → panel de reportería y auditoría se actualizan solos |
| 7:00 | Administración y supervisión | Consumer groups, offsets, **lag** (detener `report` y volver a encender), retención |
| 8:30 | Casos de uso y cierre | Tabla de casos de uso (sección 4.9) |

---

## 3. Elementos obligatorios de la presentación

| Elemento que pide la pauta | Qué mostrar | Dónde / comando |
|---|---|---|
| Instancia del API Manager en la nube | La HTTP API `rp7b03v3rd`, stage `$default` | Consola AWS → API Gateway |
| Configuración que llama al backend | *Routes* (`ANY /api/{proxy+}`, `ANY /api/public/{proxy+}`) e *Integrations* (`http://<EIP>:8080/api/{proxy}`) | API Gateway → Develop |
| El frontend consume la API por el API Manager | F12 → *Network*: las llamadas van a `rp7b03v3rd.execute-api...amazonaws.com/api/...` | Navegador |
| El API Manager valida JWT (rechaza y acepta) | `curl` sin token y con token falso → **401**; con token real → **200** | Sección 3.1 |
| Tenant en IDaaS y usuarios registrados | Entra ID → *Overview* (Tenant ID) → *Users*; *Enterprise applications* → la API → *Users and groups* (roles asignados) | Portal Azure |
| Login con OAuth 2.0 / OIDC y JWT válido | Redirección a `login.microsoftonline.com`; pegar el token en jwt.ms (`iss`, `aud`, `scp`, `roles`, `exp`) | Navegador |
| Backend y frontend desplegados e integrados | CloudFront funcionando + las 3 EC2 *running* + flujo completo de una reserva | AWS + frontend |
| Dos nodos RabbitMQ en clúster | `rabbitmqctl cluster_status` y la tabla *Nodes* en *Overview* | Sección 3.2 |
| Tres colas con su DLQ funcionando | *Queues*: `q.cmd.email`, `q.cmd.housekeeping`, `q.cmd.voucher` + `.dlq`; enviar un mensaje inválido y verlo en la DLQ | Sección 3.2 |
| Exchanges direct y topic | *Exchanges*: `cmd.direct` (direct), `cmd.topic` (topic), `cmd.dead.dlx`, con sus *bindings* | Consola RabbitMQ |
| docker-compose levantando RabbitMQ/Kafka en la nube | `docker compose ... ps` en ec2-mq y ec2-kafka | Sección 3.3 |
| Kafka UI: 2 tópicos con 3 particiones y 3 réplicas | *Topics*: `reservations.events` y `audit.timeline` (Partitions 3, Replication Factor 3) | Kafka UI |

### 3.1 API Manager y JWT

```bash
API=https://rp7b03v3rd.execute-api.us-east-1.amazonaws.com
curl -i $API/api/public/status                                       # 200 (ruta pública, sin authorizer)
curl -i $API/api/secure/me                                           # 401 {"message":"Unauthorized"} -> lo corta API Gateway
curl -i -H "Authorization: Bearer abc.def.ghi" $API/api/secure/me    # 401 (firma inválida)
curl -i -H "Authorization: Bearer $TOKEN" $API/api/secure/me         # 200 con usuario, roles, iss y aud
curl -i -H "Authorization: Bearer $TOKEN_CLIENTE" $API/api/reports/kpis   # 403: token válido pero sin rol ADMIN (lo corta el BFF)
```

Qué decir: *"El authorizer JWT de API Gateway revisa la firma con las llaves públicas de Azure (JWKS), el
`iss` (nuestro tenant) y el `aud` (la API de AndesStay). Si falla, la petición ni siquiera llega a la EC2.
Después el BFF y cada microservicio validan de nuevo el token y revisan los roles: defensa en profundidad."*

### 3.2 RabbitMQ

```bash
# ec2-mq
docker exec rabbitmq-1 rabbitmqctl cluster_status
docker exec rabbitmq-1 rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers
docker exec rabbitmq-1 rabbitmqctl list_bindings source_name destination_name routing_key
```

- **Confirmar una reserva** en el frontend → en *Queues* se ve **1 Unacked** en `q.cmd.email`, `q.cmd.housekeeping`
  y `q.cmd.voucher` durante ~10 s (el consumidor lo retiene a propósito) y luego vuelven a 0 (ACK).
  Si se confirman varias seguidas, las siguientes quedan como **Ready** (prefetch = 1).
- **DLQ**: *Exchanges* → `cmd.direct` → *Publish message* → routing key `email.send`, propiedad
  `content_type=application/json` y el JSON con `"recipient":"correo-invalido"` (está en el README de
  infra) → el mensaje termina en `q.cmd.email.dlq`.
- **Direct vs topic**: confirmar usa `cmd.direct` (keys exactas `email.send`, `housekeeping.ticket`,
  `voucher.gen`); checkout usa `cmd.topic` (`email.checkout`, `housekeeping.clean.3`, `voucher.boleta`), que
  llegan por los patrones `email.*`, `housekeeping.#` y `voucher.*`.

### 3.3 Docker Compose en la nube

```bash
# ec2-mq
cd ~/infra-andesstay-messaging && docker compose -f mq/compose.yml ps
# ec2-kafka
cd ~/infra-andesstay-messaging && docker compose -f kafka/compose.yml ps
# ec2-apps
cd ~/andesstay/infra-andesstay-messaging && docker compose -f apps/compose.yml ps
```

---

## 4. Indicadores de la pauta: qué decir y qué demostrar

### 4.1 Arquitectura Kafka con Docker Compose (10 %)

- **3 ZooKeeper** (`zookeeper-1..3`): guardan los metadatos del clúster (qué brokers existen, qué tópicos y
  particiones hay, quién es líder) y eligen al **broker controller**. Funcionan por **quórum**: con 3 nodos la
  mayoría es 2, así que **sigue funcionando si se cae 1**. Si se caen 2, no se pueden elegir líderes nuevos.
- **3 brokers** (`kafka-1..3`): guardan los datos. Cada partición tiene **1 líder** (recibe escrituras y
  lecturas) y **2 seguidores** que la copian; las réplicas al día forman el **ISR**.
- **Tolerancia a fallos**: `replication-factor=3`, `min.insync.replicas=2` y productor con `acks=all`
  → si se cae 1 broker se sigue escribiendo y leyendo sin perder datos; si se caen 2, Kafka **rechaza
  escrituras** antes que arriesgar pérdida (elegimos consistencia).
- `kafka-init` crea los tópicos y `kafka-ui` permite administrarlos. `auto.create.topics.enable=false`.

**Demo de tolerancia a fallos (ec2-kafka):**

```bash
docker exec kafka-1 zookeeper-shell zookeeper-1:2181 ls /brokers/ids      # [1, 2, 3]
docker exec kafka-1 zookeeper-shell zookeeper-1:2181 get /controller      # qué broker es el controller
docker stop kafka-2                                                       # "se cae" un broker
docker exec kafka-1 kafka-topics --bootstrap-server kafka-1:29092 --describe --topic reservations.events
#   -> los líderes de las particiones de kafka-2 pasan a otro broker y el ISR queda con 2 réplicas
#   -> en el frontend se sigue pudiendo crear y confirmar reservas
docker start kafka-2                                                      # vuelve y el ISR se recupera a 3
```

### 4.2 Dos tópicos con 3 particiones y 3 réplicas (10 %)

| | `reservations.events` | `audit.timeline` |
|---|---|---|
| Qué guarda | Cada cambio de estado de una reserva | El historial de auditoría: quién, qué, cuándo, desde dónde |
| Productor | reservations | audit |
| Consumidores | audit (`andesstay-audit`) y report (`andesstay-report-kpis`) | report (`andesstay-report-activity`) |
| Retención | 7 días, `delete` | 30 días, `compact,delete` |

- **3 particiones = paralelismo**: cada consumer group tiene 3 consumidores (`concurrency: 3`), uno por
  partición, que procesan en paralelo. Si llega mucho volumen se pueden levantar más instancias, hasta 3
  consumidores activos por grupo (no sirve tener más consumidores que particiones).
- **Orden**: la *key* del mensaje es el **id de la reserva** → todos los eventos de una reserva van a la
  **misma partición** y se procesan en orden (CREADA → CONFIRMADA → … → CHECKOUT). Distintas reservas se
  reparten entre las 3 particiones.
- **3 réplicas = resiliencia**: cada partición existe en los 3 brokers; con `min.insync.replicas=2` no se
  pierde nada si se cae un broker.

### 4.3 Kafka UI (5 %)

- **Brokers**: los 3 brokers, cuál es el controller, cuántas particiones lidera cada uno.
- **Topics**: particiones, réplicas, ISR, configuración (`retention.ms`, `cleanup.policy`,
  `min.insync.replicas`) y pestaña **Messages** (ver los eventos por partición y offset, con su key).
  También se puede crear un tópico o **producir un mensaje** de prueba desde aquí.
- **Consumers**: los grupos, sus miembros, qué partición tiene cada uno, offsets y **lag**.
- Lo mismo se puede hacer por API con **ms-andesstay-kafka-admin** (`/api/kafka/topics`,
  `/api/kafka/consumer-groups/{id}`), que es el microservicio administrador de Kafka del caso.

### 4.4 Flujo de producción y consumo (12 %)

```
Usuario confirma ──► reservations (guarda en BD)
                        │ después del commit
                        ├──► RabbitMQ: comandos (correo, limpieza, voucher)     <- se mantiene igual
                        └──► Kafka reservations.events (key = id reserva)
                                 ├──► audit  (grupo andesstay-audit) ──► guarda ──► Kafka audit.timeline
                                 │                                                     └──► report (andesstay-report-activity) -> "Última actividad"
                                 └──► report (grupo andesstay-report-kpis) ──► KPIs en tiempo real
```

Qué decir:

- reservations **no sabe** quién consume sus eventos: se pueden agregar consumidores nuevos sin tocarlo.
- Cada consumer group tiene **sus propios offsets**: audit y report leen el mismo tópico de forma
  independiente, cada uno a su ritmo (si report se cae, audit sigue).
- Los eventos quedan guardados (retención), así que un consumidor que estuvo caído **se pone al día solo**.
- Kafka **complementa** a RabbitMQ sin romperlo: RabbitMQ sigue con los comandos (una tarea, un
  consumidor, ACK); Kafka agrega el flujo de eventos para auditoría y analítica.
- Errores: 2 reintentos y luego el mensaje va al **DLT** del consumidor (`reservations.events.audit.DLT`, etc.).

### 4.5 Diseño de los eventos (6 %)

Mostrar un mensaje en Kafka UI → `reservations.events` → *Messages*:

| Campo | Para qué se necesita |
|---|---|
| `type` | Qué pasó (`reservation.confirmada`), sin abrir el payload |
| `eventId` | Id único: audit y report **no duplican** si el evento llega dos veces (idempotencia) |
| `timestamp` | Cuándo ocurrió de verdad (para KPIs por hora y tiempos de ciclo) |
| `traceId`, `correlationId` | Seguir la misma acción en RabbitMQ, Kafka y los logs |
| `reservationId` | Es la **key**: orden por reserva y línea de tiempo |
| `previousStatus` → `newStatus` | La transición: permite calcular tiempo de confirmación, tiempo de ciclo y ocupación actual |
| `accommodationId` | Unidades más demandadas |
| `totalAmount` | Monto confirmado |
| `checkInDate`, `checkOutDate`, `guests`, `userEmail` | Contexto de la reserva para auditoría |
| `performedBy`, `performedRole`, `sourceIp` | **Quién** lo hizo, con qué rol y **desde dónde** (lo pide el caso para auditoría) |

El evento lleva **todo lo necesario** para que audit y report trabajen **sin llamar** a reservations
(no hay acoplamiento ni consultas extra).

### 4.6 Reacción en tiempo real (12 %)

1. Abrir **Reportería** → *Indicadores en tiempo real* (se actualiza solo cada 5 s y muestra
   "Actualizado hace unos segundos · HH:mm:ss").
2. En otra pestaña, crear una reserva y confirmarla. El mensaje que ve el usuario es de negocio:
   *"Reserva confirmada. Enviaremos la confirmación al correo del huésped y prepararemos la habitación."*
3. En segundos: suben *Reservas creadas* y *Confirmadas*, la reserva aparece en *Última actividad*
   (estado, quién y cuándo) y cambia la barra de la hora actual.
4. Hacer check-in y check-out: cambian **ocupación activa**, **llegadas pendientes** y **tiempo de ciclo**.
5. **Auditoría** muestra el *Historial de la reserva*: quién, rol (Cliente, Recepción, Administrador,
   Auditor), cuándo y desde qué IP.
6. A los ~10 s aparecen el voucher/boleta (Reportería) y el ticket de limpieza (Catálogo).

> **Importante:** la página es para el cliente (la cadena de alojamientos), por eso **no muestra detalles
> técnicos**: ni tópicos, ni colas, ni particiones, ni offsets, ni lag, ni traceId. Para demostrar que el
> evento pasó por Kafka y los comandos por RabbitMQ se usan las herramientas de operación:
>
> - **Kafka UI** → *Topics* → `reservations.events` / `audit.timeline` → *Messages*: partición, offset y key
>   de cada evento; *Consumers*: offsets y **lag** de cada grupo.
> - **Consola de RabbitMQ** → *Queues*: `q.cmd.email`, `q.cmd.housekeeping`, `q.cmd.voucher` (Unacked ~10 s y
>   luego 0) y sus DLQ.
> - **ms-andesstay-kafka-admin**: `GET /api/kafka/topics/...` y
>   `GET /api/kafka/consumer-groups/andesstay-audit` (lag por partición).
>
> Los datos siguen llegando al frontend en la respuesta de la API (los campos no se borraron); solo se
> dejaron de mostrar.

### 4.7 Administración de la plataforma Kafka (15 %)

| Configuración | Valor | Qué resuelve |
|---|---|---|
| Particiones | 3 | Rendimiento: 3 consumidores en paralelo por grupo |
| Réplicas / `min.insync.replicas` | 3 / 2 | Disponibilidad y consistencia con 1 broker caído |
| `acks=all` + `enable.idempotence` | productor | No se pierden ni duplican eventos al reintentar |
| `retention.ms` | 7 d (`reservations.events`), 30 d (`audit.timeline`), 14 d (DLT) | Poder reprocesar y revisar errores |
| `cleanup.policy` | `delete` / `compact,delete` | `audit.timeline`: después de 7 días (`min.compaction.lag.ms`) deja solo el último registro de cada reserva |
| Consumer groups | `andesstay-audit`, `andesstay-report-kpis`, `andesstay-report-activity` | Cada necesidad lee a su ritmo con sus propios offsets |
| `auto-offset-reset=earliest` | consumidores | Un grupo nuevo lee desde el principio (replay) |
| `auto.create.topics.enable=false` | brokers | No se crean tópicos "fantasma" por un error de tipeo |
| DLT por consumidor | `*.audit.DLT`, `*.report.DLT` | Un mensaje malo no bloquea la partición |

Demo con el administrador (por el BFF, rol ADMIN): `GET /api/kafka/topics/reservations.events`
(líder, réplicas, ISR, offsets) y `GET /api/kafka/consumer-groups/andesstay-audit` (lag por partición).

### 4.8 Supervisión: offsets, lag y distribución (15 %)

```bash
# ec2-kafka
docker exec kafka-1 kafka-consumer-groups --bootstrap-server kafka-1:29092 --describe --group andesstay-report-kpis
#  TOPIC                PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID  HOST
#  reservations.events  0          14              14              0    consumer-…   /172.31.x.x
```

- **CURRENT-OFFSET**: hasta dónde procesó el grupo. **LOG-END-OFFSET**: el último mensaje del tópico.
  **LAG** = la diferencia = mensajes pendientes. **CONSUMER-ID/HOST**: qué consumidor tiene cada partición
  (distribución del consumo).

**Demo del lag (ec2-apps):**

```bash
docker compose -f apps/compose.yml stop report      # el consumidor "se cae"
# crear y confirmar 3 o 4 reservas en el frontend
# Kafka UI -> Consumers -> andesstay-report-kpis: el LAG sube (audit sigue en 0: grupos independientes)
docker compose -f apps/compose.yml start report     # vuelve, procesa lo pendiente y el LAG baja a 0
```

Qué decir: *"Si el lag crece y no baja, el consumidor está caído o es más lento que la llegada de eventos.
Lo vemos antes de que el usuario note datos atrasados y podemos escalar consumidores (hasta 3, uno por
partición) o revisar el DLT. Como los eventos quedan guardados 7 días, no se pierde nada mientras tanto."*

(Otra opción: poner `KAFKA_PROCESSING_DELAY_MS=3000` en el `.env` para simular un consumidor lento.)

### 4.9 Casos de uso que necesitan streaming (15 %)

| Caso de uso | Tópico / grupo | Configuración que lo resuelve |
|---|---|---|
| Auditoría y trazabilidad (quién / qué / cuándo / desde dónde) | `reservations.events` → `andesstay-audit` | Key = reserva (orden), idempotencia por `eventId`, DLT, retención 7 d para reprocesar |
| Panel de KPIs en tiempo real (reservas por hora, tiempo de ciclo, ocupación activa, unidades más demandadas) | `reservations.events` → `andesstay-report-kpis` | Grupo propio (no afecta a audit), 3 particiones en paralelo, `earliest` para reconstruir los KPIs |
| Feed de actividad reciente | `audit.timeline` → `andesstay-report-activity` | `compact,delete`: historial completo 7 días y luego el último estado de cada reserva hasta 30 días |
| Reprocesar / agregar un servicio nuevo (ej. analítica) | cualquier tópico, grupo nuevo | Retención + offsets por grupo: lee la historia sin molestar a los demás |
| Mensajes con error | `*.DLT` | Retención 14 días para revisar y reenviar |
| Comandos (correo, limpieza, voucher) | **RabbitMQ** (no Kafka) | Cola de trabajo con ACK, DLQ y routing direct/topic: cada comando se hace una sola vez |

---

## 5. Preguntas que podría hacer el profe

| Pregunta | Respuesta corta |
|---|---|
| ¿Por qué usar Kafka **y** RabbitMQ? | RabbitMQ para **comandos** (una tarea, un consumidor, se borra al hacer ACK). Kafka para **eventos** (quedan guardados, varios grupos los leen, replay, analítica). |
| ¿Qué pasa si se cae un broker? ¿Y dos? | Con 1: se eligen nuevos líderes y se sigue funcionando (ISR = 2). Con 2: no se cumple `min.insync.replicas=2` y se rechazan escrituras para no perder datos. |
| ¿Y si se cae un ZooKeeper? | Quedan 2 de 3: hay quórum y todo sigue. Con 2 caídos no hay quórum y no se pueden cambiar líderes ni crear tópicos. |
| ¿Por qué 3 particiones y no 10? | 3 consumidores en paralelo por grupo es suficiente para el volumen del caso; más particiones = más archivos, más rebalanceos y más carga en los brokers. |
| ¿Cómo garantizan el orden? | Key = id de la reserva → misma partición → orden garantizado dentro de la partición. |
| ¿Y si un evento llega dos veces? | El productor es idempotente y los consumidores guardan el `eventId` único: no se duplica. |
| ¿Qué es el lag? | Mensajes que el grupo todavía no procesa (`LOG-END-OFFSET − CURRENT-OFFSET`). Sirve para detectar consumidores caídos o lentos. |
| ¿Qué pasa si Kafka está caído al confirmar una reserva? | La reserva se guarda igual y los comandos de RabbitMQ salen; el error de Kafka queda en el log. Una mejora sería el patrón *outbox*. |
| ¿Por qué ZooKeeper si Kafka 4 usa KRaft? | La pauta pide ZooKeeper; usamos Confluent 7.5 (Kafka 3.5), que todavía lo soporta. En KRaft los controladores reemplazan a ZooKeeper. |
| ¿Por qué validar el JWT en API Gateway si el backend también lo valida? | Defensa en profundidad: API Gateway corta las peticiones inválidas antes de llegar a la EC2, y el backend revisa además los roles. |
| ¿Qué es CSR? | El servidor entrega solo archivos estáticos y el navegador arma la página con JavaScript. Por eso el frontend vive en S3/CloudFront y CloudFront responde `index.html` en las rutas de Angular. |
| ¿Cómo saben desde dónde se hizo un cambio? | API Gateway agrega el header `Forwarded` con la IP del usuario, el BFF la pasa en `X-Forwarded-For` y reservations la guarda en el evento (`sourceIp`). |

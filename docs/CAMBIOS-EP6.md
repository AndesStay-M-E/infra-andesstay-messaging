# Cambios de la EP6 por repositorio

Resumen de lo que se cambió en cada repo (sirve para el mensaje del commit y para estudiar).

## infra-andesstay-messaging
- El `docker-compose.yml` único se separó en tres archivos, uno por EC2:
  `mq/compose.yml` (RabbitMQ 2 nodos en clúster), `kafka/compose.yml` (3 ZooKeeper + 3 brokers +
  Kafka UI + `kafka-init`) y `apps/compose.yml` (8 microservicios). `compose.local.yml` junta todo para el PC.
- `mq/rabbitmq.conf` corregido (las claves anteriores no eran válidas): `classic_config` con los 2 nodos.
- `kafka/create-topics.sh`: `reservations.events` y `audit.timeline` (3 particiones, 3 réplicas,
  `min.insync.replicas=2`) + 3 DLT.
- `.env.example` con todas las variables (las claves ya no están escritas en los compose).
- Zona horaria `America/Santiago` en los contenedores de las apps.
- README nuevo y `docs/` (guía AWS CSR, guía de presentación y este archivo).

## ms-andesstay-reservations
- **Kafka**: publica cada cambio de estado en `reservations.events` (key = id de la reserva, `acks=all`, idempotente), después del commit.
- RabbitMQ con los nombres del caso: `cmd.direct`, `cmd.topic`, `cmd.dead.dlx`, `q.cmd.email|housekeeping|voucher` + DLQ.
  Check-in, checkout y cancelación usan el exchange topic. En el checkout se pide la boleta.
- Conexión a los 2 nodos de RabbitMQ (`spring.rabbitmq.addresses`).
- Los eventos guardan quién hizo el cambio, su rol y su IP.
- Validación de sobreventa (409 si las fechas se cruzan con otra reserva activa).
- OPERADOR puede ver todas las reservas, confirmar y avanzar estados.
- `pom.xml`: se quitó `ojdbc17` y dependencias de test que no se usaban; se agregó `spring-boot-starter-kafka`.

## ms-andesstay-notify / ms-andesstay-catalog
- Nombres nuevos de colas y exchanges (direct + topic).
- Prefetch 1 y **espera de 10 s** (`RABBIT_PROCESSING_DELAY_MS`) antes de procesar, para ver los mensajes Unacked/Ready en RabbitMQ.
- notify: correo de cancelación. catalog: ticket CLEAN_ROOM por `housekeeping.clean.<id>`.
- `pom.xml` solo con lo necesario (notify ya no levanta servidor web).

## ms-andesstay-report
- Vouchers (`VCH`) al confirmar y **boletas** (`BOL`) al hacer checkout, con la espera visible de RabbitMQ.
- **Kafka**: consume `reservations.events` (grupo `andesstay-report-kpis`) y `audit.timeline`
  (grupo `andesstay-report-activity`), con reintentos y DLT.
- Nuevos endpoints: `/api/reports/kpis`, `/api/reports/top-units`, `/api/reports/activity`.

## ms-andesstay-audit
- **Se pasó de RabbitMQ a Kafka**: consume `reservations.events` (grupo `andesstay-audit`) y publica cada
  registro en `audit.timeline`. Se borraron las clases de RabbitMQ.
- Guarda quién, rol, IP, partición y offset. Filtros por fecha (`from`, `to`). DLT para errores.

## ms-andesstay-rabbit-admin
- Recursos protegidos con los nombres nuevos y conexión a los 2 nodos. README y Postman actualizados.

## ms-andesstay-bff
- Proxies `/api/rabbit/**` y `/api/kafka/**` (rol ADMIN) y rutas de KPIs de reportería.
- Envía la IP real del usuario a los microservicios (lee el header `Forwarded` de API Gateway).
- Copia el header `Location` en las respuestas 201. README nuevo.

## ms-andesstay-kafka-admin (repo NUEVO)
- Microservicio administrador de Kafka (puerto 8087): clúster, tópicos (crear, ver, eliminar, recrear los
  del sistema), mensajes de prueba y consumer groups con lag. Colección de Postman y README.

## frontend-andesstay
- MSAL usa el origen actual como `redirectUri` (funciona en localhost, CloudFront y Amplify).
- Reportería: **panel en tiempo real (Kafka)** que se actualiza cada 5 s + vouchers y boletas.
- Auditoría: quién, rol, IP, partición/offset y filtros por fecha.
- Reservas: el OPERADOR ve y gestiona todas las reservas.
- `amplify.yml` para publicar en Amplify. README nuevo.

En todos los microservicios se corrigió el `EXPOSE` del Dockerfile al puerto real de cada uno.

---

## Subir a GitHub

En cada repo que ya existía (desde su carpeta):

```powershell
git status
git add -A
git commit -m "EP6: integración de Kafka, clúster RabbitMQ y correcciones"
git push
```

El repo **nuevo** `ms-andesstay-kafka-admin`: primero crearlo vacío en la organización `AndesStay-M-E`
(sin README ni .gitignore) y después:

```powershell
cd ms-andesstay-kafka-admin
git init
git add -A
git commit -m "EP6: microservicio administrador de Kafka"
git branch -M main
git remote add origin https://github.com/AndesStay-M-E/ms-andesstay-kafka-admin.git
git push -u origin main
```

Antes de hacer `git add`, revisar que **no** aparezca ningún archivo `.env` ni carpetas `data/` o `target/`.

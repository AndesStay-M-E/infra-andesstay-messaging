# Guía de despliegue en AWS — Arquitectura CSR (AndesStay, EP6)

Esta guía explica, paso a paso, cómo dejamos AndesStay funcionando en AWS con una arquitectura
**CSR (Client-Side Rendering)**: el frontend Angular se publica como archivos estáticos y **todo se
dibuja en el navegador**; el navegador habla con el backend solo por la API (JSON + token JWT).

> Región: **us-east-1 (N. Virginia)**. Si usan AWS Academy Learner Lab, también sirve: permite
> instancias hasta tamaño *large*, discos de hasta 100 GB y las regiones us-east-1 / us-west-2.

---

## 0. Qué vamos a construir

```
                         ┌──────────────── Azure AD (Entra ID) ────────────────┐
                         │ login OAuth 2.0 / OpenID Connect -> token JWT (v2.0) │
                         └───────────────────────▲──────────────────────────────┘
                                                 │ MSAL (redirección)
 Usuario ──► CloudFront ──► S3 privado (index.html, main-xxxx.js, styles-xxxx.css)     <- CSR
    │
    │  HTTPS + "Authorization: Bearer <JWT>"
    ▼
 API Gateway (HTTP API rp7b03v3rd)  ── JWT Authorizer (firma, iss, aud) ── CORS
    │  integración HTTP
    ▼
 EC2 ec2-apps ── :8080 BFF ──► reservations · catalog · report · audit · rabbit-admin · kafka-admin
    │                  (Docker Compose: apps/compose.yml)
    │ 5672/5673                          │ 9092/9093/9094
    ▼                                    ▼
 EC2 ec2-mq                           EC2 ec2-kafka
 RabbitMQ rabbitmq-1 + rabbitmq-2     zookeeper-1..3 + kafka-1..3 + kafka-ui
 (mq/compose.yml)                     (kafka/compose.yml)
```

| Pieza | Servicio AWS | Por qué |
|---|---|---|
| Frontend (CSR) | **S3 + CloudFront** (o Amplify) | Son solo archivos estáticos: no hace falta un servidor Node. CloudFront los entrega por HTTPS y los guarda en caché cerca del usuario. |
| API Manager | **API Gateway (HTTP API)** | Una sola URL pública para el backend. Valida el JWT de Azure **antes** de llegar a la EC2 y maneja CORS. |
| Backend | **EC2 ec2-apps** + Docker Compose | Los 8 microservicios; solo el BFF (8080) queda expuesto. |
| Mensajería | **EC2 ec2-mq** | Clúster RabbitMQ de 2 nodos (comandos). |
| Streaming | **EC2 ec2-kafka** | 3 ZooKeeper + 3 brokers + Kafka UI (eventos). |
| Identidad | **Azure AD (Entra ID)** | Ya configurado. Solo hay que agregar la URL de CloudFront (paso 11). |

**¿Por qué CSR y no SSR?** En SSR un servidor arma el HTML en cada petición. En CSR el servidor solo
entrega el mismo `index.html` + JavaScript, y Angular construye la pantalla en el navegador y pide
los datos a la API. Por eso:

- el frontend se hospeda en S3/CloudFront (barato, escalable, sin servidores que mantener),
- las rutas (`/reservations`, `/reports`, …) las resuelve Angular: CloudFront tiene que responder
  `index.html` cuando se pide una ruta que no existe como archivo (paso 9.4),
- el login lo hace el navegador con MSAL y el token viaja en cada llamada a la API.

### Anota estos datos (los vas a usar en varios pasos)

| Dato | Ejemplo | Se usa en |
|---|---|---|
| IP **privada** de ec2-mq | `172.31.20.20` | `.env` de ec2-apps |
| IP **privada** de ec2-kafka | `172.31.20.30` | `.env` de ec2-kafka y de ec2-apps |
| **Elastic IP** de ec2-apps | `3.220.10.10` | integración de API Gateway |
| URL de API Gateway | `https://rp7b03v3rd.execute-api.us-east-1.amazonaws.com` | `environment.production.ts` |
| Dominio de CloudFront | `https://d1a2b3c4d5e6f7.cloudfront.net` | Azure (redirect URI) y CORS |
| Tu IP pública | la que muestra https://checkip.amazonaws.com | Security groups (SSH y consolas) |

---

## 1. Antes de empezar

- [ ] Los 10 repositorios subidos a GitHub (organización `AndesStay-M-E`), **incluido el nuevo
      `ms-andesstay-kafka-admin`** (hay que crearlo en la organización antes de subirlo).
- [ ] Ningún archivo `.env` subido a GitHub (solo `.env.example`).
- [ ] Node.js 22 en el PC para compilar el frontend.
- [ ] Un par de llaves para SSH (en Learner Lab: `vockey`, se descarga como `labsuser.pem`
      desde *AWS Details*). También se puede entrar con **EC2 Instance Connect** desde la consola.

---

## 2. Security Groups

EC2 → **Security Groups** → *Create security group* (en la VPC por defecto). Crear los tres:

**`sg-andesstay-apps`** (para ec2-apps)

| Tipo | Puerto | Origen | Para qué |
|---|---|---|---|
| SSH | 22 | Mi IP | Administrar |
| TCP personalizado | 8080 | 0.0.0.0/0 | API Gateway llama al BFF (las IP de API Gateway no son fijas) |

**`sg-andesstay-mq`** (para ec2-mq)

| Tipo | Puerto | Origen | Para qué |
|---|---|---|---|
| SSH | 22 | Mi IP | Administrar |
| TCP personalizado | 5672-5673 | `sg-andesstay-apps` | AMQP de los microservicios (nodo 1 y nodo 2) |
| TCP personalizado | 15672-15673 | Mi IP | Consola web de RabbitMQ (nodo 1 y nodo 2) |

**`sg-andesstay-kafka`** (para ec2-kafka)

| Tipo | Puerto | Origen | Para qué |
|---|---|---|---|
| SSH | 22 | Mi IP | Administrar |
| TCP personalizado | 9092-9094 | `sg-andesstay-apps` | Los 3 brokers |
| TCP personalizado | 8090 | Mi IP | Kafka UI |

> No se abren 2181/2888/3888 (ZooKeeper), 29092 (entre brokers) ni 25672/4369 (clúster RabbitMQ):
> esa comunicación pasa por la red interna de Docker dentro de cada EC2.
> Como origen se pone el **security group** de apps (no una IP): así solo las EC2 que tengan ese
> grupo pueden conectarse a RabbitMQ y Kafka.

---

## 3. Crear las 3 instancias EC2

EC2 → **Launch instances**, una por cada fila:

| Nombre | AMI | Tipo | Disco | Security group |
|---|---|---|---|---|
| `ec2-mq` | Ubuntu Server 24.04 LTS | t3.small (o t3.medium) | 20 GB gp3 | `sg-andesstay-mq` |
| `ec2-kafka` | Ubuntu Server 24.04 LTS | **t3.large** (8 GB RAM) | 30 GB gp3 | `sg-andesstay-kafka` |
| `ec2-apps` | Ubuntu Server 24.04 LTS | **t3.large** (8 GB RAM) | 30 GB gp3 | `sg-andesstay-apps` |

- *Key pair*: `vockey` (Learner Lab) o la que tengan.
- *Network settings*: VPC por defecto, **Auto-assign public IP: Enable**.
- Al crearlas, anotar la **IP privada** de `ec2-mq` y `ec2-kafka` (pestaña *Details*). La IP privada
  no cambia al apagar/encender la instancia.

**Elastic IP para ec2-apps** (la IP pública normal cambia cada vez que se apaga la EC2 o se reinicia el lab):
EC2 → **Elastic IPs** → *Allocate Elastic IP address* → *Allocate* → *Actions* → *Associate Elastic IP address*
→ instancia `ec2-apps` → *Associate*. Anotar esa IP.

---

## 4. Instalar Docker (en las 3 EC2)

Conectarse por SSH (o con *EC2 Instance Connect* → *Connect*):

```powershell
# Windows PowerShell. Si reclama "UNPROTECTED PRIVATE KEY FILE":
#   icacls labsuser.pem /inheritance:r /grant:r "${env:USERNAME}:R"
ssh -i labsuser.pem ubuntu@<IP_PUBLICA_DE_LA_EC2>
```

Dentro de la EC2:

```bash
sudo apt-get update && sudo apt-get install -y git
curl -fsSL https://get.docker.com | sudo sh        # instala Docker Engine + plugin docker compose
sudo usermod -aG docker ubuntu                     # usar docker sin sudo
exit                                               # salir y volver a entrar para que tome el grupo
```

```bash
docker --version
docker compose version
```

En **ec2-kafka** y **ec2-apps** conviene agregar 4 GB de *swap* (evita que la compilación o los
brokers se caigan por falta de memoria):

```bash
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

> **Repos privados:** al clonar, GitHub pide usuario y contraseña. La contraseña es un
> **Personal Access Token** (GitHub → Settings → Developer settings → Personal access tokens →
> *Fine-grained*, acceso de solo lectura a *Contents* de los repos de la organización).
> Para no escribirlo 10 veces: `git config --global credential.helper 'cache --timeout=3600'`.

---

## 5. ec2-mq: RabbitMQ (2 nodos en clúster)

```bash
git clone https://github.com/AndesStay-M-E/infra-andesstay-messaging.git
cd infra-andesstay-messaging
cp .env.example .env
nano .env
```

En el `.env` cambiar **`RABBITMQ_PASSWORD`** y **`RABBITMQ_ERLANG_COOKIE`** (solo letras y números).
Guardar con `Ctrl+O`, `Enter`, `Ctrl+X`.

```bash
docker compose -f mq/compose.yml --env-file .env up -d
docker compose -f mq/compose.yml ps                 # rabbitmq-1 y rabbitmq-2 "healthy"
docker exec rabbitmq-1 rabbitmqctl cluster_status   # "Running Nodes": rabbit@rabbitmq-1 y rabbit@rabbitmq-2
```

Consola: `http://<IP_PUBLICA_EC2_MQ>:15672` (nodo 1) y `:15673` (nodo 2), con el usuario y clave del `.env`.
Las colas y exchanges aparecen cuando parten los microservicios (paso 7), porque ellos los declaran.

---

## 6. ec2-kafka: 3 ZooKeeper + 3 brokers + Kafka UI

```bash
git clone https://github.com/AndesStay-M-E/infra-andesstay-messaging.git
cd infra-andesstay-messaging
cp .env.example .env
nano .env
```

En el `.env`:

```bash
KAFKA_ADVERTISED_HOST=<IP_PRIVADA_EC2_KAFKA>     # ej. 172.31.20.30  (NO localhost, NO la IP pública)
KAFKA_UI_USER=admin
KAFKA_UI_PASSWORD=<una clave>
```

> `KAFKA_ADVERTISED_HOST` es la dirección que cada broker "anuncia" a los clientes. Los microservicios
> de ec2-apps se conectan primero a `IP:9092` y Kafka les responde "el líder de esta partición está en
> `IP:9093`"; si aquí quedara `localhost`, los microservicios intentarían conectarse a ellos mismos.

```bash
docker compose -f kafka/compose.yml --env-file .env up -d
docker compose -f kafka/compose.yml ps     # 3 zookeeper, 3 kafka "healthy", kafka-ui "running", kafka-init "Exited (0)"
docker logs kafka-init                     # lista y detalle de los tópicos creados
docker exec kafka-1 kafka-topics --bootstrap-server kafka-1:29092 --describe --topic reservations.events
```

Kafka UI: `http://<IP_PUBLICA_EC2_KAFKA>:8090` (usuario y clave del `.env`). Debe mostrar 3 brokers y los
tópicos `reservations.events` y `audit.timeline` con **3 particiones y 3 réplicas**.

> Si `kafka-init` quedó en `Exited (1)` (los brokers tardaron), se vuelve a ejecutar con
> `docker compose -f kafka/compose.yml --env-file .env up -d`; usa `--if-not-exists`, así que no duplica nada.

---

## 7. ec2-apps: los 8 microservicios

### 7.1 Clonar los repositorios uno al lado del otro

```bash
mkdir -p ~/andesstay && cd ~/andesstay
for repo in infra-andesstay-messaging ms-andesstay-bff ms-andesstay-reservations ms-andesstay-catalog \
            ms-andesstay-notify ms-andesstay-report ms-andesstay-audit ms-andesstay-rabbit-admin \
            ms-andesstay-kafka-admin; do
  git clone https://github.com/AndesStay-M-E/$repo.git
done
ls    # deben aparecer las 9 carpetas
```

### 7.2 Archivo `.env`

```bash
cd ~/andesstay/infra-andesstay-messaging
cp .env.example .env
nano .env
```

```bash
RABBITMQ_USER=andesstay
RABBITMQ_PASSWORD=<la MISMA clave que en ec2-mq>

# Descomentar y poner las IP PRIVADAS:
RABBITMQ_ADDRESSES=<IP_PRIVADA_EC2_MQ>:5672,<IP_PRIVADA_EC2_MQ>:5673
KAFKA_BOOTSTRAP_SERVERS=<IP_PRIVADA_EC2_KAFKA>:9092,<IP_PRIVADA_EC2_KAFKA>:9093,<IP_PRIVADA_EC2_KAFKA>:9094

RABBIT_PROCESSING_DELAY_MS=10000
KAFKA_PROCESSING_DELAY_MS=0

# Por ahora localhost y Amplify; en el paso 12 se agrega la URL de CloudFront.
CORS_ALLOWED_ORIGINS=http://localhost:4200,https://main.d32i73fsq9ui1t.amplifyapp.com
```

Probar que la EC2 llega a RabbitMQ y Kafka (si falla, revisar los security groups del paso 2):

```bash
nc -zv <IP_PRIVADA_EC2_MQ> 5672
nc -zv <IP_PRIVADA_EC2_KAFKA> 9092
```

### 7.3 Compilar y levantar

Se compila **de a una imagen** para no quedarse sin memoria (la primera vez demora 15-20 minutos
porque Maven descarga todas las dependencias):

```bash
cd ~/andesstay/infra-andesstay-messaging
for s in bff reservations catalog notify report audit rabbit-admin kafka-admin; do
  docker compose -f apps/compose.yml --env-file .env build "$s" || break
done

docker compose -f apps/compose.yml --env-file .env up -d
docker compose -f apps/compose.yml ps
```

Verificar:

```bash
curl -s http://localhost:8080/actuator/health                      # {"status":"UP"}
docker compose -f apps/compose.yml logs --tail=50 reservations     # sin errores de conexión a RabbitMQ/Kafka
docker compose -f apps/compose.yml logs --tail=50 audit            # "partitions assigned" del grupo andesstay-audit
```

Desde tu PC: `http://<ELASTIC_IP_EC2_APPS>:8080/actuator/health` → `{"status":"UP"}`.

Ahora en la consola de RabbitMQ (ec2-mq) ya aparecen `cmd.direct`, `cmd.topic`, `cmd.dead.dlx` y las colas
`q.cmd.email`, `q.cmd.housekeeping`, `q.cmd.voucher` con sus `.dlq`; y en Kafka UI → *Consumers* los grupos
`andesstay-audit`, `andesstay-report-kpis` y `andesstay-report-activity`.

---

## 8. API Gateway (el API Manager)

Si ya existe la API `rp7b03v3rd` de las evaluaciones anteriores, **revisar** cada punto; si no, crearla:
API Gateway → *Create API* → **HTTP API** → *Build* → nombre `andesstay-api` → (sin integraciones por ahora) →
stage **`$default`** con *Auto-deploy* → *Create*.

### 8.1 Integraciones

*Develop* → **Integrations** → *Manage integrations* → *Create*:

| Integración | Tipo | Método | URL |
|---|---|---|---|
| `bff-api` | HTTP URI | ANY | `http://<ELASTIC_IP_EC2_APPS>:8080/api/{proxy}` |
| `bff-public` | HTTP URI | ANY | `http://<ELASTIC_IP_EC2_APPS>:8080/api/public/{proxy}` |

> `{proxy}` toma el resto de la ruta: `GET /api/reservations/me` llega al BFF como
> `http://<IP>:8080/api/reservations/me`.

### 8.2 Rutas

*Develop* → **Routes** → *Create*:

| Ruta | Integración | Autorización |
|---|---|---|
| `ANY /api/{proxy+}` | `bff-api` | **JWT (azure-andesstay)** |
| `ANY /api/public/{proxy+}` | `bff-public` | Ninguna (registro y estado públicos) |

API Gateway elige siempre la ruta **más específica**, así que `/api/public/...` no pide token y todo lo
demás sí.

### 8.3 JWT Authorizer (validación del token de Azure)

*Develop* → **Authorization** → *Manage authorizers* → *Create*:

| Campo | Valor |
|---|---|
| Tipo | **JWT** |
| Nombre | `azure-andesstay` |
| Identity source | `$request.header.Authorization` |
| Issuer URL | `https://login.microsoftonline.com/4fe52189-087c-4613-8660-500431cc0eb9/v2.0` |
| Audience | `85237aa5-9ece-48d3-8767-9698df0efefa` y `api://85237aa5-9ece-48d3-8767-9698df0efefa` |

Luego en *Attach authorizers to routes* → seleccionar `ANY /api/{proxy+}` → `azure-andesstay` → *Attach*.

El authorizer descarga las llaves públicas de Azure (JWKS) y revisa **firma, `iss`, `aud` y expiración**.
Si algo no calza, responde `401 {"message":"Unauthorized"}` y la petición **nunca llega a la EC2**.
El BFF y cada microservicio vuelven a validar el token y además revisan los **roles** (`roles` del JWT).

### 8.4 CORS

*Develop* → **CORS** → *Configure*:

| Campo | Valor |
|---|---|
| Access-Control-Allow-Origin | `http://localhost:4200`, `https://main.d32i73fsq9ui1t.amplifyapp.com` (en el paso 12 se agrega CloudFront) |
| Access-Control-Allow-Headers | `authorization`, `content-type` |
| Access-Control-Allow-Methods | `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS` |
| Access-Control-Max-Age | `300` |
| Access-Control-Allow-Credentials | No (el token va en un header, no en cookies) |

Con CORS configurado, API Gateway responde solo los *preflight* `OPTIONS` y agrega los headers CORS a las
respuestas (ignora los que manda el backend).

### 8.5 Probar el API Manager (también sirve para la presentación)

```bash
API=https://rp7b03v3rd.execute-api.us-east-1.amazonaws.com

curl -i $API/api/public/status                                         # 200: ruta pública
curl -i $API/api/secure/me                                             # 401: sin token -> lo rechaza API Gateway
curl -i -H "Authorization: Bearer abc.def.ghi" $API/api/secure/me      # 401: token inválido
curl -i -H "Authorization: Bearer <TOKEN_REAL>" $API/api/secure/me     # 200: muestra usuario, roles, iss y aud
```

Para obtener `<TOKEN_REAL>`: iniciar sesión en el frontend → F12 → *Network* → cualquier llamada a
`execute-api` → *Request headers* → `Authorization` (copiar lo que va después de `Bearer `).
Se puede decodificar en https://jwt.ms para mostrar `iss`, `aud`, `scp` y `roles`.

---

## 9. Frontend CSR — Opción A: S3 + CloudFront

### 9.1 Compilar en el PC

Revisar que `src/environments/environment.production.ts` tenga la URL de API Gateway + `/api`:

```ts
apiUrl: 'https://rp7b03v3rd.execute-api.us-east-1.amazonaws.com/api',
```

```powershell
cd frontend-andesstay
npm ci
npm run build
```

El resultado queda en **`dist/frontend-andesstay/browser/`** (`index.html`, `main-XXXX.js`,
`styles-XXXX.css`, `favicon.ico`, …). Eso es todo lo que se publica.

### 9.2 Bucket S3

S3 → *Create bucket*:

- Nombre: `andesstay-frontend-<algo-único>` (el nombre es global).
- Región: us-east-1.
- **Block all public access: activado** (el bucket es privado; solo CloudFront podrá leerlo).
- **No** activar *Static website hosting* (con CloudFront + OAC no se usa).

### 9.3 Subir los archivos

En el bucket → *Upload* → arrastrar **el contenido** de `dist/frontend-andesstay/browser/`
(los archivos, no la carpeta `browser`) → *Upload*.

O con AWS CLI (en Learner Lab las credenciales están en *AWS Details* → *AWS CLI*):

```powershell
aws s3 sync dist/frontend-andesstay/browser s3://andesstay-frontend-<algo-único> --delete
```

### 9.4 Distribución de CloudFront

CloudFront → **Create distribution** (si la consola ofrece planes de precio, elegir el gratuito o *pay-as-you-go*):

1. *Distribution name*: `andesstay-frontend`.
2. Tipo: **Single website or app** → *Next*.
3. *Origin type*: **Amazon S3** → *Browse S3* → el bucket del paso 9.2.
4. **Use recommended origin settings**: crea el **Origin Access Control (OAC)** y actualiza sola la
   *bucket policy* para que solo esta distribución pueda leer el bucket.
5. *Security protections (WAF)*: **Do not enable** (para no generar costos).
6. *Create distribution*.

Cuando termine de crearse:

- *General* → *Settings* → **Edit** → **Default root object**: `index.html` → *Save changes*.
- *Error pages* → **Create custom error response** (dos veces):

| HTTP error code | Customize error response | Response page path | HTTP Response code |
|---|---|---|---|
| 403: Forbidden | Yes | `/index.html` | 200: OK |
| 404: Not Found | Yes | `/index.html` | 200: OK |

> **Por qué**: con un bucket privado + OAC, S3 responde **403** cuando se pide un archivo que no existe.
> Si el usuario recarga `https://.../reports`, no existe el archivo `reports`; CloudFront entonces entrega
> `index.html` con 200 y Angular dibuja la pantalla `/reports`. Esto es lo que hace funcionar el CSR.

Esperar a que *Last modified* deje de decir *Deploying* y anotar el dominio (`d1a2b3c4d5e6f7.cloudfront.net`).

### 9.5 Publicar una nueva versión del frontend

```powershell
npm run build
aws s3 sync dist/frontend-andesstay/browser s3://andesstay-frontend-<algo-único> --delete
aws cloudfront create-invalidation --distribution-id <ID_DISTRIBUCION> --paths "/*"
```

(La invalidación también se crea en la consola: distribución → *Invalidations* → *Create* → `/*`.)

---

## 10. Frontend CSR — Opción B: AWS Amplify Hosting (la que ya teníamos)

Amplify también es CSR: compila el Angular y publica los archivos estáticos en su CDN.

- El repo `frontend-andesstay` trae **`amplify.yml`** (Node 22, `npm ci`, `npm run build` y la carpeta
  `dist/frontend-andesstay/browser`). Si la app de Amplify está conectada a GitHub, cada *push* a la rama
  `main` vuelve a publicar.
- Amplify → la app → *Hosting* → **Rewrites and redirects** → *Manage redirects* → *Open text editor*:

```json
[
  {
    "source": "</^[^.]+$|\\.(?!(css|gif|ico|jpg|js|png|txt|svg|woff|woff2|ttf|map|json|webp)$)([^.]+$)/>",
    "status": "200",
    "target": "/index.html",
    "condition": null
  }
]
```

  (Toda ruta que no sea un archivo `.js`, `.css`, imagen, etc. se reescribe a `index.html`.)
- La URL `https://main.d32i73fsq9ui1t.amplifyapp.com` ya está en Azure y en CORS.

---

## 11. Azure: agregar la URL del frontend

Como el frontend ahora usa **su propio origen** como `redirectUri` (`window.location.origin`), cada URL donde se
publique debe estar registrada en Azure:

Azure Portal → **Microsoft Entra ID** → *App registrations* → la app del **frontend (SPA)**
`bb7e20d0-d275-4c90-b5ec-99f072c756ce` → **Authentication** → plataforma **Single-page application** →
*Add URI*:

```
https://d1a2b3c4d5e6f7.cloudfront.net
```

(sin `/` ni ruta al final). Dejar también `http://localhost:4200` y `https://main.d32i73fsq9ui1t.amplifyapp.com`.
*Save*.

> Debe ser plataforma **Single-page application** (no *Web*): si no, Azure responde el error `AADSTS9002326`.
> Si la URL no está registrada, el error es `AADSTS50011` (redirect URI mismatch).
> No hay que cambiar nada más en Azure: los scopes, roles y el tenant siguen igual.

---

## 12. Agregar CloudFront a CORS (API Gateway y BFF)

1. **API Gateway** → *CORS* → *Configure* → agregar `https://d1a2b3c4d5e6f7.cloudfront.net` en
   *Access-Control-Allow-Origin* → *Save*.
2. **BFF** (ec2-apps): API Gateway le reenvía el header `Origin`, y Spring rechaza (403) los orígenes que no
   conoce, así que también hay que agregarlo:

```bash
cd ~/andesstay/infra-andesstay-messaging
nano .env
# CORS_ALLOWED_ORIGINS=http://localhost:4200,https://main.d32i73fsq9ui1t.amplifyapp.com,https://d1a2b3c4d5e6f7.cloudfront.net
docker compose -f apps/compose.yml --env-file .env up -d bff      # recrea el BFF con la variable nueva
```

---

## 13. Prueba de punta a punta

| # | Qué hacer | Qué se debe ver |
|---|---|---|
| 1 | Abrir `https://<cloudfront>` | Pantalla de login de AndesStay |
| 2 | Iniciar sesión | Redirección a Microsoft, vuelta al dashboard con el menú según el rol |
| 3 | Recargar (F5) en `/reservations` | La página carga igual (error pages de CloudFront) |
| 4 | Crear una reserva y confirmarla (OPERADOR/ADMIN) | Mensaje "Reserva confirmada. Enviaremos la confirmación al correo del huésped y prepararemos la habitación." |
| 5 | Consola RabbitMQ → *Queues* | `q.cmd.email`, `q.cmd.housekeeping` y `q.cmd.voucher` con 1 mensaje **Unacked** ~10 s y luego 0 |
| 6 | Kafka UI → *Topics* → `reservations.events` → *Messages* | El evento `reservation.confirmada` con **key = id de la reserva** |
| 7 | Frontend → *Reportería* | *Indicadores en tiempo real* se actualiza solo (cada 5 s): reservas, ocupación y última actividad. La partición/offset **no** se ve en la página: se revisa en Kafka UI (paso 6) |
| 8 | Frontend → *Auditoría* | Quién confirmó, con qué rol (Recepción / Administrador), cuándo y **desde qué IP** (tu IP pública) |
| 9 | Kafka UI → *Consumers* | Los 3 grupos con **lag 0** |
| 10 | `curl` del paso 8.5 | 401 sin token / 200 con token |

---

## 14. Actualizar después de un cambio

**Backend** (en ec2-apps), por ejemplo después de cambiar `ms-andesstay-report`:

```bash
cd ~/andesstay/ms-andesstay-report && git pull
cd ~/andesstay/infra-andesstay-messaging
docker compose -f apps/compose.yml --env-file .env up -d --build report
```

**Frontend**: paso 9.5 (S3 + CloudFront) o *push* a `main` (Amplify).

---

## 15. Apagar, encender y costos

- Apagar las 3 EC2 cuando no se usen (EC2 → *Instance state* → *Stop*). En Learner Lab se apagan solas
  al terminar la sesión.
- Al encenderlas, Docker parte solo y los contenedores vuelven a levantarse (`restart: unless-stopped`).
  Conviene encender primero **ec2-mq** y **ec2-kafka**, y después **ec2-apps**. Si algún microservicio
  quedó con error: `docker compose -f apps/compose.yml --env-file .env restart`.
- Los datos se guardan en volúmenes de Docker (colas, tópicos y bases H2). Para borrar todo: `down -v`.
- La Elastic IP, las EC2 encendidas y los discos tienen costo (en Learner Lab se descuenta del crédito).
  CloudFront, S3 y API Gateway casi no cuestan con el tráfico de una demo.
- Si **no** se usa Elastic IP y cambia la IP pública de ec2-apps, hay que actualizar la URL de las dos
  integraciones de API Gateway (paso 8.1).

---

## 16. Problemas comunes

| Síntoma | Causa probable | Solución |
|---|---|---|
| API Gateway responde `503 Service Unavailable` / `500` | El BFF está apagado, el puerto 8080 no está abierto o la IP de la integración está mal | `curl http://<IP>:8080/actuator/health`; revisar `sg-andesstay-apps` y la URL de la integración |
| Siempre `401 Unauthorized` aunque haya token | `iss` o `aud` no calzan con el authorizer | Decodificar el token en jwt.ms. `iss` debe ser `https://login.microsoftonline.com/<tenant>/v2.0`. Si sale `https://sts.windows.net/...` el token es v1: en Azure, app de la **API** → *Manifest* → `"requestedAccessTokenVersion": 2` |
| Error de CORS en la consola del navegador | Falta el origen en API Gateway o en `CORS_ALLOWED_ORIGINS` del BFF | Paso 12. El origen va exacto, con `https://` y sin `/` final |
| El *preflight* `OPTIONS` responde 401 | El authorizer se aplicó a OPTIONS | Revisar que CORS esté configurado (8.4); si sigue, crear la ruta `OPTIONS /api/{proxy+}` **sin** autorización con la integración `bff-api` |
| `403` / `AccessDenied` al recargar una ruta del frontend | Faltan las *custom error responses* | Paso 9.4 (403 y 404 → `/index.html` → 200) |
| Página en blanco y 404 de `main-XXXX.js` | Se subió la carpeta `browser` en vez de su contenido | Volver a subir el **contenido** de `browser/` a la raíz del bucket |
| `AADSTS50011` | La URL de CloudFront no está como redirect URI | Paso 11 |
| `AADSTS9002326` | La URI se registró como *Web* | Registrarla en la plataforma **Single-page application** |
| Los microservicios no conectan a RabbitMQ/Kafka | Security groups, IP privadas mal escritas o `KAFKA_ADVERTISED_HOST=localhost` | `nc -zv` (paso 7.2); en ec2-kafka el `.env` debe tener la IP **privada** de ec2-kafka |
| La compilación se corta con `exit code 137` | Falta de memoria | Swap (paso 4), compilar de a una imagen (paso 7.3) o usar t3.large |
| Un broker se reinicia solo | Falta de memoria en ec2-kafka | t3.large + swap |

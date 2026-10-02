# AndesStay Messaging Infrastructure

Infraestructura local de mensajería de AndesStay basada en RabbitMQ.

## Servicios

- RabbitMQ AMQP: localhost:5672
- RabbitMQ Management: http://localhost:15672

## Iniciar

docker compose up -d

## Detener

docker compose down

## Detener y eliminar datos

docker compose down -v
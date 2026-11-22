#!/bin/bash
# =====================================================================
# Crea los tópicos de AndesStay (solo si no existen).
# Lo ejecuta el contenedor "kafka-init" de kafka/compose.yml.
#
# Tópicos de negocio (los que pide la pauta: 3 particiones y 3 réplicas):
#
#   reservations.events  -> cada cambio de estado de una reserva.
#                           Lo produce ms-andesstay-reservations.
#                           Lo consumen ms-andesstay-report (KPIs) y
#                           ms-andesstay-audit (auditoría).
#                           cleanup.policy=delete, retención 7 días.
#
#   audit.timeline       -> historial quién / qué / cuándo / desde dónde.
#                           Lo produce ms-andesstay-audit.
#                           Lo consume ms-andesstay-report (actividad).
#                           cleanup.policy=compact,delete, retención 30 días.
#
# Dead Letter Topics (uno por consumidor, como pide el caso "*.DLT"):
#   reservations.events.audit.DLT, reservations.events.report.DLT,
#   audit.timeline.report.DLT   -> retención 14 días.
# =====================================================================
set -e

BOOTSTRAP="kafka-1:29092,kafka-2:29092,kafka-3:29092"

echo "Esperando a que el clúster Kafka responda..."
until kafka-topics --bootstrap-server "$BOOTSTRAP" --list > /dev/null 2>&1; do
  echo "  Kafka todavía no responde, reintento en 5 s"
  sleep 5
done

crear_topico() {
  local nombre="$1"
  shift
  echo "-> Creando tópico $nombre (si no existe)"
  kafka-topics --bootstrap-server "$BOOTSTRAP" \
    --create --if-not-exists \
    --topic "$nombre" \
    --partitions 3 \
    --replication-factor 3 \
    --config min.insync.replicas=2 \
    "$@"
}

# 7 días = 604800000 ms
crear_topico reservations.events \
  --config cleanup.policy=delete \
  --config retention.ms=604800000

# 30 días = 2592000000 ms. Durante los primeros 7 días (min.compaction.lag.ms)
# se guarda el historial completo; después la compactación deja solo el último
# evento de cada reserva (key = id de la reserva) y a los 30 días se borra.
crear_topico audit.timeline \
  --config cleanup.policy=compact,delete \
  --config retention.ms=2592000000 \
  --config min.compaction.lag.ms=604800000

# 14 días = 1209600000 ms
for dlt in reservations.events.audit.DLT reservations.events.report.DLT audit.timeline.report.DLT; do
  crear_topico "$dlt" \
    --config cleanup.policy=delete \
    --config retention.ms=1209600000
done

echo ""
echo "Tópicos del clúster:"
kafka-topics --bootstrap-server "$BOOTSTRAP" --list

echo ""
echo "Detalle (líder, réplicas e ISR de cada partición):"
kafka-topics --bootstrap-server "$BOOTSTRAP" --describe --topic reservations.events
kafka-topics --bootstrap-server "$BOOTSTRAP" --describe --topic audit.timeline

echo ""
echo "Listo: tópicos de AndesStay creados."

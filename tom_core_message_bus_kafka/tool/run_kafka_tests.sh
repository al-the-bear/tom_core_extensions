#!/usr/bin/env bash
# Runs the adapter's `kafka` suite (the bus's conformance suite, the bus relay
# publishing through Kafka, the refusals and the example) against a Kafka
# cluster behind a REST proxy, in containers: Redpanda as the cluster (one
# container serving the Kafka API) and Confluent REST Proxy in front of it.
# Starts both, waits for the proxy, runs `dart test --tags kafka`, removes
# them. A run in which every test skipped (the proxy never answered) is a
# failure, not a pass.
#
# Redpanda's own HTTP proxy is not used: it serves no consumer assignments,
# refuses `auto.offset.reset` `latest` and creates no topics, all three of
# which the adapter needs.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=tom-core-message-bus-kafka-test
NETWORK="$NAME-net"
PORT="${KAFKA_REST_TEST_PORT:-18092}"
BROKER_IMAGE="${REDPANDA_IMAGE:-redpandadata/redpanda:v24.2.7}"
PROXY_IMAGE="${KAFKA_REST_IMAGE:-confluentinc/cp-kafka-rest:7.7.1}"
cleanup() {
  docker rm -fv "$NAME-proxy" "$NAME-broker" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
cleanup
docker network create "$NETWORK" >/dev/null
trap cleanup EXIT
docker run -d --name "$NAME-broker" --network "$NETWORK" "$BROKER_IMAGE" \
  redpanda start --mode dev-container --smp 1 --memory 1G --overprovisioned \
  --kafka-addr 0.0.0.0:9092 --advertise-kafka-addr "$NAME-broker:9092" >/dev/null
docker run -d --name "$NAME-proxy" --network "$NETWORK" -p "127.0.0.1:$PORT:8082" \
  -e KAFKA_REST_BOOTSTRAP_SERVERS="$NAME-broker:9092" \
  -e KAFKA_REST_LISTENERS=http://0.0.0.0:8082 \
  -e KAFKA_REST_HOST_NAME=localhost \
  "$PROXY_IMAGE" >/dev/null
for _ in $(seq 1 90); do
  curl -sf "http://127.0.0.1:$PORT/v3/clusters" >/dev/null && break
  sleep 1
done
output="$(TOM_KAFKA_REST_TEST_URL="http://127.0.0.1:$PORT" dart test --tags kafka 2>&1)" || { printf '%s\n' "$output"; docker logs "$NAME-proxy" 2>&1 | tail -20; docker logs "$NAME-broker" 2>&1 | tail -20; exit 1; }
printf '%s\n' "$output"
if printf '%s' "$output" | grep -q 'All tests skipped'; then
  echo "Every kafka test skipped: the proxy never answered — treating as failure." >&2
  exit 1
fi

#!/usr/bin/env bash
# Runs the adapter's `azure` suite (the bus's conformance suite, the bus relay
# publishing through Service Bus, and the example) against the Azure Service
# Bus emulator in Docker (tool/emulator/docker-compose.yaml: the emulator and
# the SQL Edge database it keeps its state in): starts it, waits until it
# reports itself up, runs `dart test --tags azure`, removes it. A run in which
# every test skipped (the emulator never came up) is a failure, not a pass.
set -euo pipefail
cd "$(dirname "$0")/.."
export AZURE_SB_AMQP_PORT="${AZURE_SB_AMQP_PORT:-15672}"
export AZURE_SB_HTTP_PORT="${AZURE_SB_HTTP_PORT:-15300}"
COMPOSE=(docker compose -f tool/emulator/docker-compose.yaml)
"${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d >/dev/null
trap '"${COMPOSE[@]}" down -v >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 120); do
  "${COMPOSE[@]}" logs emulator 2>/dev/null | grep -q 'Emulator Service is Successfully Up' && break
  sleep 2
done
output="$(TOM_AZURE_SB_CONNECTION='Endpoint=sb://localhost;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;' \
  TOM_AZURE_SB_AMQP_PORT="$AZURE_SB_AMQP_PORT" TOM_AZURE_SB_HTTP_PORT="$AZURE_SB_HTTP_PORT" \
  dart test --tags azure 2>&1)" || { printf '%s\n' "$output"; "${COMPOSE[@]}" logs emulator 2>&1 | tail -20; exit 1; }
printf '%s\n' "$output"
if printf '%s' "$output" | grep -q 'All tests skipped'; then
  echo "Every azure test skipped: the emulator never came up — treating as failure." >&2
  exit 1
fi

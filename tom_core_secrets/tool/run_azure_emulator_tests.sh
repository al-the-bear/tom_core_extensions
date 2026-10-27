#!/usr/bin/env bash
# Runs the azure provider's emulator suite against Lowkey Vault, an Azure Key Vault
# emulator, in a container: starts it, waits for the vault, runs `dart test
# --tags emulator`, removes it. A run in which every emulator test skipped (the
# emulator never answered) is a failure, not a pass.
#
# Lowkey serves its vault under the host and port the request names, so the
# container listens on the same port the host maps — a mapped port that differs
# answers "Unable to find active vault". The image is built for x86-64 and starts in about
# a minute under emulation on Apple silicon.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=tom-core-secrets-azure-test
PORT="${AZURE_TEST_PORT:-18443}"
TOKEN_PORT="${AZURE_TEST_TOKEN_PORT:-18080}"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:$PORT" \
  -p "127.0.0.1:$TOKEN_PORT:8080" -e LOWKEY_ARGS="--server.port=$PORT" \
  nagyesta/lowkey-vault:7.3.127 >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 180); do
  code="$(curl -sk -o /dev/null -w '%{http_code}' \
    "https://localhost:$PORT/secrets/none?api-version=7.4" 2>/dev/null || true)"
  [ "$code" = "401" ] && break
  sleep 1
done
output="$(AZURE_TEST_VAULT="https://localhost:$PORT/" \
  AZURE_TEST_IDENTITY="http://localhost:$TOKEN_PORT/metadata/identity/oauth2/token" \
  dart test --tags emulator test/azure 2>&1)" || { printf '%s\n' "$output"; exit 1; }
printf '%s\n' "$output"
if printf '%s' "$output" | grep -q 'All tests skipped'; then
  echo "Every emulator test skipped: Lowkey Vault never answered — treating as failure." >&2
  exit 1
fi

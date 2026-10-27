#!/usr/bin/env bash
# Runs the vault provider's emulator suite against a HashiCorp Vault dev server in a
# container: starts it, waits for it, runs `dart test --tags emulator test/vault`, removes
# it. A run in which every emulator test skipped (the server never answered)
# is a failure, not a pass.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=tom-core-secrets-vault-test
PORT="${VAULT_TEST_PORT:-18200}"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:8200" --cap-add=IPC_LOCK \
  -e VAULT_DEV_ROOT_TOKEN_ID=root hashicorp/vault:1.17 >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 60); do
  curl -sf "http://127.0.0.1:$PORT/v1/sys/health" >/dev/null && break
  sleep 1
done
output="$(VAULT_TEST_ADDR="http://127.0.0.1:$PORT" dart test --tags emulator test/vault 2>&1)" || { printf '%s\n' "$output"; exit 1; }
printf '%s\n' "$output"
if printf '%s' "$output" | grep -q 'All tests skipped'; then
  echo "Every emulator test skipped: Vault never answered — treating as failure." >&2
  exit 1
fi

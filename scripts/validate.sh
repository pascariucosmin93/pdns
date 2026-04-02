#!/usr/bin/env sh
set -eu

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMPOSE_FILE="$PROJECT_ROOT/compose.yaml"
ZONE_FILE="$PROJECT_ROOT/zones/db.portfolio.test"

echo "Validating compose file..."
podman compose -f "$COMPOSE_FILE" config >/dev/null

echo "Validating DNS zone serial..."
if ! grep -Eq '\b20[0-9]{8}\b' "$ZONE_FILE"; then
  echo "Zone serial does not look like YYYYMMDDNN." >&2
  exit 1
fi

echo "Validation successful."


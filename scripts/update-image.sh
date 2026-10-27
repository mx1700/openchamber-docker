#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "[$(date -Is)] pulling OpenChamber image"
docker compose pull openchamber

echo "[$(date -Is)] starting/recreating OpenChamber"
docker compose up -d openchamber

echo "[$(date -Is)] waiting for health"
for _ in $(seq 1 60); do
  cid="$(docker compose ps -q openchamber || true)"
  if [ -n "$cid" ]; then
    status="$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo unknown)"
    if [ "$status" = "healthy" ]; then
      echo "[$(date -Is)] healthy"
      exit 0
    fi
  fi
  sleep 2
done

echo "[$(date -Is)] health check failed" >&2
docker compose logs --tail 100 openchamber >&2 || true
exit 1

#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: missing dependency: $cmd" >&2
    exit 2
  fi
}

require_cmd kubectl

NAMESPACE="${NAMESPACE:-production}"
CANARY_INGRESS="${CANARY_INGRESS:-demo-api-canary}"
SLEEP_BETWEEN_STEPS="${SLEEP_BETWEEN_STEPS:-30}"
STEPS="${STEPS:-5 25 50}"

echo "Progressive rollout via NGINX canary weights: ${STEPS}"

for weight in $STEPS; do
  echo "Setting canary weight to ${weight}%..."
  kubectl -n "$NAMESPACE" annotate "ingress/${CANARY_INGRESS}" \
    nginx.ingress.kubernetes.io/canary-weight="${weight}" \
    --overwrite

  if [ "$SLEEP_BETWEEN_STEPS" -gt 0 ]; then
    echo "Waiting ${SLEEP_BETWEEN_STEPS}s..."
    sleep "$SLEEP_BETWEEN_STEPS"
  fi
done

echo "Progressive rollout complete."


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
IMAGE="${IMAGE:-}"
CANARY_WEIGHT="${CANARY_WEIGHT:-5}"
CANARY_DEPLOYMENT="${CANARY_DEPLOYMENT:-app-canary}"
CANARY_INGRESS="${CANARY_INGRESS:-demo-api-canary}"

if [ -z "$IMAGE" ]; then
  echo "ERROR: IMAGE is required (example: 123456789.dkr.ecr.us-east-1.amazonaws.com/demo-api:sha)" >&2
  exit 2
fi

echo "Deploying canary image..."
kubectl -n "$NAMESPACE" set image "deployment/${CANARY_DEPLOYMENT}" app="$IMAGE" --record=true
kubectl -n "$NAMESPACE" rollout status "deployment/${CANARY_DEPLOYMENT}" --timeout=180s

echo "Setting canary ingress weight to ${CANARY_WEIGHT}%..."
kubectl -n "$NAMESPACE" annotate "ingress/${CANARY_INGRESS}" \
  nginx.ingress.kubernetes.io/canary-weight="${CANARY_WEIGHT}" \
  --overwrite

echo "Canary deployed."


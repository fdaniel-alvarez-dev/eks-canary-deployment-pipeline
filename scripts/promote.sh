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
PROD_DEPLOYMENT="${PROD_DEPLOYMENT:-app-production}"
CANARY_DEPLOYMENT="${CANARY_DEPLOYMENT:-app-canary}"
CANARY_INGRESS="${CANARY_INGRESS:-demo-api-canary}"
SCALE_DOWN_CANARY="${SCALE_DOWN_CANARY:-true}"

if [ -z "$IMAGE" ]; then
  echo "ERROR: IMAGE is required" >&2
  exit 2
fi

echo "Promoting image to production..."
kubectl -n "$NAMESPACE" set image "deployment/${PROD_DEPLOYMENT}" app="$IMAGE" --record=true
kubectl -n "$NAMESPACE" rollout status "deployment/${PROD_DEPLOYMENT}" --timeout=300s

echo "Disabling canary traffic..."
kubectl -n "$NAMESPACE" annotate "ingress/${CANARY_INGRESS}" \
  nginx.ingress.kubernetes.io/canary-weight="0" \
  --overwrite

if [ "$SCALE_DOWN_CANARY" = "true" ]; then
  echo "Scaling down canary deployment..."
  kubectl -n "$NAMESPACE" scale "deployment/${CANARY_DEPLOYMENT}" --replicas=0
fi

echo "Promotion complete."


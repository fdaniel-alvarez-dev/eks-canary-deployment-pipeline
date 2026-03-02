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
CANARY_DEPLOYMENT="${CANARY_DEPLOYMENT:-app-canary}"
PROD_DEPLOYMENT="${PROD_DEPLOYMENT:-app-production}"
CANARY_INGRESS="${CANARY_INGRESS:-demo-api-canary}"
ROLLBACK_PRODUCTION="${ROLLBACK_PRODUCTION:-false}"

echo "Disabling canary traffic..."
kubectl -n "$NAMESPACE" annotate "ingress/${CANARY_INGRESS}" \
  nginx.ingress.kubernetes.io/canary-weight="0" \
  --overwrite || true

echo "Rolling back canary deployment..."
kubectl -n "$NAMESPACE" rollout undo "deployment/${CANARY_DEPLOYMENT}" || true
kubectl -n "$NAMESPACE" rollout status "deployment/${CANARY_DEPLOYMENT}" --timeout=180s || true

if [ "$ROLLBACK_PRODUCTION" = "true" ]; then
  echo "Rolling back production deployment..."
  kubectl -n "$NAMESPACE" rollout undo "deployment/${PROD_DEPLOYMENT}" || true
  kubectl -n "$NAMESPACE" rollout status "deployment/${PROD_DEPLOYMENT}" --timeout=300s || true
fi

echo "Rollback complete."


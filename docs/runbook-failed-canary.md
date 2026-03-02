# Runbook: Failed canary

## Goal

Restore stable service quickly and capture enough context to debug safely.

## Immediate actions

1. Disable canary traffic:
   - `NAMESPACE=production scripts/rollback.sh`
2. Confirm traffic is stable:
   - Watch error rate and latency in Grafana/Prometheus.
3. Capture context:
   - `kubectl -n production describe deploy/app-canary`
   - `kubectl -n production logs deploy/app-canary --tail=200`

## Common causes

- Misconfigured environment variables
- Dependency timeouts or new external calls
- Resource limits too tight (CPU throttling)
- Mismatched metrics labels (Prometheus query returns no data)

## After-action checklist

- Update thresholds if needed (avoid false rollbacks)
- Add a regression test for the failure mode
- Document the decision in the PR / incident notes


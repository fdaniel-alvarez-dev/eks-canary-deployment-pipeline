# Tuning thresholds

The defaults in `scripts/canary-analysis.sh` are intentionally conservative.

## Recommended approach

- Start with a 5-minute analysis window.
- Use a 2-minute Prometheus rate window to reduce noise.
- Require 2 consecutive failures to rollback (avoids transient spikes).

## Typical tuning knobs

- `MAX_P95_LATENCY` (seconds)
- `MAX_ERROR_RATE` (fraction, e.g. `0.01` for 1%)
- `MAX_CPU_USAGE` (fraction, e.g. `0.80` for 80%)
- `CONSECUTIVE_FAILURES_THRESHOLD`


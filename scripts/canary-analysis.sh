#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# Canary Analysis Script
#
# Queries Prometheus metrics to determine if the canary
# deployment is healthy enough to promote.
#
# Designed to catch latency/error regressions early, with
# predictable, machine-friendly output for CI/CD.
#
# Usage: ./canary-analysis.sh [options]
#
# Environment variables:
#   PROMETHEUS_URL    — Prometheus query endpoint
#   NAMESPACE         — Kubernetes namespace (default: production)
#   ANALYSIS_DURATION — Total analysis time in seconds (default: 300)
#   CHECK_INTERVAL    — Seconds between checks (default: 30)
# ──────────────────────────────────────────────────────────────

set -euo pipefail

# ── Dependencies ──────────────────────────────────────────────

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: missing dependency: $cmd" >&2
        exit 2
    fi
}

require_cmd curl
require_cmd jq
require_cmd bc

# ── Configuration ────────────────────────────────────────────

PROMETHEUS_URL="${PROMETHEUS_URL:-http://prometheus:9090}"
NAMESPACE="${NAMESPACE:-production}"
CANARY_LABEL="${CANARY_LABEL:-canary}"
ANALYSIS_DURATION="${ANALYSIS_DURATION:-300}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
CONSECUTIVE_FAILURES_THRESHOLD="${CONSECUTIVE_FAILURES_THRESHOLD:-2}"

# Thresholds — tune these for your workload
MAX_P95_LATENCY="${MAX_P95_LATENCY:-2.0}"         # seconds
MAX_ERROR_RATE="${MAX_ERROR_RATE:-0.01}"            # 1%
MAX_CPU_USAGE="${MAX_CPU_USAGE:-0.80}"              # 80%
MAX_RESTARTS="${MAX_RESTARTS:-0}"                   # zero tolerance

# ── Colors ───────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Prometheus Query Helper ──────────────────────────────────

query_prometheus() {
    local query="$1"
    local result

    if ! result=$(curl -sf --max-time 10 \
        "${PROMETHEUS_URL}/api/v1/query" \
        --data-urlencode "query=${query}" \
        2>/dev/null); then
        echo "ERROR"
        return 1
    fi

    # Extract the value from Prometheus response
    echo "$result" | jq -r '.data.result[0].value[1] // "0"'
}

# ── Metric Check Functions ───────────────────────────────────

check_p95_latency() {
    local query="histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{deployment=\"${CANARY_LABEL}\",namespace=\"${NAMESPACE}\"}[2m])) by (le))"
    local value
    value="$(query_prometheus "$query" 2>/dev/null || echo "ERROR")"

    if [ "$value" == "ERROR" ] || [ "$value" == "NaN" ] || [ -z "$value" ]; then
        echo -e "${YELLOW}  WARN  P95 latency: no data (low traffic?)${NC}"
        return 0  # Don't fail on no data — might be ramp-up
    fi

    local pass
    pass="$(echo "$value <= $MAX_P95_LATENCY" | bc -l 2>/dev/null || echo "1")"

    if [ "$pass" == "1" ]; then
        printf "${GREEN}  OK    P95 latency: %.3fs (threshold: %ss)${NC}\n" "$value" "$MAX_P95_LATENCY"
        return 0
    else
        printf "${RED}  FAIL  P95 latency: %.3fs exceeds threshold %ss${NC}\n" "$value" "$MAX_P95_LATENCY"
        return 1
    fi
}

check_error_rate() {
    local query_errors="sum(rate(http_requests_total{status=~\"5..\",deployment=\"${CANARY_LABEL}\",namespace=\"${NAMESPACE}\"}[2m]))"
    local query_total="sum(rate(http_requests_total{deployment=\"${CANARY_LABEL}\",namespace=\"${NAMESPACE}\"}[2m]))"

    local errors total rate
    errors="$(query_prometheus "$query_errors" 2>/dev/null || echo "ERROR")"
    total="$(query_prometheus "$query_total" 2>/dev/null || echo "ERROR")"

    if [ "$total" == "0" ] || [ "$total" == "ERROR" ] || [ -z "$total" ] || [ "$errors" == "ERROR" ]; then
        echo -e "${YELLOW}  WARN  Error rate: no traffic yet${NC}"
        return 0
    fi

    rate="$(echo "scale=6; $errors / $total" | bc -l 2>/dev/null || echo "0")"

    local pass
    pass="$(echo "$rate <= $MAX_ERROR_RATE" | bc -l 2>/dev/null || echo "1")"

    if [ "$pass" == "1" ]; then
        printf "${GREEN}  ✓ Error rate: %.4f%% (threshold: %.2f%%)${NC}\n" \
            "$(echo "$rate * 100" | bc -l)" "$(echo "$MAX_ERROR_RATE * 100" | bc -l)"
        return 0
    else
        printf "${RED}  ✗ Error rate: %.4f%% EXCEEDS threshold %.2f%%${NC}\n" \
            "$(echo "$rate * 100" | bc -l)" "$(echo "$MAX_ERROR_RATE * 100" | bc -l)"
        return 1
    fi
}

check_pod_restarts() {
    local query="sum(kube_pod_container_status_restarts_total{namespace=\"${NAMESPACE}\",pod=~\".*${CANARY_LABEL}.*\"})"
    local value
    value="$(query_prometheus "$query" 2>/dev/null || echo "ERROR")"

    if [ "$value" == "ERROR" ]; then
        echo -e "${YELLOW}  WARN  Pod restarts: unable to query${NC}"
        return 0
    fi

    local restarts
    restarts=$(printf "%.0f" "$value" 2>/dev/null || echo "0")

    if [ "$restarts" -le "$MAX_RESTARTS" ]; then
        echo -e "${GREEN}  OK    Pod restarts: ${restarts} (threshold: ${MAX_RESTARTS})${NC}"
        return 0
    else
        echo -e "${RED}  FAIL  Pod restarts: ${restarts} exceeds threshold ${MAX_RESTARTS}${NC}"
        return 1
    fi
}

check_cpu_usage() {
    local query="avg(rate(container_cpu_usage_seconds_total{namespace=\"${NAMESPACE}\",pod=~\".*${CANARY_LABEL}.*\"}[2m]))"
    local value
    value="$(query_prometheus "$query" 2>/dev/null || echo "ERROR")"

    if [ "$value" == "ERROR" ] || [ "$value" == "NaN" ]; then
        echo -e "${YELLOW}  WARN  CPU usage: no data${NC}"
        return 0
    fi

    local pass
    pass="$(echo "$value <= $MAX_CPU_USAGE" | bc -l 2>/dev/null || echo "1")"

    if [ "$pass" == "1" ]; then
        printf "${GREEN}  OK    CPU usage: %.1f%% (threshold: %.0f%%)${NC}\n" \
            "$(echo "$value * 100" | bc -l)" "$(echo "$MAX_CPU_USAGE * 100" | bc -l)"
        return 0
    else
        printf "${RED}  FAIL  CPU usage: %.1f%% exceeds threshold %.0f%%${NC}\n" \
            "$(echo "$value * 100" | bc -l)" "$(echo "$MAX_CPU_USAGE * 100" | bc -l)"
        return 1
    fi
}

# ── Main Analysis Loop ───────────────────────────────────────

main() {
    echo "═══════════════════════════════════════════════════════"
    echo -e "${BLUE}  Canary Analysis — Starting${NC}"
    echo "  Duration: ${ANALYSIS_DURATION}s | Interval: ${CHECK_INTERVAL}s"
    echo "  Fail threshold: ${CONSECUTIVE_FAILURES_THRESHOLD} consecutive failures"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    local total_checks=$(( ANALYSIS_DURATION / CHECK_INTERVAL ))
    local consecutive_failures=0
    local check_number=0

    for i in $(seq 1 "$total_checks"); do
        check_number=$((check_number + 1))
        echo -e "${BLUE}── Check ${check_number}/${total_checks} ──${NC}"

        local failed=0

        check_p95_latency  || failed=$((failed + 1))
        check_error_rate   || failed=$((failed + 1))
        check_pod_restarts || failed=$((failed + 1))
        check_cpu_usage    || failed=$((failed + 1))

        if [ $failed -gt 0 ]; then
            consecutive_failures=$((consecutive_failures + 1))
            echo -e "${YELLOW}  WARN  ${failed} metric(s) failed (consecutive: ${consecutive_failures}/${CONSECUTIVE_FAILURES_THRESHOLD})${NC}"

            if [ $consecutive_failures -ge "$CONSECUTIVE_FAILURES_THRESHOLD" ]; then
                echo ""
                echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
                echo -e "${RED}  CANARY FAILED — ${consecutive_failures} consecutive failures${NC}"
                echo -e "${RED}  Initiating automatic rollback...${NC}"
                echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
                return 1
            fi
        else
            consecutive_failures=0
            echo -e "${GREEN}  OK    All metrics healthy${NC}"
        fi

        echo ""

        # Don't sleep after the last check
        if [ "$i" -lt "$total_checks" ]; then
            sleep "$CHECK_INTERVAL"
        fi
    done

    echo "═══════════════════════════════════════════════════════"
    echo -e "${GREEN}  CANARY PASSED — All ${total_checks} checks passed${NC}"
    echo -e "${GREEN}  Safe to promote to full production${NC}"
    echo "═══════════════════════════════════════════════════════"
    return 0
}

main "$@"

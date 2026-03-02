# eks-canary-deployment-pipeline

**Automated canary deployments on EKS with metric-based promotion and fast rollback — built to be practical, readable, and CI-friendly.**

![GitHub Actions](https://img.shields.io/badge/CI/CD-GitHub_Actions-blue?logo=githubactions)
![Kubernetes](https://img.shields.io/badge/Deploy-EKS_Canary-blue?logo=kubernetes)
![Grafana](https://img.shields.io/badge/Metrics-Prometheus+Grafana-orange?logo=grafana)

---

## The deployment that taught me canary

Two years ago, we pushed a "minor" config change to a production API serving real-time financial transactions. The change was tested, code-reviewed, and approved. It also introduced a 300ms latency regression that only manifested under load patterns we didn't test for.

By the time our threshold-based alerts fired, the change had been live for 47 minutes, affecting 100% of traffic. Rolling back took another 8 minutes. Total impact: 55 minutes of degraded experience for every user.

Had we deployed to 5% of traffic first and watched the P95 for 5 minutes, we'd have caught it in under 6 minutes with zero user impact.

That's what this pipeline does. Every deployment goes through a canary phase with automated metric analysis. If the metrics look bad, rollback happens before humans even notice.

## How it works

```
┌─────────┐     ┌─────────┐     ┌───────────┐     ┌────────────┐
│  Build   │────►│ Deploy  │────►│  Analyze   │────►│  Promote   │
│  & Test  │     │ Canary  │     │  Metrics   │     │  or        │
│          │     │ (5%)    │     │  (5 min)   │     │  Rollback  │
└─────────┘     └─────────┘     └───────────┘     └────────────┘
                     │                │
                     │           ┌────▼─────┐
                     │           │ SLO Check │
                     │           │ P95 < 2s  │
                     │           │ Err < 1%  │
                     │           │ CPU < 80% │
                     │           └────┬──────┘
                     │                │
                     │          FAIL? │
                     │◄───────────────┘
                     │
                 Auto Rollback
```

### The 4-phase deployment

**Phase 1 — Build & Test** (2-3 min)
Run tests, build the container, and push to ECR. Add an image scan step if your org requires it.

**Phase 2 — Canary Deploy** (1 min)
Deploy new version to canary Deployment (5% traffic via weighted Ingress rules). Old version stays untouched.

**Phase 3 — Metric Analysis** (5 min)
Query Prometheus every 30 seconds. Check:
- P95 latency < threshold (default 2s)
- Error rate < threshold (default 1%)
- Pod restart count = 0
- CPU usage < 80%

If ANY check fails twice consecutively → automatic rollback.

**Phase 4 — Progressive Promotion** (3 min)
If canary passes: 5% → 25% → 50% → 100%, with 30-second health checks between each step.

## Project structure

```
.
├── .github/workflows/
│   └── canary-deploy.yml          # CI/CD pipeline (build, canary, analyze, promote)
├── k8s/
│   ├── base/
│   │   ├── deployment-production.yaml
│   │   ├── deployment-canary.yaml
│   │   ├── service.yaml
│   │   ├── ingress-stable.yaml
│   │   ├── ingress-canary.yaml
│   │   ├── hpa.yaml
│   │   ├── pdb.yaml
│   │   ├── serviceaccount.yaml
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── staging/
│       └── production/
├── scripts/
│   ├── canary-analysis.sh         # Metric-based canary verification (Prometheus)
│   ├── deploy-canary.sh           # Update canary deployment image + weight
│   ├── progressive-rollout.sh     # Gradual traffic shift (NGINX canary weight)
│   ├── promote.sh                 # Promote image to stable + disable canary traffic
│   └── rollback.sh                # Disable canary traffic + rollback canary
├── monitoring/
│   ├── prometheus-rules.yaml      # Example SLO alert
│   ├── canary-alerts.yaml         # Canary-specific alert examples
│   └── grafana-dashboard.json     # Minimal dashboard stub
├── app/
│   ├── Dockerfile
│   ├── main.py                    # Sample FastAPI app with /metrics
│   └── requirements.txt
└── docs/
    ├── runbook-failed-canary.md
    └── tuning-thresholds.md
```

## Quick start

### 1. Configure

```bash
# GitHub Secrets needed:
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_REGION
EKS_CLUSTER_NAME
ECR_REPOSITORY
PROMETHEUS_URL           # Your Prometheus endpoint
```

### 2. Deploy infrastructure

```bash
# Apply K8s resources (Kustomize overlay)
kubectl apply -k k8s/overlays/production/

# Verify
kubectl get deployments -n production
```

### 3. Push code

```bash
git push origin main
# Pipeline triggers automatically
```

## Canary analysis in detail

The `scripts/canary-analysis.sh` script is the brain of the operation. Here's what it actually queries:

```bash
# P95 Latency — the metric that matters most
histogram_quantile(0.95,
  rate(http_request_duration_seconds_bucket{
    deployment="canary"
  }[2m])
)

# Error rate — 5xx responses as a percentage
sum(rate(http_requests_total{status=~"5..",deployment="canary"}[2m]))
/
sum(rate(http_requests_total{deployment="canary"}[2m]))

# Pod health — restarts indicate crashloops
kube_pod_container_status_restarts_total{
  namespace="production",
  pod=~".*canary.*"
}
```

These queries come from real production monitoring. The 2-minute rate window is intentional — it's long enough to smooth out noise but short enough to catch real regressions.

## Notes

- Traffic splitting is implemented using the NGINX Ingress Controller canary annotations (`nginx.ingress.kubernetes.io/canary-weight`). If you're using ALB or another controller, adjust the ingress manifests and the rollout scripts accordingly.

## Tuning for your workload

The default thresholds work for most API workloads, but you should tune them:

| Metric | Default | When to adjust |
|--------|---------|---------------|
| P95 latency | < 2s | Lower for real-time APIs, higher for batch |
| Error rate | < 1% | Lower for financial systems, higher for best-effort |
| Analysis duration | 5 min | Longer for low-traffic services |
| Check interval | 30s | More frequent for high-traffic, less for low |
| Consecutive failures | 2 | Increase to reduce false rollbacks |

## What I learned building this

1. **Don't trust averages.** P50 can look fine while P95 is on fire. Always check percentiles.

2. **Traffic volume matters.** Canary analysis is unreliable with < 100 requests during the analysis window. For low-traffic services, use longer analysis windows.

3. **Rollback should be boring.** If your rollback process is complex, it'll fail when you need it most. Ours is one `kubectl rollout undo` command.

4. **Start with 5%.** I've seen teams jump to 25% or 50% canary splits. The whole point is minimizing blast radius.

## Author

**Freddy Alvarez** — I've deployed to production thousands of times over 22 years. The ones that went wrong taught me more than the ones that went right.

- [LinkedIn](https://linkedin.com/in/falvarezpinto)
- [Medium](https://medium.com/@falvarezpinto)
- [Related repos](https://github.com/fdaniel-alvarez-dev)

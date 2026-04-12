---
name: k8s-diagnostics
description: >
  Kubernetes cluster diagnostic skill. Use this whenever a user asks to
  diagnose, investigate, audit, or troubleshoot a Kubernetes cluster or
  namespace, including pod failures, node pressure, PVC issues, networking
  problems, event analysis, or "what is wrong with my cluster". Always invoke
  the local wrapper script, never the installed binary directly.
---

# Kubernetes Diagnostics Skill

This skill runs the local source tree through
`./k8sdiag-run.sh`, which in turn calls `go run ./cmd/k8sdiag`.

## Rules

- Always run the script at `./k8sdiag-run.sh`.
- Never call `k8sdiag` directly.
- Prefer sectioned runs when the user wants a detailed report, when the cluster
  is large, or when token limits are a concern.
- After each section, summarize only that section and keep accumulating the
  report.

## Inputs To Extract

- `cluster_name` (required)
- `namespace` (optional)
- `kubeconfig` (optional)
- `context` (optional)
- `report_path` (optional; otherwise use `/tmp/k8sdiag-<cluster>-report.md`)

If `cluster_name` is missing, ask for it.

## Default Run Modes

### Fast interactive scan

```bash
./k8sdiag-run.sh \
  --cluster "<cluster_name>" \
  --namespace "<namespace>" \
  --output text
```

### Structured single-shot report

```bash
./k8sdiag-run.sh \
  --cluster "<cluster_name>" \
  --namespace "<namespace>" \
  --output markdown \
  --report-file "/tmp/k8sdiag-<cluster>-report.md"
```

### Incremental sectioned report

Run these sections one at a time, in this order:

1. `pods`
2. `nodes`
3. `storage`
4. `network`
5. `affinity`
6. `events`
7. `resources`

First section:

```bash
./k8sdiag-run.sh \
  --cluster "<cluster_name>" \
  --namespace "<namespace>" \
  --section pods \
  --output markdown \
  --report-file "/tmp/k8sdiag-<cluster>-report.md" \
  --report-title "k8sdiag report for <cluster_name>"
```

Subsequent sections:

```bash
./k8sdiag-run.sh \
  --cluster "<cluster_name>" \
  --namespace "<namespace>" \
  --section nodes \
  --output markdown \
  --report-file "/tmp/k8sdiag-<cluster>-report.md" \
  --append-report
```

Repeat with `storage`, `network`, `affinity`, `events`, and `resources`.

## Section Mapping

- `pods` → pod lifecycle and container health
- `nodes` → node readiness, pressure, capacity, control plane
- `storage` → PVC, PV, StorageClass, mounts
- `network` → services, endpoints, policies, Calico, DNS
- `affinity` → selectors, affinity, taints, topology spread
- `events` → warning event analysis
- `resources` → quotas, HPA, RBAC, ConfigMaps, Secrets, Ingress, Namespace

## Response Pattern

After each section:

1. State the section name.
2. Summarize critical findings first, then warnings, then info.
3. Mention that the report has been appended to the report file.
4. Continue with the next section if more sections remain.

After the last section:

1. Present an overall summary across all sections.
2. Mention the final report path.
3. If the user wants follow-up, offer the next most relevant drill-down:
   logs, events, PVC status, node remediation, or RBAC review.

## Exit Codes

- `0` = no findings
- `1` = warnings only
- `2` = critical findings present

Treat `1` and `2` as successful diagnostic runs, not command failures.

## Error Handling

- `cannot resolve cluster context`: suggest `kubectl config get-contexts`
- `failed to connect`: suggest checking auth, network reachability, and kubeconfig
- `context deadline exceeded`: switch to sectioned mode or a narrower namespace
- `permission denied`: explain the tool needs `get/list` access on cluster resources

## Coverage Reference

Use `./coverage.md` when the user asks whether the tool covers a specific area.

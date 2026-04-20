# EKS Pod Debugging Reference

## CrashLoop Runbook

### Step 1 — Get the real error
```bash
# Current logs (if container is up briefly)
kubectl logs <POD> -n <NS> --previous

# Multi-container pod
kubectl logs <POD> -n <NS> -c <CONTAINER> --previous

# Describe for events + last state
kubectl describe pod <POD> -n <NS>
```
In `describe`, look for:
- `Last State: Terminated` → `Exit Code` and `Reason`
- `Exit Code 1` = app error, `137` = OOMKilled, `139` = segfault, `143` = SIGTERM, `126/127` = command not found

### Step 2 — Exit code guide

| Code | Meaning | Action |
|------|---------|--------|
| 1 | App crash / unhandled exception | Check app logs |
| 137 | OOMKilled (SIGKILL) | Increase memory limit, check for leak |
| 139 | Segfault | App or native lib bug |
| 143 | SIGTERM (graceful shutdown) | Crash on startup + gracefulTermination misconfiguration |
| 126 | Permission denied on entrypoint | Check security context / file permissions |
| 127 | Entrypoint not found | Wrong CMD or missing binary in image |

### Step 3 — Debug with ephemeral container
```bash
kubectl debug -it <POD> -n <NS> \
  --image=nicolaka/netshoot \
  --target=<CONTAINER>
```

---

## Pending / Unschedulable Runbook

```bash
kubectl describe pod <POD> -n <NS> | grep -A 20 "Events:"
```

### "Insufficient cpu/memory"
- Resources requested exceed node capacity or available headroom
- Karpenter should provision a new node within ~30s — if not, check Karpenter logs
- Check actual node allocatable: `kubectl describe node | grep -A 5 "Allocatable"`

### "0/N nodes are available: N node(s) had untolerated taint"
```bash
kubectl get nodes -o json | jq '.items[].spec.taints'
# Compare with pod's tolerations
kubectl get pod <POD> -n <NS> -o json | jq '.spec.tolerations'
```

### "0/N nodes are available: N Insufficient pods"
- Node hit max pod limit (`--max-pods` kubelet flag or ENI-based limit for VPC CNI)
- With VPC CNI: `max_pods = (ENIs × (IPs_per_ENI - 1)) + 2`
- Enable prefix delegation to increase pod density:
  ```bash
  kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true
  ```

### "did not match pod's node affinity/selector"
```bash
kubectl get pod <POD> -n <NS> -o json | jq '.spec.nodeSelector, .spec.affinity'
kubectl get nodes --show-labels
```

### Topology spread constraint violations
```bash
kubectl get pod <POD> -n <NS> -o json | jq '.spec.topologySpreadConstraints'
# Check AZ distribution of existing replicas
kubectl get pods -n <NS> -o wide
```

---

## OOMKilled Runbook

### Confirm OOM
```bash
kubectl describe pod <POD> -n <NS> | grep -A 5 "OOM\|Last State"
# On the node:
sudo dmesg | grep -i "oom_kill\|out of memory" | tail -10
```

### Right-size memory
```bash
# Check actual usage vs limits
kubectl top pod <POD> -n <NS> --containers

# Get VPA recommendation (if VPA installed)
kubectl get vpa -n <NS> <VPA_NAME> -o json | jq '.status.recommendation'
```

### Temporary fix — increase limit
```bash
kubectl patch deployment <DEPLOY> -n <NS> \
  --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"2Gi"}]'
```

### Java-specific OOM
- JVM may not see cgroup memory limits: add `-XX:+UseContainerSupport` (JDK 11+, automatic)
- For JDK 8u191+: `-XX:MaxRAMPercentage=75.0`

---

## Image Pull Errors

```bash
kubectl describe pod <POD> -n <NS> | grep -A 10 "Failed\|Back-off pulling"
```

### `ImagePullBackOff` causes:
1. **Private ECR** — node IAM role missing `ecr:GetAuthorizationToken` or IRSA for cross-account ECR
   ```bash
   # Test from node via SSM
   aws ecr get-login-password --region <REGION> | \
     docker login --username AWS --password-stdin <ACCOUNT>.dkr.ecr.<REGION>.amazonaws.com
   ```
2. **Wrong registry URL or tag** — check for typos in image field
3. **ECR lifecycle policy deleted image** — verify image exists: `aws ecr describe-images`
4. **Private registry without imagePullSecret** — create and reference secret
5. **Rate limiting (Docker Hub)** — use authenticated pull or ECR mirror

---

## Init Container Stuck / Failing

```bash
kubectl describe pod <POD> -n <NS>  # shows init container status
kubectl logs <POD> -n <NS> -c <INIT_CONTAINER_NAME>
```

Common patterns:
- DB migration init waiting on DB not yet ready → check DB service + network policy
- Init container doing `aws s3 cp` → IRSA not configured for init containers (same service account)
- Init ordering: `initContainers` run sequentially, not in parallel

---

## Readiness / Liveness Probe Failures

```bash
kubectl describe pod <POD> -n <NS> | grep -A 5 "Liveness\|Readiness\|Startup"
```

- **Connection refused**: app not listening on declared port — check app config
- **Timeout too short**: increase `timeoutSeconds` and `initialDelaySeconds`
- **HTTP 4xx**: probe path returns non-2xx — check probe httpGet path
- With Istio: probes may fail if sidecar starts before app — use `startupProbe` with large `failureThreshold`, or enable `holdApplicationUntilProxyStarts: true` in mesh config

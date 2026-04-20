# Add-ons, Helm & GitOps Debugging Reference

## EKS Managed Add-ons

```bash
# List installed add-ons and status
aws eks list-addons --cluster-name <CLUSTER>
aws eks describe-addon --cluster-name <CLUSTER> --addon-name <NAME> \
  --query 'addon.{status:status,addonVersion:addonVersion,health:health}'

# Update an add-on
aws eks update-addon \
  --cluster-name <CLUSTER> \
  --addon-name <NAME> \
  --addon-version <VERSION> \
  --resolve-conflicts OVERWRITE
```

### Add-on in DEGRADED status
```bash
aws eks describe-addon --cluster-name <CLUSTER> --addon-name <NAME> \
  --query 'addon.health.issues'
# Returns specific error codes and messages
```

Common add-on health issues:
- `ConfigurationConflict` — your custom config conflicts with add-on managed config. Use `--resolve-conflicts OVERWRITE` or `PRESERVE`
- `AdmissionRequestDenied` — OPA/Gatekeeper or Kyverno policy blocking add-on pods
- `InsufficientNumberOfReplicas` — add-on pods crashing, check pod logs

---

## Helm Debugging

```bash
# List all releases
helm list -A

# Check release status
helm status <RELEASE> -n <NS>
helm history <RELEASE> -n <NS>

# Render manifests locally (dry run)
helm template <RELEASE> <CHART> -f values.yaml

# Diff before upgrade (requires helm-diff plugin)
helm diff upgrade <RELEASE> <CHART> -f values.yaml -n <NS>
```

### Helm release stuck in "pending-upgrade" or "failed"
```bash
# Check what failed
helm history <RELEASE> -n <NS>  # find the failed revision number
helm get notes <RELEASE> -n <NS>

# Rollback to previous good version
helm rollback <RELEASE> <REVISION> -n <NS>

# Nuke a stuck release (last resort)
kubectl delete secret -n <NS> -l "owner=helm,name=<RELEASE>"
```

### OOM on Helm install (huge chart)
```bash
helm install <RELEASE> <CHART> --atomic --timeout 10m --debug
```

---

## ArgoCD Debugging

```bash
# Application status
kubectl get applications -n argocd
kubectl describe application <APP> -n argocd

# Sync manually
argocd app sync <APP> --prune

# Get sync error details
argocd app get <APP> -o json | jq '.status.conditions'
argocd app logs <APP>
```

### "OutOfSync" but nothing changed
- Timestamp fields or generated values differ each render (e.g., Helm `randAlphaNum`, `now`)
- Resource tracked in wrong namespace
- ArgoCD ignoring: use `ignoreDifferences` in Application spec:
  ```yaml
  spec:
    ignoreDifferences:
      - group: apps
        kind: Deployment
        jsonPointers:
          - /spec/replicas  # if HPA manages this
  ```

### ArgoCD image updater not updating
```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater --tail=50
# Check write-back method: git or argocd
# Verify registry access (IRSA or secret for ECR)
```

### App stuck "Progressing"
- Usually a pod rollout that can't complete (CrashLoop, OOM, pending)
- `kubectl get rollout <n> -n <NS>` if using Argo Rollouts
- Check `kubectl get events -n <NS> --sort-by=.lastTimestamp | tail -20`

---

## Flux Debugging

```bash
# Check Flux components
kubectl get pods -n flux-system
flux get all -A

# Reconcile manually
flux reconcile kustomization <n> -n flux-system
flux reconcile source git <n> -n flux-system

# Check events
flux events -n flux-system

# Trace a failing kustomization
kubectl describe kustomization <n> -n flux-system | grep -A 20 "Conditions"
```

### Flux reconciliation drift detection
```bash
flux get kustomizations -A
# Status "False" with reason shows what drifted
```

---

## Version Compatibility

Always check add-on compatibility when upgrading EKS:
- **EKS upgrade path**: only one minor version at a time (1.28 → 1.29, not 1.27 → 1.29)
- Check: https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
- Verify Karpenter, ALB controller, and VPC CNI are compatible with new EKS version

```bash
# Check current versions
kubectl version --short
aws eks describe-cluster --name <CLUSTER> --query 'cluster.version'
```

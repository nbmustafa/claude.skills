# Autoscaling Debugging Reference

## Karpenter

### Quick health check
```bash
kubectl get pods -n karpenter
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100 | grep -E "ERROR|WARN|provisioned|disrupted"

# NodePool and NodeClass status
kubectl get nodepools
kubectl get ec2nodeclasses  # or AWSNodeTemplates for older Karpenter
kubectl describe nodepool <NAME>
```

### Karpenter not provisioning nodes

**Step 1 — Check for pending pods**
```bash
kubectl get pods -A --field-selector=status.phase=Pending
kubectl describe pod <PENDING_POD> | grep -A 15 "Events:"
```

**Step 2 — Karpenter decision logs**
```bash
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter \
  | grep -E "provisioning|scheduling|launch|failed" | tail -30
```

**Step 3 — Common causes**

| Issue | Check | Fix |
|-------|-------|-----|
| NodePool limits reached | `kubectl describe nodepool` → `Resources` limits | Raise `limits` in NodePool spec |
| No matching instance type | Pod requests exceed all available types | Relax resource requests or expand instance families |
| AZ subnet missing | EC2NodeClass subnets not in pod's AZ | Add subnet tags or AZ in NodeClass |
| IAM role missing | Karpenter controller role lacks EC2 perms | Check IRSA on karpenter SA, verify policy |
| Spot capacity dry | No capacity in AZ | Add more instance families/sizes to NodePool |
| Launch template error | Security group or AMI misconfiguration | `aws ec2 describe-launch-template-versions` |

### Karpenter disruption (drift, consolidation)
```bash
# See disruption decisions
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | grep -i "disrupt\|consolidat\|drift"

# Annotate node to block disruption temporarily
kubectl annotate node <NODE> karpenter.sh/do-not-disrupt=true

# Remove annotation when ready
kubectl annotate node <NODE> karpenter.sh/do-not-disrupt-
```

### Karpenter version-specific notes
- v0.33+: `NodePool` + `EC2NodeClass` (replaces `Provisioner` + `AWSNodeTemplate`)
- Check CRD version: `kubectl get crd nodepools.karpenter.sh -o json | jq '.spec.versions[].name'`

---

## Cluster Autoscaler (CA)

```bash
kubectl get pods -n kube-system -l app=cluster-autoscaler
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=100 | \
  grep -E "scale up|scale down|error|failed|expanded"
```

### CA not scaling up
1. **Check annotations on ASG**: CA requires `k8s.io/cluster-autoscaler/<CLUSTER>=owned` and `k8s.io/cluster-autoscaler/enabled=true`
2. **CA not aware of pod**: pod might have `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` blocking scale-down and indirectly confusing scale-up
3. **cooldown period**: scale-up cooldown default 10m — check `--scale-up-stabilization-window`
4. **Resource limits**: MNG min/max size — verify in AWS console

```bash
# Check CA configmap / deployment flags
kubectl describe deployment cluster-autoscaler -n kube-system | grep -A 30 "Args:"
```

### CA not scaling down
```bash
# Nodes with "safe-to-evict: false" pods block scale-down
kubectl get pods -A -o json | jq -r \
  '.items[] | select(.metadata.annotations."cluster-autoscaler.kubernetes.io/safe-to-evict"=="false") | .metadata.name'
```

---

## HPA (Horizontal Pod Autoscaler)

```bash
kubectl get hpa -n <NS>
kubectl describe hpa <HPA_NAME> -n <NS>
```

### HPA not scaling

**"unknown" metrics**
```bash
# Metrics server must be running
kubectl get deployment metrics-server -n kube-system
kubectl top pods -n <NS>  # test it works

# For custom metrics (Prometheus Adapter)
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" | jq '.resources[].name'
```

**Scale-up blocked by PDB**
```bash
kubectl get pdb -n <NS>
# If minAvailable == current replicas, no room to scale down during rolling update
```

**HPA + VPA conflict**: Don't use both on the same deployment for CPU/memory. Use VPA for resources, HPA for custom metrics only.

---

## KEDA (Kubernetes Event-driven Autoscaling)

```bash
kubectl get scaledobjects -n <NS>
kubectl describe scaledobject <NAME> -n <NS>
kubectl get pods -n keda  # KEDA operator
kubectl logs -n keda -l app=keda-operator --tail=50
```

Check `ScaledObject` conditions for auth or metric source issues.

---

## VPA (Vertical Pod Autoscaler)

```bash
kubectl get vpa -n <NS>
kubectl describe vpa <NAME> -n <NS>
# Look at status.recommendation for suggested values
```

VPA modes: `Off` (recommend only), `Initial` (set on pod create), `Auto` (evict and recreate).

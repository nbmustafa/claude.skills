# Cost Debugging Reference

## Unexpected Cost Spikes

### Step 1 — Identify the spike source
```bash
# AWS Cost Explorer: filter by service (EC2, EBS, NAT Gateway, data transfer)
aws ce get-cost-and-usage \
  --time-period Start=2024-01-01,End=2024-01-31 \
  --granularity DAILY \
  --metrics BlendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[*].Groups[*].{Service:Keys[0],Cost:Metrics.BlendedCost.Amount}' \
  | sort
```

### Common EKS cost culprits

| Culprit | Detection | Fix |
|---------|-----------|-----|
| Over-provisioned nodes | `kubectl top nodes` — low utilization | Right-size node type, enable CA/Karpenter consolidation |
| Karpenter not consolidating | Check `consolidationPolicy` in NodePool | Set `consolidationPolicy: WhenUnderutilized` |
| Unused EBS volumes | `aws ec2 describe-volumes --filters Name=status,Values=available` | Delete orphaned PVs/PVCs |
| NAT Gateway data transfer | Large cross-AZ pod traffic | Enable VPC CNI AZ-aware routing, use PrivateLink for AWS services |
| On-Demand instead of Spot | Karpenter NodePool lacks Spot | Add `capacity-type: spot` to NodePool requirements |
| Idle load balancers | `aws elbv2 describe-load-balancers` | Delete unused Services/Ingresses |

### Node right-sizing
```bash
# Find oversized nodes
kubectl top nodes
# Compare to actual request totals per node:
kubectl describe nodes | grep -A 5 "Allocated resources"

# VPA recommendations across all namespaces
kubectl get vpa -A -o json | \
  jq '.items[] | {name:.metadata.name, ns:.metadata.namespace, recommendation:.status.recommendation.containerRecommendations}'
```

### Spot strategy (Karpenter)
```yaml
spec:
  requirements:
    - key: karpenter.sh/capacity-type
      operator: In
      values: ["spot", "on-demand"]  # Prefers spot, falls back to on-demand
    - key: kubernetes.io/arch
      operator: In
      values: ["amd64", "arm64"]  # Graviton (arm64) is ~20% cheaper
    - key: node.kubernetes.io/instance-type
      operator: In
      values: ["m5.large", "m5a.large", "m6i.large", "m6a.large", "m7i.large"]
      # Diversify instance families to improve spot availability
```

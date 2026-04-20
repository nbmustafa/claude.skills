# EKS Networking Debugging Reference

## VPC CNI (aws-node) Issues

```bash
# Check CNI version and health
kubectl get ds aws-node -n kube-system
kubectl describe ds aws-node -n kube-system
kubectl logs -n kube-system -l k8s-app=aws-node --tail=50

# Current IPAMD state
kubectl exec -n kube-system -it <AWS_NODE_POD> -- /app/grpc-health-probe -addr=:11191

# ENI/IP allocation debug
kubectl set env daemonset aws-node -n kube-system AWS_VPC_K8S_CNI_LOGLEVEL=DEBUG
```

## IP Address Exhaustion

### Diagnose
```bash
# Node IP pool status
kubectl describe node <NODE> | grep -A 20 "Capacity\|Allocatable"

# Check IPAMD metrics
kubectl exec -n kube-system <AWS_NODE_POD> -- \
  curl -s localhost:61679/metrics | grep eni_assigned
```

### Fixes — pick one:

**1. Prefix delegation** (recommended, big density boost)
```bash
kubectl set env daemonset aws-node -n kube-system \
  ENABLE_PREFIX_DELEGATION=true \
  WARM_PREFIX_TARGET=1
# Recycle nodes after this change
```

**2. Custom Networking** (pods on separate CIDR)
```bash
# Requires ENIConfig CRDs per AZ
kubectl set env daemonset aws-node -n kube-system AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true
```

**3. Expand VPC CIDR** — Add secondary CIDR in VPC console, create subnets, tag them.

---

## CoreDNS Debugging

### Quick check
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50

# DNS resolution test from a debug pod
kubectl run -it --rm dnstest --image=nicolaka/netshoot --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
```

### Enable CoreDNS query logging (temporary — high volume!)
```bash
kubectl edit configmap coredns -n kube-system
# Add "log" plugin in the Corefile block:
# .:53 {
#     log
#     ...
# }
kubectl rollout restart deployment coredns -n kube-system
```

### Common CoreDNS issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| DNS timeout ~5s | UDP truncation + conntrack issue | Set `DNSCONFIG_NDOTS=2` or use TCP for DNS |
| `NXDOMAIN` for external names | ndots setting causing search path blowup | Reduce `ndots:5` to `ndots:2` in pod dnsConfig |
| CoreDNS OOMKilled | Large number of pods / high query rate | Increase CoreDNS memory limit, scale replicas |
| Pods can't resolve cluster.local | NetworkPolicy blocking 53/UDP | Allow egress to kube-dns service CIDRs |

### CoreDNS scaling
```bash
# Scale manually
kubectl scale deployment coredns -n kube-system --replicas=4

# Or use cluster-proportional-autoscaler for CoreDNS
```

### ndots fix (per-pod)
```yaml
spec:
  dnsConfig:
    options:
      - name: ndots
        value: "2"
      - name: attempts
        value: "2"
      - name: timeout
        value: "1"
```

---

## Pod-to-Pod Connectivity

```bash
# From debug pod, test connectivity
kubectl run -it --rm nettest --image=nicolaka/netshoot --restart=Never -n <NS> -- \
  curl -v http://<POD_IP>:<PORT>/health

# Check network policy
kubectl get networkpolicy -n <NS>
kubectl describe networkpolicy <NAME> -n <NS>

# Trace route
kubectl exec -it <POD> -n <NS> -- traceroute <TARGET_IP>
```

### Security Group for Pods
If using SGP (Security Group for Pods):
```bash
kubectl get securitygrouppolicies -n <NS>
# Verify ENI security groups are assigned correctly
aws ec2 describe-network-interfaces \
  --filters "Name=description,Values=*<POD_NAME>*" \
  --query 'NetworkInterfaces[].Groups'
```

---

## Service Discovery Issues

```bash
# Verify service has endpoints
kubectl get endpoints <SERVICE> -n <NS>
kubectl describe svc <SERVICE> -n <NS>

# Check if selector matches pods
kubectl get pods -n <NS> --selector=<KEY>=<VALUE>
```

Common: service selector labels don't match pod labels after a rename/refactor.

---

## Node-Level Network Debugging

```bash
# From node via SSM
ip route show
ip link show
iptables -t nat -L KUBE-SERVICES -n | head -30
conntrack -L | wc -l  # high conntrack table = potential performance issue

# Check VPC route table has routes to pod CIDRs
aws ec2 describe-route-tables --filter "Name=vpc-id,Values=<VPC_ID>"
```

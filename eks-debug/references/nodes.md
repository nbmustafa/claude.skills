# EKS Node Debugging Reference

## NotReady Runbook

### Step 1 — Identify the node and condition
```bash
kubectl get nodes -o wide
kubectl describe node <NODE_NAME> | grep -A 20 "Conditions:"
kubectl describe node <NODE_NAME> | grep -A 10 "Events:"
```

Look for conditions: `MemoryPressure`, `DiskPressure`, `PIDPressure`, `NetworkUnavailable`.

### Step 2 — SSH / SSM into the node
```bash
# Preferred (no bastion needed)
aws ssm start-session --target <EC2_INSTANCE_ID>

# Check kubelet
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 100 --no-pager

# Check containerd
sudo systemctl status containerd
sudo journalctl -u containerd -n 50 --no-pager
```

### Step 3 — Common NotReady causes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `NetworkPlugin cni failed` | VPC CNI not ready | Restart `aws-node` DaemonSet pod on node |
| `failed to set bridge addr` | stale CNI state | Delete `/var/lib/cni/networks/` on node, restart kubelet |
| kubelet `certificate expired` | cert rotation failed | Rotate node, check `rotateCertificates: true` in kubelet config |
| `node lease not renewed` | network issue or kubelet crash | Check VPC route tables, security groups |
| `runtime not running` | containerd crash | `sudo systemctl restart containerd` |
| Disk full | log/image accumulation | `sudo crictl rmi --prune`, clean `/var/log` |

### Step 4 — Disk Pressure
```bash
# On the node via SSM
df -h
du -sh /var/log/pods/* | sort -rh | head -10
sudo crictl images | awk '{print $3}' | sort -rh  # large images cached

# Force image GC
sudo crictl rmi --prune
```
EKS kubelet GC thresholds: evictionHard `nodefs.available<10%`, `imagefs.available<15%`.

### Step 5 — Memory Pressure
```bash
# On the node
free -h
cat /proc/meminfo | grep -E "MemTotal|MemFree|Cached|SwapTotal"
sudo dmesg | grep -i "oom\|killed" | tail -20
```

Check for system-reserved memory: EKS reserves memory for kubelet/OS via `--system-reserved`.

---

## Drain & Eviction

### Safe drain (PDB-aware)
```bash
kubectl drain <NODE_NAME> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=60 \
  --timeout=300s

# If stuck on PDB:
kubectl get pdb -A
kubectl describe pdb <PDB_NAME> -n <NS>  # check minAvailable vs current
```

### Force drain (last resort, may cause downtime)
```bash
kubectl drain <NODE_NAME> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --disable-eviction \   # bypasses PDBs
  --force
```

---

## Bootstrap Failures (nodes not joining)

```bash
# Check EC2 user-data bootstrap log
aws ssm start-session --target <INSTANCE_ID>
sudo cat /var/log/cloud-init-output.log | tail -50
sudo cat /var/log/messages | grep -i "bootstrap\|kubelet\|api" | tail -30
```

### Common causes:
- **Wrong cluster name** in bootstrap script
- **SG missing 443 outbound** to EKS control plane endpoint
- **IMDSv2 hop limit = 1** for containers (set to 2 for EKS nodes)
  ```bash
  aws ec2 modify-instance-metadata-options \
    --instance-id <ID> \
    --http-put-response-hop-limit 2
  ```
- **aws-auth missing the node IAM role** — check `aws-auth` ConfigMap
- **Bottlerocket**: check `apiclient get kubernetes` for bootstrap status

---

## Managed Node Group Issues

```bash
# Check MNG health
aws eks describe-nodegroup \
  --cluster-name <CLUSTER> \
  --nodegroup-name <MNG_NAME> \
  --query 'nodegroup.{status:status,health:health,scalingConfig:scalingConfig}'

# Force update (rolling replace)
aws eks update-nodegroup-version \
  --cluster-name <CLUSTER> \
  --nodegroup-name <MNG_NAME>
```

### MNG stuck in DEGRADED:
- Check ASG launch template for correct AMI
- Check ASG activity history in EC2 console
- Verify IAM role has `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`

---

## Spot Interruption Handling

With Karpenter: interruptions handled automatically via EC2 Spot interruption notices.
With CA + Spot: need `aws-node-termination-handler` DaemonSet.

```bash
# Verify NTH is running
kubectl get ds -n kube-system aws-node-termination-handler

# Check Karpenter handles interruptions
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | grep -i "spot\|interrupt"
```

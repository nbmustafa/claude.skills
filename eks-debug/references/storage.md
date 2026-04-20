# Storage Debugging Reference (EBS CSI, EFS CSI)

## PVC Stuck Pending

```bash
kubectl describe pvc <PVC_NAME> -n <NS>
# Look for "Events:" — provisioner error messages appear here

kubectl get storageclass
kubectl describe storageclass <SC_NAME>
```

### EBS CSI — PVC Pending causes

| Event message | Cause | Fix |
|---------------|-------|-----|
| `failed to provision volume: AccessDenied` | EBS CSI driver IRSA missing perms | Verify IRSA role has `AmazonEBSCSIDriverPolicy` |
| `volume type not supported in AZ` | `gp3` not available in that AZ (rare) | Switch AZ or volume type |
| `WaitForFirstConsumer` mode | StorageClass has `volumeBindingMode: WaitForFirstConsumer` | Normal — PVC binds when pod is scheduled |
| `exceeded maximum number of attached volumes` | Node at EBS limit (default 39 for m5) | Spread pods or use EFS |
| PVC references missing StorageClass | SC name typo | `kubectl get sc` and verify name |

### Verify EBS CSI driver
```bash
kubectl get pods -n kube-system -l app=ebs-csi-controller
kubectl logs -n kube-system -l app=ebs-csi-controller -c csi-provisioner --tail=50
kubectl logs -n kube-system -l app=ebs-csi-node -c ebs-plugin --tail=30
```

---

## Volume Mount Failures

```bash
kubectl describe pod <POD> -n <NS>
# Look for: "MountVolume.MountDevice failed" or "Unable to attach or mount volumes"
```

### EBS volume stuck attaching
```bash
# Check if volume is attached to old/dead node
aws ec2 describe-volumes --volume-ids <VOL_ID> \
  --query 'Volumes[].Attachments'
```

### Multi-attach error
- EBS volumes (gp2/gp3) support only `ReadWriteOnce` — one node at a time
- For multi-pod shared storage, use EFS with `ReadWriteMany`
- Check PVC accessModes: `kubectl get pvc <n> -n <NS> -o json | jq '.spec.accessModes'`

### Volume in wrong AZ
EBS volumes are AZ-scoped. If pod is rescheduled to a different AZ, mount fails.
Fix: Use topology constraints or node selectors to pin pod to correct AZ.
```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values: ["ap-southeast-2"]
```

---

## EFS CSI Driver

```bash
kubectl get pods -n kube-system -l app=efs-csi-controller
kubectl logs -n kube-system -l app=efs-csi-controller --tail=50

# Check EFS mount from node
```

### EFS PVC Pending
- EFS must be in same VPC as EKS cluster
- Security group on EFS mount target must allow port 2049 (NFS) from node SGs
- EFS CSI driver needs IRSA with `elasticfilesystem:*` permissions

### EFS performance issues
- `generalPurpose` mode: max 35,000 IOPS — if hitting limits, switch to `maxIO`
- Enable EFS burst credits monitoring in CloudWatch
- For latency-sensitive workloads, use Provisioned Throughput mode

---

## PV/PVC Stuck Terminating

```bash
# Check for finalizers blocking deletion
kubectl get pvc <PVC_NAME> -n <NS> -o json | jq '.metadata.finalizers'

```

Warning: Removing finalizers without cleaning the backing volume may leave orphaned EBS volumes/EFS access points. Check AWS console after.

---

## Volume Snapshot (if VolumeSnapshot CRD installed)
```bash
kubectl get volumesnapshots -n <NS>
kubectl get volumesnapshotcontents
kubectl describe volumesnapshot <n> -n <NS>
# Check: snapshots require EBS CSI driver with snapshot capability enabled
```

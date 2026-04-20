# IAM, IRSA & RBAC Debugging Reference

## IRSA Debugging

IRSA = IAM Roles for Service Accounts. Pods assume AWS roles via projected ServiceAccount tokens.

### Step 1 — Verify the service account annotation
```bash
kubectl get sa <SA_NAME> -n <NS> -o json | \
  jq '.metadata.annotations."eks.amazonaws.com/role-arn"'
# Should return: "arn:aws:iam::<ACCOUNT>:role/<ROLE_NAME>"
```

### Step 2 — Verify the OIDC provider is set up
```bash
aws iam list-open-id-connect-providers
aws eks describe-cluster --name <CLUSTER> \
  --query 'cluster.identity.oidc.issuer'
# The OIDC URL must exist as an OIDC provider in IAM
```

### Step 3 — Verify the trust policy
```bash
aws iam get-role --role-name <ROLE_NAME> \
  --query 'Role.AssumeRolePolicyDocument'
```
Trust policy must have:
```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::<ACCOUNT>:oidc-provider/oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>:sub": "system:serviceaccount:<NS>:<SA_NAME>"
    }
  }
}
```

### Step 4 — Verify env vars are injected into the pod
```bash
kubectl exec -it <POD> -n <NS> -- env | grep -E "AWS_ROLE|AWS_WEB_IDENTITY|AWS_DEFAULT_REGION"
# Should show:
# AWS_ROLE_ARN=arn:aws:iam::<ACCOUNT>:role/<ROLE>
# AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

If missing: pod was not restarted after SA annotation was added, or webhook is not running.
```bash
kubectl get mutatingwebhookconfigurations | grep -i irsa
# Check pod-identity-webhook
kubectl get pods -n kube-system | grep pod-identity
```

### Step 5 — Test the token manually
```bash
kubectl exec -it <POD> -n <NS> -- sh
TOKEN=$(cat /var/run/secrets/eks.amazonaws.com/serviceaccount/token)
aws sts assume-role-with-web-identity \
  --role-arn $AWS_ROLE_ARN \
  --role-session-name test \
  --web-identity-token $TOKEN
```

---

## EKS Pod Identity (newer alternative to IRSA)

```bash
# List pod identity associations
aws eks list-pod-identity-associations --cluster-name <CLUSTER>

# Describe specific association
aws eks describe-pod-identity-association \
  --cluster-name <CLUSTER> \
  --association-id <ID>

# Verify EKS Pod Identity agent is running
kubectl get ds -n kube-system eks-pod-identity-agent
```

---

## aws-auth ConfigMap (Legacy Authentication)

```bash
kubectl get configmap aws-auth -n kube-system -o yaml
```

Structure:
```yaml
data:
  mapRoles: |
    - rolearn: arn:aws:iam::<ACCOUNT>:role/<NODE_ROLE>
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
    - rolearn: arn:aws:iam::<ACCOUNT>:role/<ADMIN_ROLE>
      username: admin
      groups:
        - system:masters
  mapUsers: |
    - userarn: arn:aws:iam::<ACCOUNT>:user/<USER>
      username: <USER>
      groups:
        - system:masters
```

**Beware**: malformed YAML in aws-auth breaks ALL cluster authentication. Always edit carefully:
```bash
# Safe edit with backup
kubectl get configmap aws-auth -n kube-system -o yaml > aws-auth-backup.yaml
kubectl edit configmap aws-auth -n kube-system
```

---

## RBAC Debugging

```bash
# Check what permissions a service account has
kubectl auth can-i list pods \
  --as=system:serviceaccount:<NS>:<SA_NAME> -n <NS>

# Full RBAC audit for a SA
kubectl get rolebindings,clusterrolebindings -A -o json | \
  jq --arg sa "<SA_NAME>" --arg ns "<NS>" \
  '.items[] | select(.subjects[]? | .kind=="ServiceAccount" and .name==$sa and .namespace==$ns)'

# What can this subject do?
kubectl auth can-i --list \
  --as=system:serviceaccount:<NS>:<SA_NAME> -n <NS>
```

### "Forbidden" errors in pod logs
1. SA lacks the ClusterRole/Role for the API call
2. Wrong namespace in RoleBinding
3. RBAC aggregation not propagated yet (wait 10s or restart API server — latter not possible on EKS)

Fix: create or update RoleBinding/ClusterRoleBinding pointing to the SA.

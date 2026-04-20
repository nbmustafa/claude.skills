# Security Debugging Reference

## OPA / Gatekeeper

```bash
kubectl get pods -n gatekeeper-system
kubectl logs -n gatekeeper-system -l control-plane=controller-manager --tail=50

# List all constraint templates and constraints
kubectl get constrainttemplate
kubectl get constraints -A  # lists all instances of all constraint types

# Check violations
kubectl get constraints -A -o json | \
  jq '.items[] | select(.status.totalViolations > 0) | {name:.metadata.name, violations:.status.violations[:3]}'
```

### Admission denial from Gatekeeper
When a resource creation is denied, the error looks like:
```
admission webhook "validation.gatekeeper.sh" denied the request: [...constraint details...]
```

```bash
# Find the constraining policy
kubectl get constrainttemplate <TEMPLATE_NAME> -o yaml
kubectl get <CONSTRAINT_KIND> <CONSTRAINT_NAME> -o yaml
```

**Audit vs Enforce mode**: Gatekeeper constraints in `warn` or `dryrun` mode won't block but will log violations. `deny` mode blocks.

---

## Kyverno

```bash
kubectl get pods -n kyverno
kubectl logs -n kyverno -l app.kubernetes.io/component=admission-controller --tail=50

kubectl get clusterpolicies
kubectl get policies -A
kubectl get policyreports -A  # post-deployment audit
kubectl get clusterpolicyreports
```

### Kyverno blocking a deployment
```bash
# Check recent policy audit
kubectl get policyreport -n <NS> -o yaml | \
  yq '.results[] | select(.result == "fail")'

# Temporarily set a policy to audit mode (not recommended for prod)
kubectl patch clusterpolicy <POLICY_NAME> \
  --type=merge -p '{"spec":{"validationFailureAction":"audit"}}'
```

---

## Pod Security Admission (PSA)

EKS 1.25+ deprecates PodSecurityPolicy; PSA is namespace-level via labels.

```bash
# Check namespace PSA labels
kubectl get ns <NS> --show-labels | grep pod-security

# Standard labels:
# pod-security.kubernetes.io/enforce: restricted|baseline|privileged
# pod-security.kubernetes.io/warn: ...
# pod-security.kubernetes.io/audit: ...
```

Pod blocked by PSA shows events like:
```
admission webhook "pod-security-webhook" denied the request: 
  pods "..." is forbidden: violates PodSecurity "restricted:latest"
```

Fix: adjust securityContext to meet the profile, or relax namespace label to `baseline`.

---

## Network Policies

```bash
kubectl get networkpolicy -n <NS>
kubectl describe networkpolicy <n> -n <NS>

# Test connectivity with debug pod
kubectl run -it --rm nettest \
  --image=nicolaka/netshoot \
  --restart=Never -n <SOURCE_NS> -- \
  curl -v --max-time 3 http://<TARGET_SVC>.<TARGET_NS>.svc.cluster.local:<PORT>/

# Check if VPC CNI enforces network policies (requires Network Policy Controller)
kubectl get ds -n kube-system aws-network-policy-agent
```

Default deny all pattern — verify intent:
```yaml
# This blocks ALL ingress to a namespace
spec:
  podSelector: {}  # selects all pods
  policyTypes: [Ingress]
  # No ingress rules = deny all
```

---

## Secrets Management

### AWS Secrets Manager / Parameter Store via CSI Driver
```bash
kubectl get secretproviderclass -n <NS>
kubectl describe secretproviderclass <n> -n <NS>

kubectl get pods -n kube-system -l app=secrets-store-csi-driver
kubectl logs -n kube-system -l app=secrets-store-csi-driver --tail=30

# Check mount failed events
kubectl describe pod <POD> -n <NS> | grep -A 10 "Events"
```

Common CSI secret errors:
- IRSA not set up on pod SA → `AccessDenied` mounting secret
- Secret version not found → check version ID or "AWSCURRENT" stage
- SecretProviderClass namespace mismatch → must be in same namespace as pod

### External Secrets Operator (ESO)
```bash
kubectl get externalsecrets -n <NS>
kubectl describe externalsecret <n> -n <NS>  # check "Conditions" for sync errors
kubectl get pods -n external-secrets
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=30
```

---

## Falco (Runtime Security)

```bash
kubectl get pods -n falco
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=50 | grep -E "Warning|Error|Critical"
# Falco events are categorized by priority
```

If Falco is generating too many alerts (noisy rules):
```bash
kubectl get configmap falco-config -n falco -o yaml | grep -A 5 "rules_file"
# Add custom exceptions in falco_rules.local.yaml
```

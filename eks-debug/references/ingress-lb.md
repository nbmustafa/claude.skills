# Ingress & Load Balancer Debugging Reference

## ALB Ingress Controller (aws-load-balancer-controller)

### Controller health
```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller \
  --tail=100 | grep -E "error|ERR|failed|reconcile"
```

### Ingress not creating ALB

**Step 1 — Describe the Ingress**
```bash
kubectl describe ingress <NAME> -n <NS>
# Look for "Events:" section — controller errors appear here
```

**Step 2 — Common causes**

| Symptom in logs | Cause | Fix |
|-----------------|-------|-----|
| `unauthorized: not authorized` | Controller IRSA missing perms | Check IRSA role, attach `AWSLoadBalancerControllerIAMPolicy` |
| `subnets not found` | Subnets not tagged | Tag public subnets `kubernetes.io/role/elb=1`, private `kubernetes.io/role/internal-elb=1` |
| `certificate not found` | Wrong ACM ARN in annotation | Verify cert ARN and region match |
| `TargetGroup already exists` | Stale TG from deleted ingress | Manually delete orphaned TG in AWS console |
| `IngressClass not found` | Missing `ingressClassName` | Add `spec.ingressClassName: alb` |

**Step 3 — Required annotations**
```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: alb              # or use spec.ingressClassName
    alb.ingress.kubernetes.io/scheme: internet-facing  # or internal
    alb.ingress.kubernetes.io/target-type: ip     # recommended; or instance
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:...
```

---

## 502 / 504 Errors

### 502 Bad Gateway — target returning errors
```bash
# Check target health in AWS
aws elbv2 describe-target-health \
  --target-group-arn <TG_ARN> \
  --query 'TargetHealthDescriptions[*].{IP:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}'

# Common: pod not passing health check
kubectl describe ingress <NAME> -n <NS> | grep "health"
# Default health check: GET / → 200. Override with:
# alb.ingress.kubernetes.io/healthcheck-path: /healthz
# alb.ingress.kubernetes.io/success-codes: 200-299
```

### 504 Gateway Timeout — upstream too slow or unreachable
```bash
# Check pod response time
kubectl exec -it <POD> -n <NS> -- curl -v -w "%{time_total}\n" http://localhost:<PORT>/path

# Increase ALB idle timeout (default 60s)
# alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=300

# Check pod is READY before ALB sends traffic
kubectl get pods -n <NS> -l <SELECTOR>  # all must be Running + Ready
```

### target-type: instance vs ip
- `ip` mode: traffic goes directly to pod IP — requires VPC CNI, faster, preferred
- `instance` mode: traffic goes to NodePort — works with any CNI, but adds a hop
- With Fargate, MUST use `ip` mode

---

## NLB (Network Load Balancer)

```bash
# Created via Service type: LoadBalancer
kubectl describe svc <SVC_NAME> -n <NS>
# Look for "LoadBalancer Ingress:" with the NLB DNS name
```

```yaml
# NLB annotations
service.beta.kubernetes.io/aws-load-balancer-type: external
service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
```

**NLB not getting external IP:**
- SG rules: NLB with IP mode requires SG to allow traffic on pod port
- Check events: `kubectl describe svc <SVC>`

---

## TLS / Cert Issues

```bash
# Check ACM cert status
aws acm describe-certificate --certificate-arn <ARN> \
  --query 'Certificate.{Status:Status,DomainName:DomainName,SubjectAlternativeNames:SubjectAlternativeNames}'

# Verify DNS validation is complete
aws acm describe-certificate --certificate-arn <ARN> \
  --query 'Certificate.DomainValidationOptions'

# Check cert on live ALB
openssl s_client -connect <ALB_DNS>:443 -servername <HOSTNAME> 2>/dev/null | \
  openssl x509 -noout -dates -subject
```

**cert-manager (if used):**
```bash
kubectl get certificates -n <NS>
kubectl describe certificate <n> -n <NS>
kubectl get certificaterequests -n <NS>
kubectl logs -n cert-manager -l app=cert-manager --tail=50
```

---

## Ingress Controller IAM Policy

Minimum required actions for `aws-load-balancer-controller`:
- `elasticloadbalancing:*`, `ec2:Describe*`, `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`
- `acm:ListCertificates`, `acm:DescribeCertificate`
- `cognito-idp:*` (if using Cognito auth)
- Full policy: https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/main/docs/install/iam_policy.json

# Service Mesh Debugging Reference (Istio / App Mesh)

## Istio

### Health check
```bash
kubectl get pods -n istio-system
istioctl proxy-status  # sync status of all sidecars
istioctl analyze -n <NS>  # configuration analysis + warnings
```

### Sidecar injection not happening
```bash
# Check namespace label
kubectl get ns <NS> --show-labels | grep istio-injection
# Must have: istio-injection=enabled

# Check pod-level override
kubectl get pod <POD> -n <NS> -o json | \
  jq '.metadata.annotations."sidecar.istio.io/inject"'
# "false" overrides namespace label

# Restart pods to inject
kubectl rollout restart deployment <n> -n <NS>
```

### Traffic not reaching service (503 / connection reset)

```bash
# Check Envoy config for a pod
istioctl proxy-config cluster <POD>.<NS>
istioctl proxy-config listener <POD>.<NS>
istioctl proxy-config route <POD>.<NS>

# Check mTLS mode
kubectl get peerauthentication -n <NS>
kubectl get destinationrule -n <NS>

# Common: STRICT mTLS set but one service has no sidecar
# Fix: set PeerAuthentication to PERMISSIVE during migration
```

### VirtualService / DestinationRule Issues
```bash
kubectl get virtualservice -n <NS>
kubectl describe virtualservice <n> -n <NS>
kubectl get destinationrule -n <NS>

# Validate with istioctl
istioctl validate -f my-virtualservice.yaml

# Check if VS is actually applied to envoy
istioctl proxy-config route <POD>.<NS> --name 80 -o json | jq '.[].virtualHosts'
```

### Debugging 503 errors
```bash
# Envoy access logs (if enabled)
kubectl logs <POD> -n <NS> -c istio-proxy --tail=50

# Or enable access logging via MeshConfig:
# accessLogFile: /dev/stdout

# Check response flags in logs:
# UF = upstream connection failure
# UH = no healthy upstream
# NR = no route found
# DC = downstream connection termination
```

### Slow traffic / high latency
```bash
# Check Envoy circuit breakers and outlier detection
istioctl proxy-config cluster <POD>.<NS> -o json | \
  jq '.[] | select(.name | contains("<SERVICE>")) | .circuitBreakers, .outlierDetection'

# Check retries (can amplify load)
kubectl get virtualservice <n> -n <NS> -o yaml | grep -A 5 "retries"
```

### Istio control plane issues
```bash
kubectl logs -n istio-system -l app=istiod --tail=50 | grep -E "error|ERROR|warn"

# Check xDS sync lag
istioctl proxy-status | grep -v SYNCED
```

---

## Liveness / Readiness Probes with Istio

Istio intercepts HTTP probes by default in older versions. In Istio 1.9+, probes are rewritten.

If probes fail with Istio:
```bash
# Option 1: Use exec probe instead of httpGet
# Option 2: Exempt from mTLS via annotation
kubectl annotate pod <POD> -n <NS> \
  traffic.sidecar.istio.io/excludeInboundPorts="8080"

# Option 3: In MeshConfig, set holdApplicationUntilProxyStarts: true
```

---

## AWS App Mesh (Legacy)

```bash
kubectl get meshes
kubectl get virtualservices -A  # App Mesh vs Istio VirtualService — different CRDs
kubectl get virtualrouters -A
kubectl get virtualnodes -A

# Controller
kubectl get pods -n appmesh-system
kubectl logs -n appmesh-system -l app.kubernetes.io/name=appmesh-controller --tail=50

# Envoy sidecar logs
kubectl logs <POD> -n <NS> -c envoy --tail=50
```

Note: AWS App Mesh is in maintenance mode. AWS recommends migrating to Istio on EKS.

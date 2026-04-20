# Observability Debugging Reference

## CloudWatch Container Insights

```bash
# Verify CloudWatch agent is running
kubectl get pods -n amazon-cloudwatch
kubectl logs -n amazon-cloudwatch -l name=cloudwatch-agent --tail=30

# Fluent Bit (log forwarder)
kubectl get pods -n amazon-cloudwatch -l k8s-app=fluent-bit
kubectl logs -n amazon-cloudwatch -l k8s-app=fluent-bit --tail=30 | grep -E "error|ERROR"
```

### Missing metrics in CloudWatch
- Node IAM role must have `CloudWatchAgentServerPolicy`
- Check CW agent config: `kubectl get configmap cwagentconfig -n amazon-cloudwatch -o yaml`
- Verify log group exists: `/aws/containerinsights/<CLUSTER>/performance`

---

## Prometheus / Grafana Stack (kube-prometheus-stack)

```bash
kubectl get pods -n monitoring  # or prometheus namespace
kubectl get prometheusrule -A   # check rules are loaded
kubectl get servicemonitor -A   # targets for scraping

# Prometheus UI port-forward
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Then open: http://localhost:9090/targets  — check for DOWN targets
```

### Missing metrics
```bash
# Check ServiceMonitor selector matches service labels
kubectl describe servicemonitor <n> -n <NS>
kubectl get svc <TARGET_SVC> -n <NS> --show-labels

# Check Prometheus RBAC can scrape the namespace
kubectl get clusterrole prometheus-kube-prometheus-prometheus -o yaml | grep -A 5 "rules"
```

### Alertmanager not firing
```bash
kubectl port-forward -n monitoring svc/alertmanager 9093:9093
# http://localhost:9093/#/alerts — check silence rules and routing

kubectl get secret alertmanager-prometheus-kube-prometheus-alertmanager -n monitoring -o yaml | \
  yq '.data."alertmanager.yaml"' | base64 -d
```

---

## Distributed Tracing (X-Ray / Jaeger / Tempo)

### AWS X-Ray
```bash
# X-Ray daemon as sidecar or DaemonSet
kubectl get ds -n kube-system aws-xray-daemon
kubectl logs -n kube-system -l app=xray-daemon --tail=30

# Node IAM or IRSA needs: xray:PutTraceSegments, xray:PutTelemetryRecords
```

### OpenTelemetry Collector
```bash
kubectl get pods -n opentelemetry
kubectl describe pod <OTEL_POD> -n opentelemetry
# Check pipeline config
kubectl get configmap <OTEL_CM> -n opentelemetry -o yaml | yq '.data."otel-collector-config.yaml"'
```

---

## Log Aggregation (Fluent Bit / Fluentd)

```bash
# Fluent Bit health
kubectl get pods -n logging  # or amazon-cloudwatch
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit --tail=50 | \
  grep -E "error|warning|dropped"

# Check Fluent Bit config
kubectl get configmap fluent-bit-config -n logging -o yaml

# Test output connectivity (e.g., to OpenSearch)
kubectl exec -it <FLUENT_BIT_POD> -n logging -- \
  curl -v https://<OPENSEARCH_ENDPOINT>:443 -k
```

Common issues:
- `Backpressure` warnings: output too slow, increase `storage.max_chunks_up`
- `fluentd OOMKilled`: increase memory limit, tune buffer sizes
- Missing logs: check `Mem_Buf_Limit` and `storage.type filesystem`

---

## Metrics Server

```bash
kubectl top nodes  # if this fails, metrics-server is broken
kubectl get pods -n kube-system -l k8s-app=metrics-server
kubectl logs -n kube-system -l k8s-app=metrics-server --tail=30

# Common fix: --kubelet-insecure-tls flag needed in some configurations
kubectl edit deployment metrics-server -n kube-system
# Add to args: - --kubelet-insecure-tls
```

---

## Key Dashboards to Check

For a Grafana stack, commonly useful dashboards:
- **Node Exporter Full** (ID 1860) — CPU, memory, disk, network per node
- **Kubernetes / Compute Resources / Namespace** — resource usage by namespace
- **Kubernetes / Networking** — pod-level network traffic
- **CoreDNS** — DNS query rates and errors
- **Karpenter** — provisioning latency and node lifecycle
- **ALB Ingress Controller** — request rates, latency, 5xx rates

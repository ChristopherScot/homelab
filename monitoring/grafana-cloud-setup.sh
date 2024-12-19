helm repo add grafana https://grafana.github.io/helm-charts &&
  helm repo update &&
  helm upgrade --install --version ^1 --atomic --timeout 300s grafana-k8s-monitoring grafana/k8s-monitoring \
    --namespace "monitoring" --create-namespace --values - <<EOF
cluster:
  name: default
externalServices:
  prometheus:
    host: https://prometheus-prod-13-prod-us-east-0.grafana.net
    basicAuth:
      username: "1054401"
      password: $grafana_token
  loki:
    host: https://logs-prod-006.grafana.net
    basicAuth:
      username: "628971"
      password: $grafana_token
  tempo:
    host: https://tempo-prod-04-prod-us-east-0.grafana.net:443
    basicAuth:
      username: "625475"
      password: $grafana_token
metrics:
  enabled: true
  alloy:
    metricsTuning:
      useIntegrationAllowList: true
  cost:
    enabled: true
  kepler:
    enabled: true
  node-exporter:
    enabled: true
  beyla:
    enabled: true
logs:
  enabled: true
  pod_logs:
    enabled: true
  cluster_events:
    enabled: true
traces:
  enabled: true
receivers:
  grpc:
    enabled: true
  http:
    enabled: true
  zipkin:
    enabled: true
  grafanaCloudMetrics:
    enabled: true
opencost:
  enabled: true
  opencost:
    exporter:
      defaultClusterId: default
    prometheus:
      external:
        url: https://prometheus-prod-13-prod-us-east-0.grafana.net/api/prom
kube-state-metrics:
  enabled: true
prometheus-node-exporter:
  enabled: true
prometheus-operator-crds:
  enabled: false
kepler:
  enabled: true
alloy: {}
alloy-events: {}
alloy-logs: {}
beyla:
  enabled: true
EOF
#!/usr/bin/env bash
# Installs kube-prometheus-stack into monitoring.
# Run BEFORE install-karpenter.sh (ServiceMonitor CRD).
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh >/dev/null

KPS_VERSION=92.2.0
KPS_RELEASE=kube-prometheus-stack
MON_NS=monitoring
# demo only, port-forward access
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-karpenter-demo}"

echo "==> Installing ${KPS_RELEASE} ${KPS_VERSION} into ${MON_NS}"
helm upgrade --install "${KPS_RELEASE}" kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts \
  --version "${KPS_VERSION}" \
  --namespace "${MON_NS}" --create-namespace \
  --values manifests/12-observability/kube-prometheus-stack-values.yaml \
  --set-string grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD}" \
  --timeout 10m

echo "==> Waiting for rollouts"
kubectl -n "${MON_NS}" rollout status deploy/${KPS_RELEASE}-operator --timeout=300s
kubectl -n "${MON_NS}" rollout status deploy/${KPS_RELEASE}-kube-state-metrics --timeout=300s
kubectl -n "${MON_NS}" rollout status deploy/${KPS_RELEASE}-grafana --timeout=300s
kubectl -n "${MON_NS}" rollout status ds/${KPS_RELEASE}-prometheus-node-exporter --timeout=300s

# operator creates the StatefulSet async
for _ in $(seq 1 30); do
  kubectl -n "${MON_NS}" get sts prometheus-${KPS_RELEASE}-prometheus >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n "${MON_NS}" rollout status sts/prometheus-${KPS_RELEASE}-prometheus --timeout=300s

kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null
echo "==> Monitoring ready. Grafana:"
echo "    kubectl -n ${MON_NS} port-forward svc/${KPS_RELEASE}-grafana 3000:80"
echo "    http://localhost:3000  user: admin  password: ${GRAFANA_ADMIN_PASSWORD}"

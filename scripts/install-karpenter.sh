#!/usr/bin/env bash
# Installs Karpenter CRDs + controller (idempotent).
# Run install-monitoring.sh first.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh >/dev/null

if [ -z "${CLUSTER_ENDPOINT}" ] || [ "${CLUSTER_ENDPOINT}" = "None" ]; then
  echo "ERROR: CLUSTER_ENDPOINT empty; check AWS creds/cluster." >&2
  exit 1
fi

if ! kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  echo "WARN: ServiceMonitor CRD missing; run scripts/install-monitoring.sh first." >&2
  echo "WARN: Karpenter installs without its ServiceMonitor." >&2
fi

# first spot launch needs this
if ! aws iam get-role --role-name AWSServiceRoleForEC2Spot >/dev/null 2>&1; then
  aws iam create-service-linked-role --aws-service-name spot.amazonaws.com >/dev/null
fi

# stale creds cause 403 on public ECR
helm registry logout public.ecr.aws >/dev/null 2>&1 || true

echo "==> karpenter-crd ${KARPENTER_VERSION}"
helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" --create-namespace

echo "==> karpenter ${KARPENTER_VERSION}"
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
  --values manifests/03-install/karpenter-values.yaml \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "settings.interruptionQueue=${KARPENTER_QUEUE}"

kubectl -n "${KARPENTER_NAMESPACE}" rollout status deploy/karpenter --timeout=180s
kubectl -n "${KARPENTER_NAMESPACE}" get pods -l app.kubernetes.io/name=karpenter -o wide

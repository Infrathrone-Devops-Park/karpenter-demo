#!/usr/bin/env bash
# PARKED to BASELINE: reapply base manifests.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh >/dev/null

NS=demo

log() { printf '==> %s\n' "$*"; }

log "Applying base EC2NodeClass and NodePool"
kubectl apply -f manifests/base/
kubectl wait ec2nodeclass/default --for=condition=Ready --timeout=180s
kubectl wait nodepool/default --for=condition=Ready --timeout=120s

log "Applying demo namespace and inflate"
kubectl apply -f workloads/
kubectl -n "${NS}" scale deploy/inflate --replicas=0

# BASELINE: only inflate in demo
for d in $(kubectl -n "${NS}" get deploy -o name); do
  [ "${d}" = "deployment.apps/inflate" ] && continue
  kubectl -n "${NS}" delete "${d}" --wait=false
done
kubectl -n "${NS}" delete statefulsets --all --wait=false >/dev/null 2>&1 || true

echo
log "BASELINE summary"
kubectl get nodepools,ec2nodeclasses
kubectl get nodeclaims 2>&1
kubectl get nodes -L karpenter.sh/nodepool
kubectl -n "${NS}" get deploy
echo "For a full check run: scripts/reset.sh"

#!/usr/bin/env bash
# Parks the cluster: no Karpenter nodes.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh >/dev/null

NS=demo
WAIT_SECS=480

log() { printf '==> %s\n' "$*"; }

# 1. demo workloads to zero
log "Scaling workloads in ${NS} to 0"
if kubectl get ns "${NS}" >/dev/null 2>&1; then
  for kind in deployments statefulsets; do
    for o in $(kubectl -n "${NS}" get "${kind}" -o name); do
      kubectl -n "${NS}" scale "${o}" --replicas=0
    done
  done
  kubectl -n "${NS}" delete jobs --all --wait=false >/dev/null 2>&1 || true
fi

# 2. remove capacity sources
if kubectl get crd nodeoverlays.karpenter.sh >/dev/null 2>&1; then
  kubectl delete nodeoverlays --all --wait=false >/dev/null 2>&1 || true
fi
log "Deleting all NodePools (Karpenter drains its nodes)"
kubectl delete nodepools --all --wait=false

log "Deleting EC2NodeClasses other than default"
for nc in $(kubectl get ec2nodeclasses -o jsonpath='{.items[*].metadata.name}'); do
  [ "${nc}" = "default" ] && continue
  kubectl delete ec2nodeclass "${nc}" --wait=false
done

# 3. wait for nodes and instances
ec2_count() {
  aws ec2 describe-instances \
    --filters "Name=tag:karpenter.sh/nodepool,Values=*" \
              "Name=tag:eks:eks-cluster-name,Values=${CLUSTER_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,shutting-down" \
    --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo "?"
}
log "Waiting up to ${WAIT_SECS}s for zero NodeClaims and instances"
start=$(date +%s)
while :; do
  n="$(kubectl get nodeclaims -o name 2>/dev/null | wc -l | tr -d ' ')"
  i="$(ec2_count)"
  elapsed=$(( $(date +%s) - start ))
  [ "${n}" = "0" ] && [ "${i}" = "0" ] && break
  if [ "${elapsed}" -ge "${WAIT_SECS}" ]; then
    echo "WARN: timeout: nodeclaims=${n} instances=${i}" >&2
    break
  fi
  echo "    ${elapsed}s: nodeclaims=${n} karpenter-instances=${i}"
  sleep 15
done

# 4. summary
echo
log "PARKED summary"
kubectl get nodepools,ec2nodeclasses 2>&1
kubectl get nodeclaims 2>&1
kubectl get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type,karpenter.sh/capacity-type
echo "Karpenter EC2 instances still running: $(ec2_count)"
kubectl -n "${KARPENTER_NAMESPACE}" get deploy karpenter
kubectl -n monitoring get deploy,sts 2>/dev/null | head -10 || true
echo "Resume with: scripts/resume.sh"

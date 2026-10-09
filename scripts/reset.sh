#!/usr/bin/env bash
# Returns the cluster to BASELINE (idempotent).
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh >/dev/null

NS=demo
KNS="${KARPENTER_NAMESPACE}"
WAIT_SECS=360

log() { printf '==> %s\n' "$*"; }
has_crd() { kubectl get crd "$1" >/dev/null 2>&1; }

# 1. controller back to install values
log "Checking Karpenter Helm values"
vals="$(helm get values karpenter -n "${KNS}" -o json 2>/dev/null || echo '{}')"
gates="$(echo "${vals}" | jq -c '.settings.featureGates // empty')"
level="$(echo "${vals}" | jq -r '.logLevel // "info"')"
if [ -n "${gates}" ] || [ "${level}" != "info" ]; then
  log "Values differ (featureGates=${gates:-none} logLevel=${level}); re-running install"
  scripts/install-karpenter.sh
fi
replicas="$(kubectl -n "${KNS}" get deploy karpenter -o jsonpath='{.spec.replicas}')"
if [ "${replicas}" != "1" ]; then
  log "Karpenter replicas=${replicas}; scaling to 1"
  kubectl -n "${KNS}" scale deploy/karpenter --replicas=1
fi
kubectl -n "${KNS}" rollout status deploy/karpenter --timeout=180s

# 2. demo namespace workloads
log "Cleaning namespace ${NS}"
kubectl apply -f workloads/namespace.yaml >/dev/null
for d in $(kubectl -n "${NS}" get deploy -o name); do
  [ "${d}" = "deployment.apps/inflate" ] && continue
  kubectl -n "${NS}" delete "${d}" --wait=false
done
for kind in statefulsets daemonsets jobs cronjobs pdb hpa services podtemplates; do
  kubectl -n "${NS}" delete "${kind}" --all --wait=false >/dev/null 2>&1 || true
done
if has_crd capacitybuffers.autoscaling.x-k8s.io; then
  kubectl -n "${NS}" delete capacitybuffers --all --wait=false >/dev/null 2>&1 || true
fi
# replace drops any patched fields
kubectl replace --save-config -f workloads/inflate.yaml >/dev/null 2>&1 \
  || kubectl apply -f workloads/inflate.yaml >/dev/null
kubectl -n "${NS}" scale deploy/inflate --replicas=0
kubectl -n "${NS}" delete pods --all --grace-period=0 --wait=false >/dev/null 2>&1 || true

# 3. extra cluster objects from modules
log "Removing NodeOverlays and demo alert rules"
if has_crd nodeoverlays.karpenter.sh; then
  kubectl delete nodeoverlays --all --wait=false >/dev/null 2>&1 || true
fi
kubectl -n monitoring delete prometheusrule karpenter-demo-alerts --ignore-not-found >/dev/null 2>&1 || true

# 4. non-default NodePools / EC2NodeClasses
log "Deleting NodePools other than default"
for np in $(kubectl get nodepools -o jsonpath='{.items[*].metadata.name}'); do
  [ "${np}" = "default" ] && continue
  kubectl delete nodepool "${np}" --wait=false
done

# 5. default objects match manifests
# rc 0=same 1=differ 2=unknown 3=missing
spec_state() {
  local kind="$1" file="$2" live want
  live="$(kubectl get "${kind}" default -o json 2>/dev/null | jq -S '.spec' || true)"
  [ -z "${live}" ] && return 3
  want="$(sed 's/^  name: default$/  name: reset-probe/' "${file}" \
    | kubectl create --dry-run=server -o json -f - 2>/dev/null | jq -S '.spec' || true)"
  [ -z "${want}" ] && return 2
  [ "${live}" = "${want}" ] && return 0
  return 1
}
# apply first; recreate only if needed
kubectl apply -f manifests/base/ >/dev/null
recreate=false
rc=0; spec_state nodepool manifests/base/nodepool.yaml || rc=$?
[ "${rc}" = "1" ] && recreate=true
rc=0; spec_state ec2nodeclass manifests/base/ec2nodeclass.yaml || rc=$?
[ "${rc}" = "1" ] && recreate=true
if ${recreate}; then
  log "default objects still differ from manifests; recreating"
  kubectl delete nodepool default --ignore-not-found --timeout=6m
  kubectl delete ec2nodeclass default --ignore-not-found --timeout=4m
  kubectl apply -f manifests/base/ >/dev/null
fi

log "Deleting EC2NodeClasses other than default"
for nc in $(kubectl get ec2nodeclasses -o jsonpath='{.items[*].metadata.name}'); do
  [ "${nc}" = "default" ] && continue
  kubectl delete ec2nodeclass "${nc}" --wait=false
done

# 6. FIS leftovers
log "Deleting FIS templates tagged Name=karpenter-spot-demo"
for id in $(aws fis list-experiment-templates \
  --query "experimentTemplates[?tags.Name=='karpenter-spot-demo'].id" --output text 2>/dev/null || true); do
  [ "${id}" = "None" ] && continue
  aws fis delete-experiment-template --id "${id}" >/dev/null && echo "    deleted ${id}"
done

# 7. drain remaining Karpenter nodes
log "Deleting remaining NodeClaims (nothing runs on them)"
kubectl delete nodeclaims --all --wait=false >/dev/null 2>&1 || true

log "Waiting up to ${WAIT_SECS}s for zero NodeClaims"
start=$(date +%s)
while :; do
  n="$(kubectl get nodeclaims -o name 2>/dev/null | wc -l | tr -d ' ')"
  extra="$(kubectl get nodepools,ec2nodeclasses -o name 2>/dev/null | grep -vc '/default$' || true)"
  elapsed=$(( $(date +%s) - start ))
  [ "${n}" = "0" ] && [ "${extra}" = "0" ] && break
  if [ "${elapsed}" -ge "${WAIT_SECS}" ]; then
    echo "WARN: timeout: ${n} nodeclaims, ${extra} extra pools/classes left" >&2
    break
  fi
  echo "    ${elapsed}s: nodeclaims=${n} extra-pools/classes=${extra}"
  sleep 15
done

# 8. summary
kubectl wait nodepool/default --for=condition=Ready --timeout=120s >/dev/null || true
echo
log "BASELINE summary"
kubectl get nodepools,ec2nodeclasses
kubectl get nodeclaims 2>&1
kubectl get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type
kubectl -n "${NS}" get all
kubectl -n "${KNS}" get deploy karpenter \
  -o jsonpath='{"FEATURE_GATES="}{.spec.template.spec.containers[0].env[?(@.name=="FEATURE_GATES")].value}{"\n"}'

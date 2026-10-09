#!/usr/bin/env bash
# Destroys everything. Needs --yes-destroy.
set -euo pipefail

if [ "${1:-}" != "--yes-destroy" ]; then
  echo "This deletes the cluster, VPC and all demo AWS resources."
  echo "Re-run with: scripts/teardown.sh --yes-destroy"
  exit 1
fi

cd "$(dirname "$0")/.."
source scripts/env.sh >/dev/null

log() { printf '==> %s\n' "$*"; }
KNS="${KARPENTER_NAMESPACE}"
have_cluster=true
kubectl get nodes >/dev/null 2>&1 || have_cluster=false

kp_instances() {
  aws ec2 describe-instances \
    --filters "Name=tag:karpenter.sh/nodepool,Values=*" \
              "Name=tag:eks:eks-cluster-name,Values=${CLUSTER_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

# 1. workloads and load balancers
if ${have_cluster}; then
  log "Deleting demo workloads and LoadBalancer services"
  kubectl delete ns demo --ignore-not-found --timeout=5m || true
  kubectl get svc -A -o json \
    | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do kubectl -n "${ns}" delete svc "${name}" --timeout=5m || true; done

  # 2. Karpenter capacity, controller still up
  log "Deleting NodeOverlays and NodePools"
  kubectl get crd nodeoverlays.karpenter.sh >/dev/null 2>&1 \
    && kubectl delete nodeoverlays --all --timeout=2m || true
  kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1 \
    && kubectl delete nodepools --all --timeout=10m || true

  log "Waiting for NodeClaims to reach zero"
  for _ in $(seq 1 40); do
    n="$(kubectl get nodeclaims -o name 2>/dev/null | wc -l | tr -d ' ')"
    [ "${n}" = "0" ] && break
    echo "    nodeclaims=${n}"; sleep 15
  done

  log "Deleting EC2NodeClasses (removes instance profiles)"
  kubectl get crd ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1 \
    && kubectl delete ec2nodeclasses --all --timeout=5m || true

  # 3. Helm releases
  log "Uninstalling Helm releases"
  helm uninstall kube-prometheus-stack -n monitoring --wait --timeout 5m 2>/dev/null || true
  helm uninstall karpenter -n "${KNS}" --wait --timeout 5m 2>/dev/null || true
  helm uninstall karpenter-crd -n "${KNS}" --wait --timeout 5m 2>/dev/null || true
else
  echo "WARN: cluster unreachable; skipping Kubernetes steps" >&2
fi

# 4. FIS templates
log "Deleting FIS templates tagged Name=karpenter-spot-demo"
for id in $(aws fis list-experiment-templates \
  --query "experimentTemplates[?tags.Name=='karpenter-spot-demo'].id" --output text 2>/dev/null || true); do
  [ "${id}" = "None" ] && continue
  aws fis delete-experiment-template --id "${id}" >/dev/null && echo "    deleted ${id}"
done

# 5. orphan sweep before destroy
sweep() {
  log "Orphan sweep: Karpenter instances"
  ids="$(kp_instances)"
  if [ -n "${ids}" ] && [ "${ids}" != "None" ]; then
    echo "    terminating ${ids}"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids ${ids} >/dev/null
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids ${ids} || true
  fi

  log "Orphan sweep: Karpenter launch templates"
  for lt in $(aws ec2 describe-launch-templates \
    --filters "Name=tag:eks:eks-cluster-name,Values=${CLUSTER_NAME}" \
    --query "LaunchTemplates[?starts_with(LaunchTemplateName, 'karpenter.k8s.aws/')].LaunchTemplateId" --output text); do
    aws ec2 delete-launch-template --launch-template-id "${lt}" >/dev/null && echo "    deleted ${lt}"
  done
  for lt in $(aws ec2 describe-launch-templates \
    --filters "Name=tag:karpenter.k8s.aws/cluster,Values=${CLUSTER_NAME}" \
    --query 'LaunchTemplates[].LaunchTemplateId' --output text); do
    aws ec2 delete-launch-template --launch-template-id "${lt}" >/dev/null && echo "    deleted ${lt}"
  done

  log "Orphan sweep: Karpenter instance profiles"
  for ip in $(aws iam list-instance-profiles --path-prefix "/karpenter/${AWS_REGION}/${CLUSTER_NAME}/" \
    --query 'InstanceProfiles[].InstanceProfileName' --output text); do
    for role in $(aws iam get-instance-profile --instance-profile-name "${ip}" \
      --query 'InstanceProfile.Roles[].RoleName' --output text); do
      aws iam remove-role-from-instance-profile --instance-profile-name "${ip}" --role-name "${role}" || true
    done
    aws iam delete-instance-profile --instance-profile-name "${ip}" && echo "    deleted ${ip}"
  done

  vpc="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${CLUSTER_NAME}" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo None)"
  if [ -n "${vpc}" ] && [ "${vpc}" != "None" ]; then
    log "Orphan sweep: available ENIs in ${vpc}"
    for eni in $(aws ec2 describe-network-interfaces \
      --filters "Name=vpc-id,Values=${vpc}" "Name=status,Values=available" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do
      aws ec2 delete-network-interface --network-interface-id "${eni}" && echo "    deleted ${eni}"
    done
    log "Orphan sweep: k8s-* security groups in ${vpc}"
    for sg in $(aws ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=${vpc}" "Name=group-name,Values=k8s-*" \
      --query 'SecurityGroups[].GroupId' --output text); do
      aws ec2 delete-security-group --group-id "${sg}" && echo "    deleted ${sg}" || true
    done
  fi
}
sweep

# 6. terraform destroy, retry once
log "terraform destroy"
if ! terraform -chdir=terraform destroy -auto-approve; then
  echo "WARN: destroy failed; sweeping and retrying once" >&2
  sweep
  terraform -chdir=terraform destroy -auto-approve
fi

# 7. post-destroy check
log "Leftover check"
echo "Karpenter instances: $(kp_instances)"
aws ec2 describe-launch-templates \
  --filters "Name=tag:eks:eks-cluster-name,Values=${CLUSTER_NAME}" \
  --query 'LaunchTemplates[].LaunchTemplateName' --output text
aws iam list-instance-profiles --path-prefix "/karpenter/${AWS_REGION}/${CLUSTER_NAME}/" \
  --query 'InstanceProfiles[].InstanceProfileName' --output text
aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 \
  && echo "WARN: cluster still exists" || echo "Cluster ${CLUSTER_NAME} gone."

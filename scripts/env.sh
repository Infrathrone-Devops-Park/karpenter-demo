# Source from repo root: source scripts/env.sh
# Safe to source repeatedly; never sets -e.

export AWS_PROFILE=infrathrone-demo
export AWS_REGION=ap-south-1
export AWS_DEFAULT_REGION="${AWS_REGION}"
export CLUSTER_NAME=karpenter-demo
export KARPENTER_VERSION=1.14.1
export KARPENTER_NAMESPACE=kube-system

if [ ! -f scripts/env.sh ]; then
  echo "ERROR: source from repo root" >&2
  return 1 2>/dev/null || exit 1
fi

# dedicated kubeconfig; immune to context switches
export KUBECONFIG="${PWD}/.kube/${CLUSTER_NAME}.kubeconfig"
if [ ! -s "${KUBECONFIG}" ]; then
  mkdir -p "${PWD}/.kube"
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --kubeconfig "${KUBECONFIG}" >/dev/null 2>&1 || echo "WARN: kubeconfig not created" >&2
fi

# Queue name from Terraform state
_kd_queue=""
if command -v terraform >/dev/null 2>&1 && [ -d terraform ]; then
  _kd_queue="$(terraform -chdir=terraform output -raw karpenter_queue_name 2>/dev/null)" || _kd_queue=""
  case "${_kd_queue}" in
    *[[:space:]]*|*Warning*|*Error*) _kd_queue="" ;;
  esac
fi
export KARPENTER_QUEUE="${_kd_queue:-Karpenter-${CLUSTER_NAME}}"
unset _kd_queue

# Cluster facts from AWS
export CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
  --query 'cluster.endpoint' --output text 2>/dev/null || true)"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity \
  --query Account --output text 2>/dev/null || true)"

echo "AWS_PROFILE=${AWS_PROFILE} AWS_REGION=${AWS_REGION} CLUSTER_NAME=${CLUSTER_NAME}"
echo "KARPENTER_VERSION=${KARPENTER_VERSION} KARPENTER_NAMESPACE=${KARPENTER_NAMESPACE}"
echo "KARPENTER_QUEUE=${KARPENTER_QUEUE}"
echo "CLUSTER_ENDPOINT=${CLUSTER_ENDPOINT:-<not found>}"
echo "KUBECONFIG=${KUBECONFIG}"
echo "AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-<not found>}"

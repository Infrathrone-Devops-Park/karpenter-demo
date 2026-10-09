#!/usr/bin/env bash
# Prints or runs the demo watch panes.
# Usage: scripts/watch.sh [nodes|claims|logs|pods]

NODE_VIEWER=(eks-node-viewer --resources cpu,memory
  --extra-labels karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type,topology.kubernetes.io/zone)
CLAIMS=(kubectl get nodeclaims -w)
LOGS=(kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller -f --tail=20)
PODS=(kubectl get pods -n demo -o wide -w)

if [ -n "${1:-}" ]; then
  cd "$(dirname "$0")/.." && source scripts/env.sh >/dev/null
fi

case "${1:-}" in
  nodes)  exec "${NODE_VIEWER[@]}" ;;
  claims) exec "${CLAIMS[@]}" ;;
  logs)   exec "${LOGS[@]}" ;;
  pods)   exec "${PODS[@]}" ;;
  "")
    cat <<EOF
Recommended panes (run from repo root, after: source scripts/env.sh)

  Pane 1 (top, large)  : ${NODE_VIEWER[*]}
  Pane 2 (right top)   : ${CLAIMS[*]}
  Pane 3 (right bottom): ${LOGS[*]}
  Pane 4 (optional)    : ${PODS[*]}
  Main pane            : commands from docs/NN-*.md

Shortcut: scripts/watch.sh nodes|claims|logs|pods
EOF
    ;;
  *) echo "unknown pane: $1 (nodes|claims|logs|pods)" >&2; exit 1 ;;
esac

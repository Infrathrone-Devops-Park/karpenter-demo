# 12 — Observability: Metrics, Dashboards, Logs, Events

**Time:** 20 min · **Goal:** Show where Karpenter's signals live (Prometheus metrics, Grafana dashboards, JSON logs, Kubernetes events) and watch them move during a live scale-up and scale-down.

## What you'll show

- The Karpenter `/metrics` endpoint and the metric families that matter (all names verified against v1.14.1 source).
- Prometheus scraping Karpenter through the chart's ServiceMonitor; PromQL that changes live.
- The official Karpenter Grafana dashboards (Capacity, Performance) in the `Karpenter` folder.
- Structured JSON logs, filtering them with `jq`, and switching to `debug` log level with an explicit Helm upgrade.
- Kubernetes events from Karpenter, filtered by reason.
- A small alert rule set you would ship to production.

## Concepts

### Where the signals come from

```text
karpenter pod (kube-system)
  :8080 /metrics ──▶ Service karpenter (port http-metrics)
                        ▲
                        └── ServiceMonitor karpenter (chart, serviceMonitor.enabled=true)
                               ▲
Prometheus (monitoring, kube-prometheus-stack) ── scrapes every 30 s ──▶ Grafana dashboards
stdout (JSON) ──▶ kubectl logs                                          (folder "Karpenter")
Events ──▶ kubectl get events (source karpenter)
```

### Metric families (v1.14.1)

| Family | Metrics (prefix `karpenter_`) | Use |
|---|---|---|
| NodeClaims | `nodeclaims_created_total{reason,nodepool,min_values_relaxed}`, `nodeclaims_terminated_total{nodepool,capacity_type,zone}`, `nodeclaims_disrupted_total{reason,nodepool,capacity_type}` | Launch / churn rate, why nodes went away (`empty`, `underutilized`, `drifted`, `expired`, `spot_interrupted`, `insufficient_capacity`, …) |
| Nodes | `nodes_created_total`, `nodes_terminated_total`, `nodes_allocatable`, `nodes_total_pod_requests`, `nodes_total_daemon_requests`, `nodes_system_overhead`, `nodes_current_lifetime_seconds`, `nodes_drained_total`, `nodes_termination_duration_seconds` | Per-node capacity vs requests, labelled with `node_name`, `nodepool`, `capacity_type`, `instance_type`, `zone`, `resource_type` |
| Pods | `pods_state`, `pods_startup_duration_seconds`, `pods_provisioning_startup_duration_seconds`, `pods_provisioning_bound_duration_seconds`, `pods_provisioning_unbound_time_seconds` | Where pods run; how long pods waited for Karpenter capacity |
| Scheduler | `scheduler_scheduling_duration_seconds`, `scheduler_queue_depth`, `scheduler_unschedulable_pods_count`, `scheduler_ignored_pods_count` | Simulation latency, pods Karpenter cannot place |
| Disruption | `voluntary_disruption_decisions_total{decision,reason,consolidation_type}`, `voluntary_disruption_eligible_nodes{reason}`, `voluntary_disruption_decision_evaluation_duration_seconds`, `nodepools_allowed_disruptions` | Consolidation / drift activity and budgets |
| NodePools | `nodepools_usage{nodepool,resource_type}`, `nodepools_limit{nodepool,resource_type}`, `nodepools_cost_total` | Distance to `spec.limits` |
| Interruption | `interruption_received_messages_total{message_type}`, `interruption_deleted_messages_total`, `interruption_message_queue_duration_seconds`, `interruption_instance_status_unhealthy_total` | SQS pipeline health |
| Cloud provider | `cloudprovider_duration_seconds{controller,method}`, `cloudprovider_errors_total{method,error}`, `cloudprovider_instance_launch_failures_total{zone,capacity_type,reason}`, `cloudprovider_instance_type_offering_available`, `cloudprovider_instance_type_offering_price_estimate` | AWS API latency, ICE / quota failures, live price list |
| Cluster | `cluster_utilization_percent{resource_type}`, `cluster_state_node_count`, `cluster_state_synced` | Overall packing efficiency |
| Status conditions | `operator_nodeclaim_status_condition_count`, `operator_nodepool_status_condition_count`, `operator_ec2nodeclass_status_condition_count` (no `karpenter_` prefix) | Alert on objects stuck `Ready=False` |

Plus standard `controller_runtime_*`, `workqueue_*`, `leader_election_*` and `aws_sdk_go_request_*`.

### Logs

- JSON, one object per line: `level`, `time`, `logger`, `message`, `commit`, `controller`, and object references such as `NodeClaim: {"name": …}`, `NodePool`, `Node`, `Pod`.
- `logLevel` values: `debug`, `info` (default), `error`. Changing it changes the `LOG_LEVEL` env var, so the pod restarts. With one replica that is ~20–30 s without a controller; nothing is lost, Karpenter catches up after restart.

### Capacity used in this module

`inflate` scaled to 6 replicas = 3 vCPU of requests on the `default` NodePool (Spot first). Typically one 4-vCPU or two 2-vCPU Spot nodes.

## Demo

### Step 1 — Load the environment and check BASELINE
```bash
source scripts/env.sh
kubectl get nodepools,nodeclaims
kubectl get servicemonitor -A | grep karpenter
```
Expected: `default` NodePool, no NodeClaims. The ServiceMonitor listing shows `kube-system   karpenter`.

### Step 2 — Read raw metrics straight from the controller
Port-forward to the controller Service for a few seconds. Note: the API server proxy (`kubectl get --raw .../services/karpenter:http-metrics/proxy/metrics`) times out on this cluster; the control plane cannot reach pod port 8080.
```bash
kubectl -n kube-system port-forward svc/karpenter 8080:8080 >/dev/null 2>&1 &
PF=$!; sleep 2
curl -s localhost:8080/metrics | grep -E '^karpenter_(build_info|cluster_state_synced|nodepools_limit)'
curl -s localhost:8080/metrics | grep -E '^karpenter_cloudprovider_instance_type_offering_available.*c6a.large.* 1$'
kill $PF
```
Expected:
```text
karpenter_build_info{commit="bde0065",goarch="amd64",goversion="go1.26.6",version="1.14.1"} 1
karpenter_cluster_state_synced 1
karpenter_nodepools_limit{nodepool="default",resource_type="cpu"} 10
```
then six `karpenter_cloudprovider_instance_type_offering_available{capacity_type="on-demand|spot",instance_type="c6a.large",zone="ap-south-1a|b|c"} 1` lines (one per capacity type and zone).

### Step 3 — Port-forward Prometheus and check the scrape target
Run the port-forward in its own terminal (leave it running).
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```
Back in the main terminal:
```bash
curl -s localhost:9090/api/v1/query --data-urlencode 'query=up{job="karpenter"}' \
  | jq -c '.data.result[] | {job: .metric.job, namespace: .metric.namespace, value: .value[1]}'
```
Expected: `{"job":"karpenter","namespace":"kube-system","value":"1"}`.

Optionally open http://localhost:9090/targets and show the `serviceMonitor/kube-system/karpenter/0` target `UP`.

### Step 4 — Port-forward Grafana and open the Karpenter dashboards
Run in another terminal (leave it running).
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```
Open http://localhost:3000, log in `admin` / `karpenter-demo`. Dashboards → folder **Karpenter** → **Karpenter Capacity v1**. Set the time range to **Last 15 minutes** and auto-refresh **10s**.

Expected: panels `Nodes Created by nodepool`, `Nodes Terminated by nodepool`, `Nodes Eligible for Disruptions by "reason"`, `Node Disruptions by …`, `Disruption Actions performed by "type" and "decision"`, `Pod Distribution by …`, `Pod Phase`, `Nodepool Summary`, `Spot Node Percentage`, `Node Summary`. Mostly empty now: there are no Karpenter nodes.

### Step 5 — Generate activity: scale up
```bash
kubectl -n demo scale deploy/inflate --replicas 6
kubectl -n demo rollout status deploy/inflate --timeout=180s
kubectl get nodeclaims
```
Expected: 1 NodeClaim (Spot, 4 vCPU; validation run: `c8i-flex.xlarge`) or 2 smaller ones, rollout done in ~30 s.

### Step 6 — PromQL that moves live
Wait ~60 s for a scrape (30 s interval), then run each query.
```bash
q() { curl -s localhost:9090/api/v1/query --data-urlencode "query=$1" | jq -c '.data.result[] | {m: .metric, v: .value[1]}'; }
q 'sum by (nodepool, reason) (karpenter_nodeclaims_created_total)'
q 'karpenter_nodepools_usage{resource_type="cpu"} / karpenter_nodepools_limit{resource_type="cpu"}'
q 'sum by (node_name, capacity_type, instance_type) (karpenter_nodes_total_pod_requests{resource_type="cpu"})'
q 'count by (phase, capacity_type) (karpenter_pods_state{exported_namespace="demo"})'
q 'histogram_quantile(0.9, sum by (le) (rate(karpenter_pods_provisioning_startup_duration_seconds_bucket[15m])))'
```
Expected (values vary; counters are cumulative since the controller started):
- One line per NodePool ever used, for example `{"nodepool":"default","reason":"provisioned"}` → `35`, plus `spot-first`, `team-batch`, `od-replace`, `bottlerocket`, ... from earlier modules, and `{"nodepool":"default","reason":"drifted"}` (replacements).
- NodePool usage ratio `0.4` (4 of 10 CPU), with the full scrape label set (`job="karpenter"`, `pod=...`).
- Per-node pod CPU requests: `3.16` on the spot node (6 x 500m + 160m DaemonSets), plus the system node (`t3a.large`, ~`1.12`, no `capacity_type`).
- `{"capacity_type":"spot","phase":"Running"}` → `6`. Note: the scrape renames the metric's own `namespace` label to `exported_namespace` (`namespace` is always `kube-system`, the target's namespace).
- p90 time from pod creation to running for pods that needed a new node: about `35` seconds.

Point at the Grafana Capacity dashboard: `Nodes Created by nodepool`, `Pod Phase`, `Spot Node Percentage` (100%) and `Node Summary` have data now.

### Step 7 — Read the logs as structured data
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller --tail=-1 --since=10m \
  | jq -cR 'fromjson? | select(.message | test("nodeclaim|provisionable")) | {time, level, message, NodeClaim: .NodeClaim.name, type: ."instance-type"}'
```
Expected: lines `found provisionable pod(s)`, `computed new nodeclaim(s) to fit pod(s)`, `created nodeclaim`, `launched nodeclaim`, `registered nodeclaim`, `initialized nodeclaim`, each with the NodeClaim name. `launched nodeclaim` carries `instance-type`.

Count log lines by level:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller --tail=-1 --since=30m \
  | jq -rR 'fromjson? | .level' | sort | uniq -c
```
Expected: mostly `INFO` (validation run: 84 INFO, 39 ERROR). The `ERROR` lines are harmless `Reconciler error` / `NodePool.karpenter.sh "bottlerocket" not found` from the module 11 cleanup (pool deleted while its NodeClaim terminated).

### Step 8 — Events by reason
```bash
kubectl get events -A --field-selector source=karpenter --sort-by=.lastTimestamp | tail -15
kubectl get events -n demo --field-selector reason=Nominated --sort-by=.lastTimestamp | tail -6
```
Expected: the first command lists recent Karpenter events: `Nominated` (pods), `Launched`, `Registered`, `Ready`, `Initialized` (`Status condition transitioned, Type: …`), `DisruptionBlocked` (`Nodeclaim does not have an associated node`, `Node isn't initialized`) and `Unconsolidatable` (`SpotToSpotConsolidation is disabled, can't replace a spot node with a spot node`). The second shows six `Nominated` events: `Pod should schedule on: nodeclaim/default-xxxxx`.

### Step 9 — Generate the scale-down
```bash
kubectl -n demo scale deploy/inflate --replicas 0
kubectl get nodeclaims -w
```
Expected: after ~1 minute (`consolidateAfter: 1m`) the NodeClaims are deleted (empty-node consolidation). Ctrl-C when none remain (~1 min 45 s).

Then:
```bash
kubectl get events -A --field-selector reason=DisruptionTerminating
q 'sum by (decision, reason, consolidation_type) (karpenter_voluntary_disruption_decisions_total)'
q 'sum by (nodepool, reason) (karpenter_nodeclaims_disrupted_total)'
```
Expected: `DisruptionTerminating` events `Disrupting Node: Empty` and `Disrupting NodeClaim: Empty`. Metrics: `{"decision":"delete","reason":"empty",…}` ≥ 1 and `{"nodepool":"default","reason":"empty"}` ≥ 1 (counts include earlier modules). Real lines: `{"consolidation_type":"empty","decision":"delete","reason":"empty"}` → `8`, `{"consolidation_type":"single","decision":"replace","reason":"underutilized"}`, `{"decision":"replace","reason":"drifted"}` (no `consolidation_type` for drift). The events list also shows older `Drifted` / `Underutilized` terminations from modules 07 and 09. In Grafana, `Nodes Terminated by nodepool` and `Disruption Actions performed …` show the step.

### Step 10 — Karpenter Performance dashboard
Grafana → Karpenter → **Karpenter Performance v1**.

Expected: `Pod Startup Latency`, `Node Termination Latency`, `Controller Reconciliation Latency [$controller]` and `Controller Reconciliation Rate` with the spike from Steps 5 and 9. Pick controller `provisioner` / `nodeclaim.lifecycle` in the variable dropdown.

### Step 11 — Turn on debug logging (explicit values, then revert)
Same chart, same values file, same settings as the install script, plus `logLevel=debug`.
```bash
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --values manifests/03-install/karpenter-values.yaml \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "settings.interruptionQueue=${KARPENTER_QUEUE}" \
  --set logLevel=debug
kubectl -n kube-system rollout status deploy/karpenter --timeout=180s
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller --tail=-1 --since=2m \
  | jq -rR 'fromjson? | select(.level=="DEBUG") | .message' | sort | uniq -c | sort -rn | head -8
```
Expected: `Release "karpenter" has been upgraded. Happy Helming!`, rollout complete in ~12 s, then the startup DEBUG messages, one each: `discovered zones`, `discovered region`, `discovered offerings for instance types`, `discovered kube dns`, `discovered karpenter version`, `discovered instance types`, `discovered cluster endpoint`. Note: the restart resets all Karpenter counters in Prometheus.

Revert to `info`:
```bash
scripts/install-karpenter.sh
kubectl -n kube-system get deploy karpenter -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LOG_LEVEL")].value}{"\n"}'
```
Expected: install script output ending with the Karpenter pod `Running` (~20 s), then `info`.

### Step 12 — Production alert rules
A small, opinionated set. The Prometheus in this cluster picks up every PrometheusRule (no label selector).
```bash
kubectl apply -f manifests/12-observability/karpenter-alerts.yaml
for i in $(seq 30); do
  curl -s localhost:9090/api/v1/rules | jq -e '.data.groups[] | select(.name=="karpenter") | .rules[0].health=="ok"' >/dev/null && break; sleep 5
done
curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[] | select(.name=="karpenter") | .rules[] | "\(.name)  \(.state)"'
```
Expected: the loop ends after ~70 s (operator reload ~50 s, then first evaluation). Six rules, all `inactive`: `KarpenterControllerDown`, `KarpenterPodsUnschedulable`, `KarpenterNodePoolNearLimit`, `KarpenterLaunchFailures`, `KarpenterCloudProviderErrors`, `KarpenterNodeClaimsNotReady`. Module 13 (quota lab) will make `KarpenterLaunchFailures` fire.

## Talking points

- Karpenter is a controller: the truth is in **events and status conditions**; metrics give you rates and history; logs give you the reasoning.
- Watch three things in production: pods waiting for capacity (`scheduler_unschedulable_pods_count`, `pods_provisioning_startup_duration_seconds`), launch failures (`cloudprovider_instance_launch_failures_total` by `reason`), and distance to limits (`nodepools_usage / nodepools_limit`).
- `nodeclaims_disrupted_total` by `reason` tells you *why* nodes go away: `empty`, `underutilized`, `drifted`, `expired`, `spot_interrupted`, `insufficient_capacity`, `nodeclass_not_ready`.
- Logs are JSON on purpose. Pipe them to `jq` locally and to Loki / CloudWatch / OpenSearch in production, keyed on `NodeClaim.name`.
- Debug logging is for incidents. It restarts the controller and is verbose; set it, reproduce, revert.
- `cluster_utilization_percent` and the Capacity dashboard show bin-packing efficiency, which is where Karpenter saves money.

## Reset

```bash
kubectl delete -f manifests/12-observability/karpenter-alerts.yaml --ignore-not-found
kubectl -n demo scale deploy/inflate --replicas 0
scripts/install-karpenter.sh
scripts/reset.sh
```
Stop both port-forwards with Ctrl-C. (`install-karpenter.sh` is a no-op if `logLevel` is already `info`; `reset.sh` re-checks it too.)

## Q&A prep

- **Why not CloudWatch Container Insights?** Works for node / pod metrics, but Karpenter's own metrics are Prometheus. Use Amazon Managed Prometheus or the CloudWatch agent's Prometheus scraping if you want AWS-managed storage.
- **Do metric names change between versions?** Sometimes: 1.2 changed reason labels to snake_case, 1.3 renamed the ignored-pods metric, 1.7 renamed `pods_drained_total`. Pin dashboards to the Karpenter version and re-check on upgrade.
- **High-cardinality labels?** `karpenter_pods_state` has one series per pod; on big clusters drop it with `serviceMonitor.metricRelabelings`.
- **How do I see why a node was not consolidated?** Events with reason `Unconsolidatable` on the Node / NodeClaim, and `karpenter_voluntary_disruption_eligible_nodes`.
- **Is there a Karpenter CLI or kubectl plugin?** No official one. Use `kubectl get nodepools,nodeclaims,ec2nodeclasses -o wide` and `eks-node-viewer`.
- **What is `commit` in every log line?** The controller build commit; useful in support tickets.

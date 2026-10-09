# 04 — First scale-up
**Time:** 30 min · **Goal:** Watch Karpenter turn Pending pods into a right-sized spot node, scale further, then watch consolidation remove the nodes.

## What you'll show
- Scaling `inflate` from 0 to 5: Pending pods → NodeClaim → EC2 instance → Ready node → Running pods, in well under a minute.
- The NodeClaim lifecycle conditions `Launched`, `Registered`, `Initialized`, `Ready`, and the events and log lines behind each step.
- Which instance type Karpenter picked and why (bin-packing, spot first, price-capacity-optimized).
- Scaling to 10: existing free space is used first, then a second node.
- How the NodePool's `limits.cpu: 10` and the vCPU quota cap the cluster.
- Scaling to 0: empty nodes are removed by consolidation after `consolidateAfter: 1m`.

## Concepts

### The workload
`workloads/inflate.yaml`: a Deployment of `pause` containers, each requesting **500m CPU / 256Mi**, `terminationGracePeriodSeconds: 0`. It does nothing; it only reserves capacity. It does not tolerate `CriticalAddonsOnly`, so it can never use the system node.

### Capacity math (approximate)

Karpenter computes allocatable itself, before the node exists:

| | 2-vCPU node (e.g. `c6a.large`) | 4-vCPU node (e.g. `c6a.xlarge`) |
|---|---|---|
| vCPU | 2000m | 4000m |
| kube-reserved CPU (6% of core 1, 1% of core 2, 0.5% of cores 3–4) | 70m | 80m |
| **Allocatable CPU** | **1930m** | **3920m** |
| DaemonSet requests (aws-node 2×25m, kube-proxy 100m, node-exporter 10m, pod-identity-agent 0) | 160m | 160m |
| Free for `inflate` | 1770m → **3 pods** | 3760m → **7 pods** |

Memory is never the bottleneck here (256Mi per pod; kube-reserved memory with `maxPods: 110` is `11×110+255 = 1465Mi`). Measured: the 5-pod NodeClaim requested `cpu 2660m, memory 1312Mi, pods 9` (5 × 500m + 160m DaemonSets; 4 DaemonSet pods), and the `c6a.xlarge` reported allocatable `cpu 3920m`, `pods 110`.

So, expected shapes:

| `inflate` replicas | CPU requested | Expected Karpenter nodes | vCPU used (of limit 10) |
|---|---|---|---|
| 5 | 2500m | 1 × 4-vCPU | 4 |
| 10 | 5000m | 1 × 4-vCPU + 1 × 2-vCPU (7 + 3 pods; verified) | 6 |
| ~16–17 | 8000m+ | would reach the 10-vCPU limit (e.g. 4+4+2) | 10 |

We stop at 10 replicas in this module. Going further would also exceed the **8-vCPU spot quota**, which is module 13's controlled failure, not this one.

### Why this instance type?
1. **Bin-packing**: Karpenter adds pending pods to one NodeClaim until no allowed instance type could hold more. 5 × 500m plus DaemonSets does not fit any 2-vCPU type, so the NodeClaim lists only the 4-vCPU types that fit all 5.
2. **Candidates**: every type matching the NodePool (c/m/r, generation > 4, 2 or 4 vCPU, amd64) and big enough, cheapest first. The launch request to EC2 Fleet carries up to 60 of them across all three subnets/AZs.
3. **Spot first**: the NodePool allows `spot` and `on-demand`; Karpenter prefers spot.
4. **EC2 picks**: spot uses the `price-capacity-optimized` allocation strategy: among the deepest (least likely to be interrupted) pools, the cheapest. So it is often, but not always, the absolute cheapest type.

### NodeClaim lifecycle

| Condition | Meaning | Typical time after scale |
|---|---|---|
| `Launched` | EC2 instance created; type, zone and capacity type known | 2–5 s |
| `Registered` | kubelet joined; Karpenter synced labels/taints and removed `karpenter.sh/unregistered` | 15–30 s |
| `Initialized` | node `Ready`, startup taints gone, resources registered | 30–60 s |
| `Ready` | all of the above | 30–60 s |

Measured on this cluster (AL2023, spot): `c6a.xlarge` Launched +2 s, Registered +17 s, Initialized +31 s after the NodeClaim was created; `c8i-flex.large` +2 s / +17 s / +28 s. Note: EC2 boot time varies; allow up to ~90 s.

## Demo

Have the panes running: 1 `scripts/watch.sh nodes`, 2 `scripts/watch.sh claims`, 3 `scripts/watch.sh logs`. Optionally 4 `scripts/watch.sh pods`.

### Step 1 — Create the namespace and the workload
Idempotent; both may already exist from module 03's reset.
```bash
source scripts/env.sh
kubectl apply -f workloads/namespace.yaml -f workloads/inflate.yaml
kubectl get deploy -n demo
```
Expected: `namespace/demo created` (or `unchanged`), `deployment.apps/inflate created` (or `unchanged`), then `inflate 0/0 0 0`.

### Step 2 — Scale to 5
```bash
kubectl scale deployment inflate -n demo --replicas 5
kubectl get pods -n demo
```
Expected: five `inflate-...` pods `Pending`. About 2 s later pane 3 shows `found provisionable pod(s)`, `computed new nodeclaim(s) to fit pod(s)` (`"nodeclaims":1,"pods":5`), `created nodeclaim`, and ~2 s after that `launched nodeclaim`; pane 2 shows a NodeClaim `default-xxxxx` appear, with `TYPE`, `CAPACITY`, `ZONE` filled once it is launched.

### Step 3 — Why are they Pending, and what did Karpenter decide?
```bash
kubectl get events -n demo --sort-by=.lastTimestamp | grep -E 'FailedScheduling|Nominated' | tail -6
```
Expected: one `Warning FailedScheduling` line: `0/1 nodes are available: 1 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.`; then five `Normal Nominated` lines (one per pod): `Pod should schedule on: nodeclaim/default-xxxxx`.

### Step 4 — Wait for the node and the pods
Node launch to Ready took about 30 s here; allow up to 90 s.
```bash
kubectl wait nodeclaims --all --for=condition=Initialized --timeout=300s
kubectl rollout status deployment/inflate -n demo --timeout=300s
```
Expected: `nodeclaim.karpenter.sh/default-xxxxx condition met`, then `deployment "inflate" successfully rolled out`. The wait returned about 30 s after the scale. Pane 1 shows a new node with 5 pods and about 68% CPU allocated (`2660m/3920m`).

### Step 5 — Inspect the NodeClaim
```bash
kubectl get nodeclaims -o wide
kubectl get nodeclaim -o json | jq -r '.items[] | .metadata.name as $n | .status.conditions[] | [$n, .type, .status, .lastTransitionTime] | @tsv' | grep -E 'Launched|Registered|Initialized|Ready'
```
Expected: one row: `TYPE` a 4-vCPU type (we got `c6a.xlarge`), `CAPACITY spot`, a `ZONE`, `NODE ip-10-0-...`, `READY True`, plus `IMAGEID`, `ID aws:///ap-south-1x/i-...`, `NODEPOOL default`, `NODECLASS default`, `DRIFTED` empty. The condition timestamps show the lifecycle in order, e.g. Launched `16:19:07`, Registered `16:19:22`, Initialized and Ready `16:19:36` (NodeClaim created `16:19:05`).

### Step 6 — The full story in the logs
```bash
kubectl -n kube-system logs deploy/karpenter -c controller --since=10m | jq -rR 'fromjson? | select(.message | test("provisionable|computed new|created nodeclaim|launched nodeclaim|registered nodeclaim|initialized nodeclaim")) | [.time, .message, (."instance-types" // ."instance-type" // ""), (."capacity-type" // ""), (.zone // "")] | @tsv'
```
Expected, in order:
```text
<t>  found provisionable pod(s)
<t>  computed new nodeclaim(s) to fit pod(s)
<t>  created nodeclaim     c5.xlarge, c5a.xlarge, c5d.xlarge, c5n.xlarge, c6a.xlarge and 34 other(s)
<t>  launched nodeclaim    c6a.xlarge   spot   ap-south-1a
<t>  registered nodeclaim
<t>  initialized nodeclaim
```
`created nodeclaim` shows the first 5 candidates (alphabetical) and how many more: 39 4-vCPU types fit 5 pods. `launched nodeclaim` shows what EC2 actually gave us. Types and zone will differ.

### Step 7 — Node labels and the spot price
```bash
kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type,topology.kubernetes.io/zone
aws ec2 describe-spot-price-history --product-descriptions "Linux/UNIX" --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --instance-types "$(kubectl get nodes -l karpenter.sh/nodepool=default -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}')" --query 'SpotPriceHistory[].[InstanceType,AvailabilityZone,SpotPrice]' --output table
```
Expected: the system node (no NodePool label) plus one node with `NODEPOOL default`, `CAPACITY-TYPE spot`, its type and zone. The price table shows the current spot price per AZ for that type, typically well under half the on-demand price (`c6a.xlarge`: about $0.049–0.052/hour across the three AZs at validation time).

### Step 8 — Scale to 10
Free space on the existing node is used first; only the remainder triggers a launch.
```bash
kubectl scale deployment inflate -n demo --replicas 10
kubectl get pods -n demo -o wide
```
Expected: 2 new pods go `ContainerCreating` immediately on the existing node (it has room for 7). 3 stay `Pending`; pane 3 shows `computed new nodeclaim(s) to fit pod(s)` with `"nodeclaims":1,"pods":3` and `created nodeclaim` listing `c5.large, c5.xlarge, c5a.large, c5a.xlarge, c5d.large and 73 other(s)` (both 2- and 4-vCPU types fit 3 pods); EC2 picks a 2-vCPU spot type. We got `c8i-flex.large`; `c6a.large` or similar is equally likely.

### Step 9 — Wait, then look at NodePool usage against its limit
```bash
kubectl wait nodeclaims --all --for=condition=Initialized --timeout=300s
kubectl rollout status deployment/inflate -n demo --timeout=300s
kubectl get nodepool default -o wide
kubectl get nodepool default -o jsonpath='{.spec.limits.cpu}{" limit / "}{.status.resources.cpu}{" used vCPU\n"}'
```
Expected: two NodeClaims `condition met` (about 30 s after the scale), rollout complete, `NODES 2`, `CPU 6`, `MEMORY` in Ki (node capacity, e.g. `11828612Ki`) in the wide output, and `10 limit / 6 used vCPU`. Pods split 7 + 3 across the two nodes. Explain: `status.resources` counts the **capacity** of Karpenter's nodes, not pod requests. Another ~4 vCPU of nodes and Karpenter would stop with `all available instance types exceed limits for nodepool`. We do not do that here: 10 vCPU of spot is more than the 8-vCPU spot quota.

### Step 10 — Scale to 0 and watch consolidation
Empty nodes are removed after they have been unchanged for `consolidateAfter: 1m`.
```bash
kubectl scale deployment inflate -n demo --replicas 0
kubectl get pods -n demo
```
Expected: `No resources found in demo namespace.` almost immediately (grace period 0). After about 80 s (1m `consolidateAfter` plus validation), pane 3 shows `disrupting node(s)` with a command `Empty/<id>: delete: ...`, then `tainted node`, `deleted node`, `deleted nodeclaim`. The nodes go in separate decisions about 25 s apart; both were gone about 2 min 20 s after scaling to 0.

### Step 11 — Confirm we are back to one node
```bash
for i in $(seq 1 30); do [ -z "$(kubectl get nodeclaims -o name)" ] && break; sleep 10; done
kubectl get nodeclaims
kubectl get nodes -L karpenter.sh/nodepool
kubectl -n kube-system logs deploy/karpenter -c controller --since=10m | jq -rR 'fromjson? | select(.message | test("disrupting|deleted node|deleted nodeclaim")) | [.time, .message, (.command // "")] | @tsv'
```
Expected: the loop returns once the NodeClaims are gone (about 2–2.5 min), then `No resources found`, only the system node (empty `NODEPOOL`), and:
```text
<t>  disrupting node(s)  Empty/425808ec-...: delete: nodepools=[default]: [ip-10-0-11-31.ap-south-1.compute.internal] (savings: $0.05)
<t>  disrupting node(s)  Empty/2c53b8f7-...: delete: nodepools=[default]: [ip-10-0-42-53.ap-south-1.compute.internal] (savings: $0.02)
<t>  deleted node
<t>  deleted nodeclaim
<t>  deleted node
<t>  deleted nodeclaim
```
Savings are the hourly price of the deleted node.

## Talking points
- "From `kubectl scale` to a running pod on a brand-new spot instance: about 30 seconds here, and most of that is EC2 boot."
- "Karpenter made **one** decision for five pods because they arrived in the same batch window (1 s idle, 10 s max)."
- "Notice the NodeClaim had dozens of candidate instance types. We never wrote an instance type anywhere."
- "On the second scale-up Karpenter did not launch a big node: it used free space first and sized the new node for just the 3 leftover pods."
- "`limits.cpu` is counted on node capacity. It is your blast-radius and budget guard, and it is the only thing between a runaway Deployment and your EC2 bill."
- "Scale-down needs no extra component: empty nodes are consolidated after `consolidateAfter`, paced by disruption budgets."

## Reset
Return to BASELINE: `inflate` at 0 and no Karpenter nodes.
```bash
kubectl scale deployment inflate -n demo --replicas 0
for i in $(seq 1 30); do [ -z "$(kubectl get nodeclaims -o name)" ] && break; sleep 10; done
kubectl get nodeclaims
kubectl get deploy -n demo
```
Expected: `No resources found` for nodeclaims (about 2–3 min if nodes were still running), `inflate 0/0`. If a NodeClaim is still there after 5 minutes, check `kubectl describe nodeclaim` events for `Unconsolidatable`/`DisruptionBlocked`, or run `scripts/reset.sh`.

## Q&A prep
- **Why one 4-vCPU node and not two 2-vCPU nodes for 5 pods?** Karpenter packs a batch onto as few NodeClaims as possible; a single larger node also has less per-node overhead (DaemonSets, reserved resources).
- **Why spot?** The NodePool allows both; Karpenter launches spot when available and falls back to on-demand on capacity errors. For on-demand only, set `karpenter.sh/capacity-type In [on-demand]`.
- **Why did EC2 not pick the cheapest type in the list?** `price-capacity-optimized` trades a little price for deeper pools with lower interruption risk.
- **How long until an empty node is removed?** `consolidateAfter` (1m here, default 0s) plus a few seconds of validation, then drain and terminate. Budgets can slow it further.
- **What if pods arrive one by one over minutes?** Each batch (1 s idle, 10 s max) gets its own decision; consolidation later repacks if that leaves nodes underutilized.
- **Does Karpenter look at actual CPU usage?** No. Only pod **requests**. Pods without requests look free and lead to overpacking.
- **What happens at the limit?** Pods stay Pending; the log says `all available instance types exceed limits for nodepool`. Raise the limit or add another NodePool.

# 07 — Consolidation
**Time:** 35 min · **Goal:** Watch Karpenter delete and replace nodes to cut cost, and understand exactly when it will and will not.

## What you'll show
- **Delete** consolidation: scale `inflate` up to 2 nodes, scale down, watch one node go away.
- The three policies side by side: `WhenEmpty` refuses a half-used node (`Unconsolidatable` event), `WhenEmptyOrUnderutilized` acts, `Balanced` (new in v1.14) scores the move first.
- **Replace** consolidation: an on-demand 4-vCPU node running 2 small pods is swapped for a cheaper 2-vCPU node, replacement launched **before** the old one is drained.
- The exact log line (`disrupting node(s)`) and events (`DisruptionLaunching`, `DisruptionWaitingReadiness`, `DisruptionTerminating`, `Unconsolidatable`).
- Why spot nodes are only ever deleted, never replaced, unless `SpotToSpotConsolidation` is on.

## Concepts

### The loop
```text
every ~10 s (one action per loop, methods tried in order):
  Emptiness  ->  Drift  ->  Multi-node consolidation  ->  Single-node consolidation
for the chosen candidate(s):
  1. budget check (module 08)
  2. scheduling simulation: can every pod go elsewhere (+ at most ONE new, cheaper node)?
  3. emptiness/consolidation: wait 15 s, re-validate (cluster may have changed)
  4. log "disrupting node(s)", taint karpenter.sh/disrupted:NoSchedule
  5. replace?  -> create replacement NodeClaim, wait until it is Ready
  6. delete old NodeClaim -> drain (Eviction API, PDBs respected) -> terminate EC2
```

### Policies (`spec.disruption.consolidationPolicy`)
| Policy | Considers | Note |
|---|---|---|
| `WhenEmpty` | Only nodes whose pods all have zero disruption cost (DaemonSet-only, etc.) | Most conservative |
| `WhenEmptyOrUnderutilized` (default) | Any node that can be deleted or replaced to lower cost | Max savings, max churn |
| `Balanced` (v1.14.0+, no feature gate) | Like the default, but each move is **scored** and rejected if disruption outweighs savings | Middle ground |

**`Balanced` scoring** (core `balanced.go`, design `balanced-consolidation.md`):
```text
savings%     = (price of removed nodes - price of replacement) / total price of the NodePool
disruption%  = (1 per node + 1 per evicted pod) / same sum over every node in the NodePool
score        = savings% / disruption%           approved when score >= 1/k = 0.5  (k = 2, fixed)
```
- Every pod weighs 1.0 by default; `controller.kubernetes.io/pod-deletion-cost` and pod priority raise or lower it.
- Approved moves emit a `ConsolidationApproved` event: `score 1.20 >= threshold 0.50 (k: 2, savings 60.0%, disruption 50.0%)` (on Node + NodeClaim for single-node, on the NodePool for multi-node). Rejected moves emit **no event**: look at metrics `karpenter_consolidation_moves_total{decision="rejected"}` and `karpenter_consolidation_score`, or debug logs (`consolidation score`).
- Worked example with this module's replace demo: a 1-node pool, 4-vCPU → 2-vCPU, 2 pods. savings ≈ 50%, disruption = 100% (it is the only node) → score ≈ 0.5, right on the threshold. Within-family halving is exactly what k = 2 was tuned to allow.
- `WhenEmpty` and `WhenEmptyOrUnderutilized` behave as before.

### `consolidateAfter`
How long a node must be **stable** (no pod scheduled to or removed from it) before it becomes a candidate. Sets the NodeClaim condition `Consolidatable=True`. `Never` disables consolidation. Since v1.14 it also protects **destination** nodes: a node that just received pods is not used as a target until it has been stable that long. The base pool uses `1m`; this module's pool uses `30s`.

### Delete vs replace
- **Delete**: all pods fit on free space of other nodes.
- **Replace**: all pods fit on other nodes **plus exactly one new node that is cheaper** than what is removed. Karpenter never turns one node into two (`Can't remove without creating 2 candidates`).
- **Single-node** looks at each node alone. **Multi-node** tries to remove several nodes at once (optionally with one cheaper replacement). Empty nodes are handled first, in parallel.
- Candidate order (v1.14 changed it for all policies): highest savings per unit of disruption first.

### Spot rules
- Spot nodes: **delete** always works.
- Spot → spot **replace** requires `settings.featureGates.spotToSpotConsolidation=true` (alpha, off by default here). Without it, the node gets `Unconsolidatable`: `SpotToSpotConsolidation is disabled, can't replace a spot node with a spot node`.
- With the gate on, single-node spot→spot needs **at least 15** cheaper instance types than the current one (prevents "race to the bottom" onto the least-available pool). Multi-node has no such floor.
- On-demand → spot is allowed (if the pool allows spot), and Karpenter pins the replacement to spot so it never "falls back" to a pricier on-demand node.

### Why a node is NOT consolidated (events you will see)
| Where | Reason | Example message (from source) |
|---|---|---|
| Node + NodeClaim | `Unconsolidatable` | `NodePool "od-replace" has consolidation policy WhenEmpty, but node is not empty` |
| Node + NodeClaim | `Unconsolidatable` | `Can't replace with a cheaper node` |
| Node + NodeClaim | `Unconsolidatable` | `SpotToSpotConsolidation is disabled, can't replace a spot node with a spot node` |
| Node + NodeClaim | `DisruptionBlocked` | `Pod has "karpenter.sh/do-not-disrupt" annotation (Pod=demo/x)` / `Pdb prevents pod evictions (PodDisruptionBudget=[demo/x])` (module 08) |
| NodePool | `DisruptionBlocked` | `No allowed disruptions for disruption reason Underutilized due to blocking budget` (module 08) |

### Capacity plan
| Part | Pools active (sum of limits) | Peak vCPU |
|---|---|---|
| A: delete demo | `default` (10) | ≈ 6 spot |
| B: replace demo | `default` deleted, `od-replace` (6) | 4 + 2 on-demand during the replace = **exactly the 6 free on-demand vCPU** |

## Demo

Panes: `scripts/watch.sh nodes`, `scripts/watch.sh claims`, `scripts/watch.sh logs`.

### Step 1 — Part A: build two nodes
```bash
source scripts/env.sh
kubectl scale deployment inflate -n demo --replicas 10
kubectl rollout status deployment inflate -n demo --timeout=5m
kubectl get nodeclaims -o wide
```
Expected: in 30–45 s (measured 37 s), 2 NodeClaims from `default`, typically one 4-vCPU (7 pods) + one 2-vCPU (3 pods), usually `spot` (validation: `c6a.xlarge` + `c8i-flex.large`). `-o wide` adds `IMAGEID`, `ID`, `NODEPOOL`, `NODECLASS`, `DRIFTED`.

Note: run straight after a reset, one launch can fail with `MaxSpotInstanceCountExceeded` (spot instances still shutting down count against the 8-vCPU quota). Karpenter retries within seconds; the rollout just takes about 90 s.

### Step 2 — Scale down and watch a delete
```bash
kubectl scale deployment inflate -n demo --replicas 3
kubectl get nodeclaims -w
```
Expected: about 70 s after the scale-down (`consolidateAfter: 1m` + loop + 15 s validation) the 4-vCPU NodeClaim gets a deletion timestamp and is gone about 30 s later (measured 68 s / 100 s). This is a **delete**, no replacement. Ctrl-C when one NodeClaim remains.

Note: the ReplicaSet removes pods from the node with the most replicas first, so all 7 pods on the 4-vCPU node are killed and it becomes **empty**. Karpenter therefore logs it as `Empty`, not `Underutilized`. With a 7 + 3 split this is what you will see.

### Step 3 — The log line
```bash
kubectl logs -n "$KARPENTER_NAMESPACE" deploy/karpenter -c controller --since=5m \
  | jq -rR 'fromjson? | select(.message=="disrupting node(s)") | [.time, .command, .decision, ."pod-count"] | @tsv'
```
Expected (real output):
```text
2026-10-09T16:59:27.449Z  Empty/2b3dae15-...: delete: nodepools=[default]: [ip-10-0-44-221.ap-south-1.compute.internal] (savings: $0.05)  delete  0
```
If the split was different you may see `Underutilized/...: delete: ...` with a non-zero pod-count. Fields: `<reason>/<command-id>: <decision>: nodepools=[...]: [nodes] (savings: $X)`. Savings are per hour.

### Step 4 — Why the last node stays
```bash
kubectl get events -A --field-selector reason=Unconsolidatable --sort-by=.lastTimestamp | tail -2
```
Expected: `SpotToSpotConsolidation is disabled, can't replace a spot node with a spot node` on the remaining node and its NodeClaim. Validation saw this even on the 2-vCPU `c8i-flex.large` survivor: a cheaper 2-vCPU spot type existed. If no cheaper type exists you see `Can't replace with a cheaper node`. Older lines from module 06 nodes may also appear higher up. Either way: spot is deleted, never replaced, in this cluster.

### Step 5 — Part B setup: an on-demand pool that starts as WhenEmpty
Remove `default` (re-applied in Reset) so the sum of limits stays ≤ 12, then create `od-replace` with `consolidationPolicy: WhenEmpty`.
```bash
kubectl scale deployment inflate -n demo --replicas 0
kubectl delete nodepool default
kubectl wait nodeclaims --all --for=delete --timeout=300s
kubectl apply -f manifests/07-consolidation/od-replace-whenempty.yaml -f manifests/07-consolidation/replace-app.yaml
kubectl rollout status deployment replace-app -n demo --timeout=5m
kubectl get nodeclaims
```
Expected: `default` and its NodeClaim deleted (about 40 s). Then one `od-replace-xxxxx` NodeClaim, `on-demand`, a **4-vCPU** type (6 pods × 500m + DaemonSets needs > 1.8 CPU), `c6a.xlarge`. Rollout in 30–45 s (measured 34 s).

### Step 6 — Shrink the workload: WhenEmpty refuses
```bash
kubectl scale deployment replace-app -n demo --replicas 2
sleep 45
kubectl get events -A --field-selector reason=Unconsolidatable --sort-by=.lastTimestamp | tail -2
kubectl get nodeclaims
```
Expected: `NodePool "od-replace" has consolidation policy WhenEmpty, but node is not empty` on the Node and the NodeClaim. The 4-vCPU node stays, now ~75% idle. That is the cost of the conservative policy.

### Step 7 — Switch to WhenEmptyOrUnderutilized: replace
Policy is a behavioural field: changing it does not drift the node.
```bash
kubectl apply -f manifests/07-consolidation/od-replace-pool.yaml
kubectl get nodeclaims -w
```
Expected timeline (about 1.5 min total, measured):
1. ~20 s: a **second** NodeClaim appears (2-vCPU on-demand, `c6a.large`). The old node is tainted `karpenter.sh/disrupted:NoSchedule`.
2. ~50 s: the new NodeClaim is `Ready`, and the old one gets its deletion timestamp in the same second.
3. ~90 s: the old NodeClaim is gone: pods were evicted, rescheduled onto the new node, the instance terminated.

Ctrl-C when one NodeClaim (the 2-vCPU one) remains. On-demand peak was 4 + 2 = 6 vCPU, exactly the free quota.

### Step 8 — The evidence
```bash
kubectl logs -n "$KARPENTER_NAMESPACE" deploy/karpenter -c controller --since=5m \
  | jq -rR 'fromjson? | select(.message=="disrupting node(s)") | [.command, (."replacement-nodes"|tostring)] | @tsv'
kubectl get events -A --sort-by=.lastTimestamp \
  --field-selector involvedObject.kind=NodeClaim | grep -E 'Disruption|Consolidation' | tail -6
```
Expected:
- Log: `Underutilized/<id>: replace: nodepools=[od-replace]: [ip-10-0-17-88.ap-south-1.compute.internal] -> [1 replacement] (savings: $0.05)` and replacement-nodes `[{"capacity-type":"on-demand","instance-types":"c6a.large, c5a.large, m6a.large, m5a.large, m5ad.large and 8 other(s)"}]` (cheapest first).
- Events (NodeClaims live in namespace `default`):
  - `ConsolidationCandidate` on the old NodeClaim: `Consolidation candidate: replace: [ip-10-0-17-88...] -> [1 replacement] (savings: $0.05)`
  - `DisruptionLaunching` on the new NodeClaim: `Launching NodeClaim: Underutilized`
  - `DisruptionWaitingReadiness` on the new NodeClaim: `Waiting on readiness to continue disruption`
  - `DisruptionTerminating` on the old NodeClaim: `Disrupting NodeClaim: Underutilized`
  - Two harmless `DisruptionBlocked` lines also show: `Nodeclaim does not have an associated node` (new one, before it registers) and `Node is deleting or marked for deletion` (old one). Afterwards the new NodeClaim gets `Unconsolidatable`: `Can't replace with a cheaper node`.

### Step 9 — Balanced exists, and how to read it
We do not run a live Balanced move (with a 1-node pool the score sits right on the 0.5 threshold, so the outcome depends on live prices). Show the API and the dry-run instead.
```bash
kubectl explain nodepool.spec.disruption.consolidationPolicy
kubectl apply --dry-run=server -f manifests/07-consolidation/balanced-example.yaml
```
Expected: the explain output lists `Valid values: "WhenEmpty", "WhenEmptyOrUnderutilized", "Balanced".` and `ENUM: WhenEmpty, WhenEmptyOrUnderutilized, Balanced`. Dry run: `nodepool.karpenter.sh/balanced-example created (server dry run)`. Walk through the score formula in Concepts using Step 7's numbers.

## Talking points
- Consolidation is Karpenter's cost engine: provisioning picks the cheapest node *now*, consolidation keeps it cheapest *over time*.
- Replace is make-before-break: the new node is Ready before the old one is drained. Budget your quotas and limits for that extra node.
- `WhenEmpty` is safe but leaves money on the table. `WhenEmptyOrUnderutilized` saves the most and moves pods the most. `Balanced` asks "is this move worth it?"
- `consolidateAfter` is your churn dial: longer = calmer clusters, slower savings.
- Spot is deleted, not replaced, by default: Karpenter will not chase cheaper spot pools unless you opt in, and then only with ≥ 15 cheaper options.
- Every "no" has a reason: look for `Unconsolidatable` and `DisruptionBlocked` events before opening a ticket.
- Pods are evicted through the Eviction API, so PDBs and `terminationGracePeriodSeconds` are respected. Make your apps tolerate restarts.

## Reset
```bash
source scripts/env.sh
kubectl delete -f manifests/07-consolidation/replace-app.yaml --ignore-not-found
kubectl scale deployment inflate -n demo --replicas 0
kubectl delete nodepool od-replace --ignore-not-found
kubectl wait nodeclaims --all --for=delete --timeout=300s
kubectl apply -f manifests/base/nodepool.yaml
bash scripts/reset.sh
```
Expected: `nodepool/default` back, no NodeClaims, only `inflate` (0) in `demo`.

## Q&A prep
- **Why did it take ~2 minutes and not instantly?** `consolidateAfter` (1m / 30s) + the 10 s loop + a 15 s re-validation + node launch for replaces.
- **Will consolidation ever increase my cost?** Not intentionally: replace requires a strictly cheaper node; delete always saves. Prices are Karpenter's estimates (spot prices move).
- **Can I stop consolidation for one workload?** `karpenter.sh/do-not-disrupt: "true"` on the pod, or a PDB (module 08). For a whole pool: `consolidateAfter: Never`, or a budget `nodes: "0"`.
- **Does consolidation move pods to the system node group?** It can use any node the pods fit on, Karpenter-managed or not. Here the system node is tainted `CriticalAddonsOnly`, so `inflate` cannot go there.
- **Does Balanced need a feature gate?** No. It is a plain enum value since v1.14.0. Only the score metrics are marked alpha.
- **What changed in v1.14 for everyone?** Candidate ordering for consolidation changed for all policies (savings-per-disruption first), and `consolidateAfter` now also protects destination nodes.
- **Preferred anti-affinity and consolidation?** They can block it; Karpenter logs `pod(s) have a preferred Anti-Affinity which can prevent consolidation`.
- **Is multi-node consolidation ever replace?** Yes: N nodes → 1 cheaper node is allowed, never N → 2.

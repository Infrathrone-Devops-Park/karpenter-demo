# 08 — Disruption controls
**Time:** 30 min · **Goal:** Show every lever that slows or stops Karpenter from disrupting nodes, and the one that forces it through anyway.

## What you'll show
- A NodePool disruption **budget** of `nodes: "0"` freezing consolidation, with the `DisruptionBlocked` event, then a per-reason budget unfreezing it.
- A schedule-based budget (cron + duration), validated by the API server, explained, not waited for.
- Pod annotation `karpenter.sh/do-not-disrupt: "true"` blocking voluntary disruption, and the duration form (`"10m"`, v1.12+).
- `terminationGracePeriod` on the NodePool forcing a stuck drain to finish.
- A PodDisruptionBudget blocking disruption, and the node-level `do-not-disrupt` annotation.

## Concepts

### Voluntary vs forceful
| Method | Class | Budgets apply | PDB / do-not-disrupt respected |
|---|---|---|---|
| Consolidation (Empty, Underutilized) | voluntary, graceful | yes | yes, node is skipped |
| Drift | voluntary, graceful ("eventual") | yes | yes, **unless** the NodePool sets `terminationGracePeriod` |
| Expiration (`expireAfter`) | forceful | **no** | drain waits for them, until `terminationGracePeriod` |
| Interruption (spot, health) | forceful | no | best effort before the instance dies |
| Manual (`kubectl delete node/nodeclaim`) | forceful | no | drain waits, until `terminationGracePeriod` |

### Budgets (`spec.disruption.budgets[]`)
```yaml
budgets:
  - nodes: "10%"            # default when unset: one budget of 10%
  - nodes: "0"              # count or percentage; "0" = frozen
    reasons: ["Drifted"]    # Underutilized | Empty | Drifted; omit = all reasons
    schedule: "30 3 * * mon-fri"   # cron, ALWAYS UTC, needs duration
    duration: 8h            # how long it is active after each schedule hit
```
- Allowed disruptions = `roundup(nodes_in_pool × %)` (or the count) **minus** nodes already being disrupted or NotReady. With several active budgets, the **most restrictive** wins, per reason.
- `nodes` counts **NodeClaims terminating at the same time**, not "per hour".
- Budgets never stop expiration, interruption or manual deletion.
- When blocked, Karpenter emits on the NodePool: `DisruptionBlocked` `No allowed disruptions for disruption reason <Reason> due to blocking budget` (only while the pool has nodes and that method has candidates).

### Pod and node controls
- **Pod annotation `karpenter.sh/do-not-disrupt: "true"`**: the node is skipped by consolidation, and by drift unless `terminationGracePeriod` is set. During any drain, Karpenter does not evict that pod.
- **Duration form (v1.12+)**: `karpenter.sh/do-not-disrupt: "30m"` protects the pod for 30 min **after the pod started**. Events on the pod: `DoNotDisruptUntil` (`The karpenter.sh/do-not-disrupt grace period will elapse at <RFC3339>`), later `DoNotDisruptGracePeriodElapsed`. Invalid values (`"abc"`, `"-5m"`) are ignored with a `InvalidDoNotDisruptAnnotation` warning.
- **Node annotation `karpenter.sh/do-not-disrupt: "true"`**: the whole node is excluded from voluntary disruption.
- **PDBs**: a node is only a voluntary candidate if every PDB covering its pods currently allows at least one disruption. Eviction then goes through the Eviction API, one pod at a time as the PDB allows.
- Events on the Node and NodeClaim when a node is excluded (`DisruptionBlocked`, exact text from source):
  - `Pod has "karpenter.sh/do-not-disrupt" annotation (Pod=demo/precious-...)`
  - `Pdb prevents pod evictions (PodDisruptionBudget=[demo/pdb-app])`
  - `Disruption is blocked through the "karpenter.sh/do-not-disrupt" annotation`
  - `Node is nominated for a pending pod`

### terminationGracePeriod (TGP) vs pod `terminationGracePeriodSeconds`
```text
NodeClaim deleted at T  (TGP = 2m on the NodePool)
 ├─ node tainted karpenter.sh/disrupted:NoSchedule, drain starts
 ├─ evictable pods: evicted via Eviction API (PDBs respected)
 ├─ do-not-disrupt pods / PDB-blocked pods: WAIT ...
 ├─ at T + TGP - pod.terminationGracePeriodSeconds: pod is DELETED (bypasses PDB + annotation)
 │     so the pod still gets its full graceful shutdown before T + TGP
 └─ at T + TGP: instance terminated regardless
```
Max node lifetime = `expireAfter` + `terminationGracePeriod`. The docs recommend: if you use `do-not-disrupt` with `expireAfter`, also set `terminationGracePeriod`, otherwise a node can be stuck draining forever.

### Capacity plan
`default` is removed for this module; only `budget-demo` exists (2-vCPU types only, `limits.cpu: 4`, `terminationGracePeriod: 2m`, `consolidateAfter: 30s`). Peak: 2 nodes × 2 vCPU during the forced-drain step.

## Demo

Panes: `scripts/watch.sh claims`, `scripts/watch.sh logs`, `scripts/watch.sh pods`.

### Step 1 — Swap in the frozen pool
```bash
source scripts/env.sh
kubectl delete nodepool default
kubectl apply -f manifests/08-disruption/budget-demo-pool.yaml
kubectl get nodepool budget-demo -o jsonpath='{.spec.disruption}{"\n"}{.spec.template.spec.terminationGracePeriod}{"\n"}'
```
Expected: `{"budgets":[{"nodes":"0"}],"consolidateAfter":"30s","consolidationPolicy":"WhenEmptyOrUnderutilized"}` then `2m`.

### Step 2 — Make a node, then make it empty
```bash
kubectl scale deployment inflate -n demo --replicas 3
kubectl rollout status deployment inflate -n demo --timeout=5m
kubectl scale deployment inflate -n demo --replicas 0
sleep 60
kubectl get nodeclaims
kubectl get events -A --field-selector involvedObject.kind=NodePool,reason=DisruptionBlocked --sort-by=.lastTimestamp | tail -2
```
Expected: one 2-vCPU NodeClaim (3 pods, e.g. `c8i-flex.large` spot), rollout in 30–45 s (measured 34 s). After scale-to-0 and 60 s, the empty node is **still there**. Event on `nodepool/budget-demo`: `No allowed disruptions for disruption reason Empty due to blocking budget` (repeats about once a minute).

### Step 3 — Unfreeze with a per-reason budget
Allow 1 node at a time for `Empty` and `Underutilized`, keep `Drifted` frozen.
```bash
kubectl patch nodepool budget-demo --type merge -p '{"spec":{"disruption":{"budgets":[{"nodes":"1","reasons":["Empty","Underutilized"]},{"nodes":"0","reasons":["Drifted"]}]}}}'
kubectl get nodeclaims -w
```
Expected: within ~20 s (next loop + 15 s re-validation) the NodeClaim gets a deletion timestamp; gone about 35 s later (measured 21 s / 56 s). Log: `disrupting node(s)` with command `Empty/<id>: delete: nodepools=[budget-demo]: [ip-10-0-41-149.ap-south-1.compute.internal] (savings: $0.02)`. Ctrl-C when the list is empty.

### Step 4 — A schedule-based budget (validated, not waited for)
```bash
kubectl apply --dry-run=server -f manifests/08-disruption/budget-schedule-example.yaml
```
Expected: `nodepool.karpenter.sh/budget-schedule-example created (server dry run)`. Walk the three budgets: empties all at once; otherwise 1 node at a time; and **zero** voluntary `Underutilized`/`Drifted` disruptions from 03:30 UTC (09:00 IST) for 8 h on weekdays. Point out: cron is UTC only, `schedule` and `duration` must be set together (CEL rule `'schedule' must be set with 'duration'`).

### Step 5 — A do-not-disrupt pod
```bash
kubectl apply -f manifests/08-disruption/precious.yaml
kubectl rollout status deployment precious -n demo --timeout=5m
for i in $(seq 30); do kubectl get events -A --field-selector reason=DisruptionBlocked,involvedObject.kind=Node | grep 'annotation (Pod=' && break; sleep 10; done
```
Expected: a new 2-vCPU node, rollout in 30–45 s (measured 33 s). The loop then prints, after 1.5–2 min (the node must first be `Consolidatable`, 30 s after its last pod change, and these events are rate-limited): `Pod has "karpenter.sh/do-not-disrupt" annotation (Pod=demo/precious-678f858c8f-blqmz)`. Talk through the annotation while it waits. Earlier `DisruptionBlocked` lines such as `Node isn't initialized` or `Nodeclaim does not have an associated node` are normal for a brand-new node.

Note: events live 1 h. If you rehearsed within the last hour, these loops can match an old event at once: check `LAST SEEN`.

### Step 6 — Force it: manual delete + terminationGracePeriod
Manual deletion is not stopped by the annotation, but the drain is: Karpenter will not evict the pod. The pool's `terminationGracePeriod: 2m` ends the standoff.
```bash
kubectl delete nodeclaims -l karpenter.sh/nodepool=budget-demo --wait=false
sleep 20
kubectl get events -A --sort-by=.lastTimestamp | grep -E 'FailedDraining|TerminationGracePeriodExpiring' | tail -3
OLD=$(kubectl get pods -n demo -l app=precious -o name); echo "$OLD"
kubectl wait -n demo "$OLD" --for=delete --timeout=3m
kubectl get events -n demo --field-selector reason=Disrupted --sort-by=.lastTimestamp | tail -1
```
Expected:
- `TerminationGracePeriodExpiring` (Warning) on the NodeClaim and Node: `All pods will be deleted by <T+2m>`.
- `FailedDraining` on the Node: `Failed to drain node, 1 pods are waiting to be evicted` (DaemonSet pods that tolerate the disrupted taint are not counted).
- About 90 s after the delete (2 m TGP minus the pod's 30 s `terminationGracePeriodSeconds`) the pod is deleted (measured exactly 90 s). Pod event `Disrupted`: `Deleting the pod to accommodate the terminationTime 2026-10-09 17:19:16 +0000 UTC of the node. The pod was granted 29 seconds of grace-period of its 30 terminationGracePeriodSeconds. This bypasses the PDB of the pod and the do-not-disrupt annotation.` (29 or 30 depending on loop timing).
- The Deployment recreates the pod; it is Pending until a new node is Ready (measured ~27 s). The new node launches while the old one finishes terminating: 2 nodes × 2 vCPU = 4 = pool limit.

### Step 7 — Time-boxed protection (duration form)
Overwrite the annotation on the new pod with a duration.
```bash
kubectl rollout status deployment precious -n demo --timeout=5m
kubectl annotate pods -n demo -l app=precious karpenter.sh/do-not-disrupt=10m --overwrite
sleep 30
kubectl get events -n demo --field-selector reason=DoNotDisruptUntil --sort-by=.lastTimestamp | tail -1
```
Expected (event arrives ~17 s after the annotate): `The karpenter.sh/do-not-disrupt grace period will elapse at 2026-10-09T17:29:13Z` = pod `status.startTime` (17:19:13) + 10 min. After that time the pod is disruptable again and the event `DoNotDisruptGracePeriodElapsed` appears. Use case: protect a batch job or a cache warm-up window, not forever.

### Step 8 — PodDisruptionBudget
`pdb-app`: 2 replicas, PDB `minAvailable: 2` (so `disruptionsAllowed: 0`). Put it on the same node, then remove `precious` so the PDB is the only blocker.
```bash
kubectl apply -f manifests/08-disruption/pdb-app.yaml
kubectl rollout status deployment pdb-app -n demo --timeout=5m
kubectl delete -f manifests/08-disruption/precious.yaml
kubectl get pdb -n demo
for i in $(seq 30); do kubectl get events -A --field-selector reason=DisruptionBlocked,involvedObject.kind=Node | grep 'Pdb prevents' && break; sleep 10; done
```
Expected: `pdb-app` pods schedule on the existing node (room for 3 × 500m). `kubectl get pdb`: `pdb-app   2   N/A   0`. After about 70 s the loop prints `Pdb prevents pod evictions (PodDisruptionBudget=[demo/pdb-app])`.

### Step 9 — Relax the PDB
```bash
kubectl patch pdb pdb-app -n demo --type merge -p '{"spec":{"minAvailable":1}}'
kubectl get pdb -n demo
```
Expected: `ALLOWED DISRUPTIONS 1`. The `Pdb prevents pod evictions` events stop. The node is a normal candidate again (nothing cheaper exists for 2 pods on a 2-vCPU node, so it stays).

### Step 10 — Node-level opt-out
```bash
kubectl annotate nodes -l karpenter.sh/nodepool=budget-demo karpenter.sh/do-not-disrupt=true
for i in $(seq 30); do kubectl get events -A --field-selector reason=DisruptionBlocked,involvedObject.kind=Node | grep 'blocked through' && break; sleep 10; done
```
Expected: after about 2 min (measured 1 min 50 s) the loop prints `Disruption is blocked through the "karpenter.sh/do-not-disrupt" annotation`. Use case: an operator freezing one node during an investigation.

## Talking points
- Budgets are **rate limits** for voluntary disruption, per pool, per reason, optionally per time window. `nodes: "0"` is the big red button.
- Schedules are cron in **UTC**. Write the IST conversion next to every schedule in Git.
- `do-not-disrupt` is for pods that must not be interrupted (long batch jobs, stateful leaders). The duration form stops it becoming permanent by accident.
- PDBs protect availability for all voluntary actions, Karpenter's and yours. A PDB with `minAvailable` equal to replicas (or `maxUnavailable: 0`) blocks every node it touches.
- `terminationGracePeriod` is the safety valve: without it a stuck drain can last forever; with it, drift and expiration always finish. It is the node-level cousin of the pod's `terminationGracePeriodSeconds`, which Karpenter still honours.
- Expiration and interruption ignore budgets: they are forceful by design.

## Reset
```bash
source scripts/env.sh
kubectl delete -f manifests/08-disruption/precious.yaml -f manifests/08-disruption/pdb-app.yaml --ignore-not-found
kubectl scale deployment inflate -n demo --replicas 0
kubectl delete nodepool budget-demo --ignore-not-found
kubectl wait nodeclaims --all --for=delete --timeout=300s
kubectl apply -f manifests/base/nodepool.yaml
bash scripts/reset.sh
```
Expected: `budget-demo` and its nodes gone (no blockers left: PDB and pods deleted first; the node annotation leaves with the node), `default` restored, `demo` holds only `inflate` (0). The logs pane may show a few `Reconciler error` lines `NodePool.karpenter.sh "budget-demo" not found` while the last NodeClaim terminates: harmless.

## Q&A prep
- **Do budgets limit how fast new nodes are launched?** No. They only limit voluntary disruption. Provisioning is limited by `limits`.
- **`nodes: "10%"` with 3 nodes: how many at once?** `roundup(3 × 0.1) = 1`.
- **Does a NotReady node count against the budget?** Yes: allowed = budget − nodes already deleting − NotReady nodes.
- **What if the annotation value is invalid, e.g. `"forever"`?** It is ignored (pod treated as disruptable) and a Warning event `InvalidDoNotDisruptAnnotation` is emitted on the pod.
- **Is the duration measured from when I annotated?** No, from the pod's `status.startTime`.
- **Does do-not-disrupt stop spot interruptions?** No. Nothing can; AWS reclaims the instance after 2 minutes.
- **Two PDBs match one pod?** Eviction is impossible; Karpenter reports `Eviction does not support multiple PDBs (PodDisruptionBudget(s)=[...])`.
- **Can I see allowed disruptions as a metric?** Yes: `karpenter_nodepools_allowed_disruptions{nodepool,reason}`.

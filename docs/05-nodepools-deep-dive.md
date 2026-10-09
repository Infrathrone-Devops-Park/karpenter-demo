# 05 — NodePools deep dive
**Time:** 35 min · **Goal:** Read every NodePool field with confidence, then use weights, taints, limits and requirements to shape where capacity comes from.

## What you'll show
- The full anatomy of a NodePool, validated against the live CRD with a server-side dry run.
- Two weighted pools, `spot-first` (weight 50) and `on-demand-fallback` (weight 10): the higher weight always wins, and the lower one only catches what the first cannot take.
- Limits in action: both pools hit `limits.cpu`, the overflow stays `Pending`, `status.resources` shows why, and Karpenter says `all available instance types exceed limits for nodepool`.
- A dedicated, tainted team pool: only pods with the toleration and the label land there; everyone else is refused with `did not tolerate taint`.
- Requirement selectors on well-known labels (`instance-family`, `instance-size`, `capacity-type`, zone) plus `minValues: 3` for spot flexibility.

## Concepts

### Capacity plan for this module (read before presenting)
The base `default` pool (limit 10) is **deleted** at the start and re-applied in Reset. Without that, the extra pools would push the sum of active limits above 12. With it removed, the module never exceeds the quotas:

| Pools alive at the same time | Sum of `limits.cpu` | Worst-case vCPU actually launched |
|---|---|---|
| Steps 3–7: `spot-first` 4 + `on-demand-fallback` 2 | 6 | 4 spot + 2 on-demand |
| Steps 8–10: `team-batch` 4 + `selectors-demo` 4 | 8 | 2 on-demand + 2 spot (worst case 4 + 4) |

On-demand never goes above 4 vCPU (6 free). Spot never goes above 4 vCPU (8 free).

### Anatomy

```text
NodePool
├── spec.template                      -> becomes each NodeClaim (drift-relevant)
│   ├── metadata.labels / annotations  -> copied onto every Node
│   └── spec
│       ├── nodeClassRef               -> which EC2NodeClass (AMI, subnets, SGs, role)
│       ├── requirements[]             -> In/NotIn/Exists/DoesNotExist/Gt/Lt/Gte/Lte (+ minValues)
│       ├── taints[]                   -> pods must tolerate them
│       ├── startupTaints[]            -> expected to be removed by an agent; pods need not tolerate
│       ├── expireAfter                -> forceful max node age (default 720h, or Never)
│       └── terminationGracePeriod     -> max drain time before pods are force-deleted
├── spec.limits                        -> cpu / memory / nodes cap (checked against status.resources)
├── spec.weight                        -> 1–100, higher is tried first (unset = 0)
└── spec.disruption                    -> consolidationPolicy, consolidateAfter, budgets[]
```

Key rules (Karpenter v1.14.1):
- **`template.metadata.labels`** cannot use the `karpenter.sh` or `karpenter.k8s.aws` domains, nor `kubernetes.io/hostname`. A custom label here (for example `team: batch`) makes a pod `nodeSelector` on it schedulable by Karpenter.
- **`requirements`** combine with the pod's own constraints. A pod can only narrow a pool, never widen it. Well-known labels you can use: `karpenter.sh/capacity-type` (`spot`, `on-demand`, `reserved`), `topology.kubernetes.io/zone`, `node.kubernetes.io/instance-type`, `kubernetes.io/arch`, and the AWS `karpenter.k8s.aws/instance-*` family (`-category`, `-family`, `-generation`, `-size`, `-cpu`, `-memory`, …).
- **`minValues`** (alpha field, 1–50): the launch request must keep at least N distinct values of that key. With `instance-family` `minValues: 3`, every spot launch offers EC2 at least 3 families, so one exhausted spot pool cannot strand you. The default `--min-values-policy` is `Strict`: if it cannot be met, the pool is not used.
- **`limits`** count the *capacity* of every node in the pool (a 2-vCPU node uses 2 of `cpu`, whatever its pods request). Checked before each launch, eventually consistent, so a burst can overshoot slightly.
- **`weight`**: pools are tried from highest weight down. Docs recommend making pools mutually exclusive, or using weight for "prefer this, fall back to that".
- **`expireAfter`** and **`terminationGracePeriod`** live under `template.spec`, so changing them drifts existing nodes (module 09). `weight`, `limits` and `disruption` are behavioural: changing them never drifts nodes.

### Capacity-type preference inside one pool
When one pool allows several capacity types, Karpenter prefers **reserved > spot > on-demand**. Weighted pools are how you make that choice explicit and cap each side separately, which is what this module does.

## Demo

Keep panes 1–3 running (`scripts/watch.sh nodes`, `claims`, `logs`).

### Step 1 — Remove the default pool for this module
Keeps total active limits within budget. At BASELINE it has no nodes, so nothing is disrupted.
```bash
source scripts/env.sh
kubectl delete nodepool default
kubectl get nodepools
```
Expected: `nodepool.karpenter.sh "default" deleted`, then `No resources found`.

### Step 2 — Tour the anatomy with a server-side dry run
Validates every field against the real CRD and its CEL rules, without creating anything.
```bash
kubectl apply --dry-run=server -f manifests/05-nodepools/nodepool-anatomy.yaml
kubectl explain nodepool.spec.template.spec.requirements.minValues
```
Expected: `nodepool.karpenter.sh/anatomy created (server dry run)`. `kubectl explain` prints `FIELD: minValues <integer>` and the description ("This field is ALPHA and can be dropped or replaced at any time", "MinValues is the minimum number of unique values required to define the flexibility of the specific requirement."). Walk the file top to bottom using the anatomy diagram above.

### Step 3 — Create two weighted pools
`spot-first` (weight 50, spot, 2-vCPU types only, limit 4) and `on-demand-fallback` (weight 10, on-demand, 2-vCPU only, limit 2). Restricting both to 2-vCPU types makes the packing predictable: 3 inflate pods per node.
```bash
kubectl apply -f manifests/05-nodepools/weighted-pools.yaml
kubectl get nodepools -o wide
```
Expected (`-o wide` adds Weight/CPU/Memory; both show `0` until a node exists):
```text
NAME                 NODECLASS   NODES   READY   AGE   WEIGHT   CPU   MEMORY
on-demand-fallback   default     0       True    0s    10       0     0
spot-first           default     0       True    0s    50       0     0
```

### Step 4 — Small scale: the heavier pool wins
```bash
kubectl scale deployment inflate -n demo --replicas 3
kubectl rollout status deployment inflate -n demo --timeout=5m
kubectl get nodes -l karpenter.sh/nodepool -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type,topology.kubernetes.io/zone
```
Expected: rollout completes in 30–60 s (measured 33 s). One node, `NODEPOOL=spot-first`, `CAPACITY-TYPE=spot`, a 2-vCPU type such as `c8i-flex.large` (picked in validation), `c6a.large` or `m6a.large`. `on-demand-fallback` was never considered because `spot-first` (weight 50) could hold all 3 pods.

### Step 5 — Scale past both limits
12 pods × 500m. `spot-first` can grow to 4 vCPU (2 nodes, 6 pods), `on-demand-fallback` to 2 vCPU (1 node, 3 pods), so 3 pods must stay Pending.
```bash
kubectl scale deployment inflate -n demo --replicas 12
kubectl wait deployment inflate -n demo --for=jsonpath='{.status.readyReplicas}'=9 --timeout=5m
kubectl get pods -n demo --field-selector=status.phase=Pending
kubectl get nodes -l karpenter.sh/nodepool -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
```
Expected: about 30–60 s to 9 ready (measured 36 s). 3 pods `Pending`. Nodes: 2 × `spot-first` (`spot`, e.g. `c8i-flex.large`) + 1 × `on-demand-fallback` (`on-demand`, e.g. `c6a.large`), all 2-vCPU types. Both new nodes launch in the same batch.

### Step 6 — Why are 3 pods still Pending? Limits.
```bash
kubectl get nodepools -o wide
kubectl get nodepool spot-first -o jsonpath='{.spec.limits}{"\n"}{.status.resources}{"\n"}'
kubectl get events -n demo --field-selector reason=FailedScheduling,source=karpenter --sort-by=.lastTimestamp | tail -3
kubectl logs -n "$KARPENTER_NAMESPACE" deploy/karpenter -c controller --since=5m \
  | jq -rR 'fromjson? | select(.message=="could not schedule pod") | .error' | sort -u
```
Expected:
- `kubectl get nodepools -o wide`: `spot-first` NODES 2, CPU `4`; `on-demand-fallback` NODES 1, CPU `2`.
- `{"cpu":"4"}` then a status like `{"cpu":"4","ephemeral-storage":"41787352Ki","hugepages-1Gi":"0","hugepages-2Mi":"0","memory":"7815052Ki","nodes":"2","pods":"220","vpc.amazonaws.com/pod-eni":"0"}` (memory/storage values depend on the types EC2 chose).
- Event message: `Failed to schedule pod, all available instance types exceed limits for nodepool (NodePool=spot-first); all available instance types exceed limits for nodepool (NodePool=on-demand-fallback)`. Pools appear in weight order. One event per Pending pod.
- The log shows the same text as the `error` field of `could not schedule pod`.

### Step 7 — Clean up the weighted pools
Deleting a NodePool cascades: its NodeClaims are drained and terminated gracefully.
```bash
kubectl scale deployment inflate -n demo --replicas 0
kubectl delete -f manifests/05-nodepools/weighted-pools.yaml
kubectl wait nodeclaims --all --for=delete --timeout=300s; kubectl get nodeclaims
```
Expected: both pools deleted. The `delete` returns at once; `kubectl wait` prints `condition met` per NodeClaim as each goes (about 35 s), then `No resources found`.

### Step 8 — A dedicated, tainted team pool
`team-batch`: label `team: batch`, taint `team=batch:NoSchedule`, on-demand 2-vCPU, limit 4 (headroom matters in Step 9). `batch-worker` has the matching toleration **and** `nodeSelector`.
```bash
kubectl apply -f manifests/05-nodepools/team-batch-pool.yaml -f manifests/05-nodepools/batch-worker.yaml
kubectl rollout status deployment batch-worker -n demo --timeout=5m
kubectl get nodes -l team=batch -o custom-columns=NAME:.metadata.name,TEAM:.metadata.labels.team,TAINTS:.spec.taints,OWNER:.metadata.annotations.example\\.com/owner
```
Expected: rollout completes in 30–60 s (measured 35 s). One node, `TEAM=batch`, taints include `map[effect:NoSchedule key:team value:batch]`, `OWNER=batch-team` (the template annotation).

### Step 9 — Everyone else is kept out
`inflate` has no toleration, and `team-batch` is now the only pool.
```bash
kubectl scale deployment inflate -n demo --replicas 1
sleep 15
kubectl get events -n demo --field-selector reason=FailedScheduling,source=karpenter --sort-by=.lastTimestamp | tail -1
```
Expected: the `inflate` pod stays `Pending`. Message: `Failed to schedule pod, did not tolerate taint (taint=team=batch:NoSchedule)`. Leave it Pending: the next step rescues it.

Note: limits are checked before taints. With the pool at its limit the message would be `all available instance types exceed limits for nodepool (NodePool=team-batch)` instead; that is why `team-batch` has limit 4.

### Step 10 — Requirement selectors + minValues
`selectors-demo`: spot only, families `c5a c6a c6i m6a m6i r6a` with `minValues: 3`, sizes `large`/`xlarge`, zones `ap-south-1a`/`ap-south-1b`, limit 4.
```bash
kubectl apply -f manifests/05-nodepools/selectors-pool.yaml
kubectl rollout status deployment inflate -n demo --timeout=5m
kubectl get nodes -l karpenter.sh/nodepool=selectors-demo -L karpenter.k8s.aws/instance-family,karpenter.k8s.aws/instance-size,karpenter.sh/capacity-type,topology.kubernetes.io/zone
kubectl get nodeclaims -l karpenter.sh/nodepool=selectors-demo -o json \
  | jq -c '.items[0].spec.requirements[] | select(.key=="karpenter.k8s.aws/instance-family" or .key=="topology.kubernetes.io/zone" or .key=="node.kubernetes.io/instance-type")'
```
Expected: the Pending pod is picked up within seconds; rollout done in 30–60 s (measured 42 s). Node is one of the listed families, usually `large` (EC2 may pick an `xlarge` from a deeper spot pool), `spot`, zone `ap-south-1a` or `ap-south-1b`, never `1c`. The NodeClaim requirements show `instance-family` `In` the 6 families with `"minValues":3`, the zone `In` the two zones, and `node.kubernetes.io/instance-type` `In` a list spanning at least 3 families: that whole list went to EC2 Fleet.

## Talking points
- A NodePool is a **policy**, not a node group: no instance type, no size, no count. Karpenter picks per batch of pods.
- Weight is how you say "prefer". Limits are how you say "but no more than". Together they implement "use my Savings Plan / spot first, then fall back".
- Limits count **node capacity**, not pod requests. 3 pods × 500m on a 2-vCPU node still uses 2 of `cpu`.
- Limits are checked at launch time, so a burst can overshoot slightly. They are a guardrail, not a quota.
- A taint keeps others **out**; a label + `nodeSelector` keeps the team **in**. You need both for a dedicated pool.
- Custom labels must be declared on the pool (template label or requirement) or Karpenter will not launch for a pod that selects them.
- `minValues` trades a little price for availability: Karpenter cannot "race to the bottom" onto a single spot pool.
- Avoid single-SKU pools (one family + one size): one ICE and you get `NoCompatibleInstanceTypes`.

## Reset
```bash
source scripts/env.sh
kubectl delete -f manifests/05-nodepools/batch-worker.yaml --ignore-not-found
kubectl scale deployment inflate -n demo --replicas 0
kubectl delete -f manifests/05-nodepools/selectors-pool.yaml -f manifests/05-nodepools/team-batch-pool.yaml -f manifests/05-nodepools/weighted-pools.yaml --ignore-not-found
kubectl wait nodeclaims --all --for=delete --timeout=300s
kubectl apply -f manifests/base/nodepool.yaml
bash scripts/reset.sh
```
Expected: only `nodepool/default` remains, no NodeClaims, only `inflate` (0 replicas) in `demo`.

## Q&A prep
- **Two pools with the same weight both match. Which wins?** In v1.14.1 ties are broken by name, reverse alphabetical (`zeta` before `alpha`). That is an implementation detail: the docs recommend mutually exclusive pools, or distinct weights.
- **Is `limits.memory` / `limits.nodes` supported?** Yes: any resource (`cpu`, `memory`, `nvidia.com/gpu`, …) plus `nodes` (since v1.11).
- **What happens when `minValues` cannot be met?** With the default `Strict` policy the pool is skipped for that pod (event `NoCompatibleInstanceTypes`: `NodePool requirements filtered out all compatible available instance types due to minValues incompatibility`). With `--min-values-policy=BestEffort` Karpenter relaxes it and annotates the NodeClaim `karpenter.sh/nodeclaim-min-values-relaxed: "true"`.
- **Does changing `weight` or `limits` replace my nodes?** No. They are behavioural fields, not part of the drift hash.
- **startupTaints vs taints?** `taints` stay for the node's life and pods must tolerate them. `startupTaints` are expected to be removed by some agent (CNI, security agent); Karpenter does not require pods to tolerate them and waits for their removal before marking the node `Initialized`.
- **Can I target a specific pool from a pod?** Yes: `nodeSelector: {karpenter.sh/nodepool: <name>}`.
- **What does `expireAfter: Never` mean?** Nodes never expire. Default is `720h` (30 days).

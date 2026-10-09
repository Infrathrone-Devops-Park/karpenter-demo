# 06 — Scheduling constraints
**Time:** 30 min · **Goal:** Show that Karpenter reads the pod's scheduling constraints and launches exactly the node that satisfies them.

## What you'll show
- `nodeSelector` on well-known labels: `karpenter.sh/capacity-type`, `topology.kubernetes.io/zone`, `node.kubernetes.io/instance-type`.
- Required node affinity on `karpenter.k8s.aws/instance-family`, plus a *preferred* zone that Karpenter treats as required first.
- Topology spread across zones: 3 replicas become 3 nodes in 3 AZs.
- Pod anti-affinity on `kubernetes.io/hostname`: one pod per node.
- Resource requests drive instance size: a 3-CPU pod gets a 4-vCPU instance.

## Concepts

### Who does what
```text
pod Pending (kube-scheduler: no node fits)
   -> Karpenter simulates: pod constraints  ∩  NodePool requirements  ∩  instance types/offerings
   -> launches the cheapest node that satisfies ALL of them  (NodeClaim)
   -> kube-scheduler binds the pod to the new node  (Karpenter only "nominates")
```
Karpenter never binds pods. It launches capacity that kube-scheduler will then pick, so the pod's constraints must be satisfiable by **both** the NodePool and an instance type that exists in that zone.

### What Karpenter understands
| Pod field | Karpenter behaviour |
|---|---|
| `nodeSelector`, required `nodeAffinity` (In, NotIn, Exists, DoesNotExist, Gt, Lt) | Hard requirements, intersected with the NodePool's `requirements` |
| Preferred `nodeAffinity`, preferred pod (anti-)affinity | Treated as **required first**; if nothing fits, relaxed one term at a time (heaviest weight first) and retried |
| `topologySpreadConstraints` on `topology.kubernetes.io/zone`, `kubernetes.io/hostname`, `karpenter.sh/capacity-type` (or any label the NodePool defines) | Honoured; `DoNotSchedule` is hard, `ScheduleAnyway` is a preference (relaxed last) |
| Required pod affinity / anti-affinity | Honoured |
| Resource requests (+ DaemonSet overhead) | Pick an instance type with enough allocatable |
| PVC with a zonal volume | New node goes to the volume's zone |

Relaxation order in v1.14.1 (source `preferences.go`): required node-affinity terms (when there are several OR'ed terms, one is dropped at a time), then preferred pod affinity, preferred pod anti-affinity, preferred node affinity, then `ScheduleAnyway` spread. The `PREFERENCE_POLICY` setting (`Respect` by default, `Ignore` to skip preferences) controls this.

### What it does not do well (be honest with the audience)
- **Preferences cost nodes.** Because preferred terms are tried as required first, a preferred zone or a preferred anti-affinity can make Karpenter launch a *new* node instead of using free space elsewhere. Karpenter logs `pod(s) have a preferred Anti-Affinity which can prevent consolidation` and `pod(s) have a preferred TopologySpreadConstraint which can prevent consolidation`.
- **Preferences are not used for topology domains.** Karpenter does not treat preferred affinities as required when building topology requirements; if the spread or co-location really matters, use the required form.
- **Unknown labels.** A `nodeSelector` on a label no NodePool declares (in `requirements` or `template.metadata.labels`) leaves the pod Pending. Watch for look-alikes: `node.kubernetes.io/instance-family` does not exist; the real key is `karpenter.k8s.aws/instance-family`.
- **Restricted labels.** `karpenter.sh/registered` and `karpenter.sh/initialized` never trigger provisioning; select `karpenter.sh/nodepool` instead.
- **No rebalancing of running pods.** Once bound, pods stay. Moving them later is consolidation's job (module 07), not scheduling's.
- **DRA.** Pods with ResourceClaims are ignored by default in v1.14 (`settings.ignoreDRARequests: true`).

### Capacity plan
All demos use the base `default` pool (limit 10, spot + on-demand, c/m/r, generation > 4, 2 or 4 vCPU). Between steps we force-delete the nodes so the next step starts from zero and its result is unambiguous.

| Step | Nodes | vCPU |
|---|---|---|
| 2 (three selectors) | 3 × 2-vCPU (1 on-demand, 2 spot) | 6 |
| 4 (zone spread) | 3 × 2-vCPU | 6 |
| 6 (anti-affinity) | 3 × 2-vCPU | 6 |
| 7 (big pod) | 1 × 4-vCPU | 4 |

Note: a terminated spot instance keeps counting against the 8-vCPU spot quota for about a minute after `kubectl delete nodeclaims` returns. Without the `sleep 60` in Steps 4, 6 and 7, validation hit `MaxSpotInstanceCountExceeded` (Karpenter retried or fell back to on-demand, but the logs pane showed an ERROR).

## Demo

Panes: `scripts/watch.sh nodes`, `scripts/watch.sh claims`, `scripts/watch.sh logs`.

### Step 1 — Starting point
```bash
source scripts/env.sh
kubectl get nodepools,nodeclaims
export KN_COLS=topology.kubernetes.io/zone,karpenter.sh/capacity-type,node.kubernetes.io/instance-type,karpenter.k8s.aws/instance-family
kubectl get nodes -l karpenter.sh/nodepool -L "$KN_COLS"
```
Expected: `nodepool.karpenter.sh/default` only; no NodeClaims; `No resources found` for nodes. `KN_COLS` is reused in every step.

### Step 2 — Three nodeSelector / affinity flavours at once
- `od-only`: `nodeSelector: karpenter.sh/capacity-type: on-demand`.
- `pinned`: `nodeSelector` zone `ap-south-1b` + instance-type `c6a.large` + capacity-type `spot`.
- `family-affinity`: required affinity instance-family `In [m6a, m6i]` + capacity-type `spot`, preferred zone `ap-south-1c`.

Their requirements are mutually incompatible (different capacity type, instance type and family), so Karpenter cannot pack them together: expect 3 NodeClaims in one batch.
```bash
kubectl apply -f manifests/06-scheduling/od-only.yaml -f manifests/06-scheduling/zone-and-type.yaml -f manifests/06-scheduling/family-affinity.yaml
for d in od-only pinned family-affinity; do kubectl rollout status deployment $d -n demo --timeout=5m; done
kubectl get nodes -l karpenter.sh/nodepool -L "$KN_COLS"
```
Expected after 30–45 s (measured 36 s):
```text
NAME                ...  ZONE          CAPACITY-TYPE   INSTANCE-TYPE   INSTANCE-FAMILY
ip-10-0-...         ...  ap-south-1?   on-demand       c6a.large*      c6a*
ip-10-0-...         ...  ap-south-1b   spot            c6a.large       c6a
ip-10-0-...         ...  ap-south-1c   spot            m6a.large*      m6a*
```
`*` = Karpenter's cheapest choice, may differ (for example `c5a.large`, `m6i.large`). The pinned row is exact. The `family-affinity` node is in `ap-south-1c`: the *preferred* zone was honoured as if required, because it was satisfiable.

### Step 3 — Show what Karpenter derived
```bash
kubectl get nodeclaims -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone,CAP:.metadata.labels.karpenter\\.sh/capacity-type
kubectl get events -n demo --field-selector reason=Nominated --sort-by=.lastTimestamp | tail -3
```
Expected: 3 NodeClaims `default-xxxxx` matching the table above. `Nominated` events from `karpenter`: `Pod should schedule on: nodeclaim/default-xxxxx` (later also `, node/ip-...`).

### Step 4 — Clean slate, then spread across zones
Force-delete the nodes (graceful drain) instead of waiting for consolidation.
```bash
kubectl delete -f manifests/06-scheduling/od-only.yaml -f manifests/06-scheduling/zone-and-type.yaml -f manifests/06-scheduling/family-affinity.yaml
kubectl delete nodeclaims -l karpenter.sh/nodepool=default
sleep 60
kubectl apply -f manifests/06-scheduling/zone-spread.yaml
kubectl rollout status deployment zone-spread -n demo --timeout=5m
kubectl get nodes -l karpenter.sh/nodepool -L "$KN_COLS"
```
Expected: the `delete nodeclaims` returns in 30–40 s, then the 60 s pause. Then 3 new nodes in 30–45 s (measured 36 s), **one in each of `ap-south-1a`, `ap-south-1b`, `ap-south-1c`**. With `maxSkew: 1` and `DoNotSchedule`, three pods cannot share a zone, so Karpenter launched 3 zonal NodeClaims even though 3 × 500m would fit on one node.

Note: the manifest also sets `minDomains: 3`. kube-scheduler only counts zones that already have a node; without it, when the 1a node came up 10 s late, two pods were bound to the 1b node (skew 2-1 across the 2 zones it could see).

### Step 5 — Proof from the scheduler's side
```bash
kubectl get pods -n demo -l app=zone-spread -o wide
```
Expected: three pods `Running`, each on a different node.

### Step 6 — Clean slate, then one pod per node
Required pod anti-affinity on `kubernetes.io/hostname`.
```bash
kubectl delete -f manifests/06-scheduling/zone-spread.yaml
kubectl delete nodeclaims -l karpenter.sh/nodepool=default
sleep 60
kubectl apply -f manifests/06-scheduling/hostname-anti.yaml
kubectl rollout status deployment one-per-node -n demo --timeout=5m
kubectl get nodes -l karpenter.sh/nodepool -L "$KN_COLS"
```
Expected: 3 nodes again, 30–45 s. This time zones are **not** forced: in validation all three landed in `ap-south-1c` (cheapest spot pool, `c8i-flex.large`). The constraint is per hostname, not per zone. Point out that each node has ~1.3 CPU free, yet a 4th replica would still get a 4th node: anti-affinity is honoured, at a price. (Do not actually scale to 4: it would hit the 8-vCPU spot quota.)

### Step 7 — Clean slate, then a big pod
A single pod requesting `cpu: "3"`. A 2-vCPU node has about 1.8 CPU allocatable after DaemonSets, so only 4-vCPU types qualify.
```bash
kubectl delete -f manifests/06-scheduling/hostname-anti.yaml
kubectl delete nodeclaims -l karpenter.sh/nodepool=default
sleep 60
kubectl apply -f manifests/06-scheduling/big-pod.yaml
kubectl rollout status deployment big-pod -n demo --timeout=5m
kubectl get nodes -l karpenter.sh/nodepool -L "$KN_COLS"
kubectl logs -n "$KARPENTER_NAMESPACE" deploy/karpenter -c controller --since=3m \
  | jq -rR 'fromjson? | select(.message=="created nodeclaim") | [.NodeClaim.name, (.requests.cpu), .["instance-types"]] | @tsv' | tail -1
```
Expected: rollout in 30–45 s (measured 34 s). One node, an `.xlarge` type (4 vCPU), for example `c6a.xlarge` (validation) or `c8id.xlarge`. The log line shows the NodeClaim name, requested CPU `3160m` (3 for the pod + 160m DaemonSet overhead), and an instance-types list of only 4-vCPU types: `c5.xlarge, c5a.xlarge, c5d.xlarge, c5n.xlarge, c6a.xlarge and 34 other(s)`. Compare with the 2-vCPU-capable list of Step 6 (`c5.large, c5.xlarge, ... and 73 other(s)`).

## Talking points
- Karpenter is not a second scheduler. It answers one question: "what node would make this pod schedulable, cheapest?"
- Everything is an intersection: pod constraints ∩ NodePool requirements ∩ what EC2 offers in that zone. An empty intersection means Pending forever, with a `FailedScheduling` event from `karpenter` that says why.
- Prefer well-known labels (`karpenter.k8s.aws/instance-family`, `karpenter.sh/capacity-type`) over pinning exact instance types. Pinning `c6a.large` in one AZ is a single-pool bet; it is fine for a demo, risky for spot in production.
- Topology spread is how you get AZ resilience without three node groups.
- Preferred rules are not free: Karpenter honours them by launching new nodes, and they can block consolidation later.
- Requests are the sizing input. Under-request and you get packed onto small nodes; over-request and you pay for air.

## Reset
```bash
source scripts/env.sh
kubectl delete -f manifests/06-scheduling/ --ignore-not-found
kubectl delete nodeclaims -l karpenter.sh/nodepool=default
unset KN_COLS
bash scripts/reset.sh
```
Expected: only `inflate` (0 replicas) in `demo`, no NodeClaims, `default` pool unchanged.

## Q&A prep
- **Why did Karpenter launch 3 nodes for 3 tiny pods?** Because the pods asked for it (zone spread or anti-affinity). Karpenter does exactly what the constraints require, then consolidation keeps it from growing further.
- **What if I select a zone the NodePool excludes?** Pending, with `FailedScheduling` from `karpenter`: `Failed to schedule pod, no instance type met the scheduling requirements or had enough resources or had a required offering, requirements=... topology.kubernetes.io/zone In [ap-south-1d], ...` (tested with a nodeSelector on `ap-south-1d`).
- **Does `ScheduleAnyway` spread work?** Yes, as a preference: Karpenter tries to satisfy it (often by creating nodes), and relaxes it last if impossible.
- **Can I spread across capacity types (spot vs on-demand)?** Yes: `topologyKey: karpenter.sh/capacity-type`. That is the documented pattern for an on-demand/spot ratio, together with a custom label.
- **Does Karpenter respect `nodeAffinityPolicy` / `nodeTaintsPolicy` / `matchLabelKeys` in spread constraints?** Yes, since v1.3.
- **Why did my pod land on an existing node, not the one Karpenter launched?** kube-scheduler binds wherever the pod fits first. If space freed up elsewhere, it may use that; the new node then becomes empty and consolidation removes it.
- **Can a pod request a specific AMI or kubelet setting?** No. That is EC2NodeClass territory (module 11). Point the pod at a NodePool that uses that class.

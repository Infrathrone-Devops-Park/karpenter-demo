# 09 — Drift and expiration
**Time:** 20 min · **Goal:** Roll a new AMI across running nodes with drift, one node at a time, and see why expiration is a different, forceful tool.

## What you'll show
- Bumping the pinned AMI alias `al2023@v20260930` → `al2023@v20261003` marks every node `Drifted=True` (reason `AMIDrift`).
- Karpenter replaces drifted nodes make-before-break, paced by the default budget (`nodes: "10%"` → 1 at a time).
- `expireAfter: 4m` on a demo pool: the node is deleted at 4 minutes even though the pool's budget is `nodes: "0"`.
- Why production should pin AMIs, and how `@latest` creates surprise drift.

## Concepts

### What drift is
A NodeClaim is **drifted** when the node it describes no longer matches what its NodePool / EC2NodeClass would launch today. Drift is GA (no feature gate since v1.0) and is a *voluntary, graceful* disruption: budgets, PDBs and `do-not-disrupt` apply (the last two can be overridden by `terminationGracePeriod`).

| Source | How detected | Drift reason (NodeClaim condition `Drifted`) |
|---|---|---|
| NodePool `spec.template` (labels, taints, `expireAfter`, `terminationGracePeriod`, kubelet-related, …) | hash annotation `karpenter.sh/nodepool-hash` differs | `NodePoolDrifted` |
| NodePool `requirements` | node's labels no longer satisfy them (widening does **not** drift) | `RequirementsDrifted` |
| Instance type gone from the offering list | checked hourly | `InstanceTypeNotFound` |
| EC2NodeClass static fields (`kubelet`, `tags`, `blockDeviceMappings`, `userData`, `metadataOptions`, `role`, …) | hash annotation `karpenter.k8s.aws/ec2nodeclass-hash` differs | `NodeClassDrift` |
| EC2NodeClass `amiSelectorTerms` | the **resolved** AMI set no longer contains the node's `status.imageID` | `AMIDrift` |
| `subnetSelectorTerms` / `securityGroupSelectorTerms` | node's subnet / SGs no longer selected | `SubnetDrift` / `SecurityGroupDrift` |
| Capacity reservations / placement group | resolved value changed | `CapacityReservationDrift` / `PlacementGroupDrift` |

- **Static vs dynamic.** Static fields are hashed: any edit drifts. Selector fields (`amiSelectorTerms`, subnet/SG/capacity-reservation selectors) are excluded from the hash and drift only when **what they resolve to** changes. `amiFamily` and `ipPrefixCount` are also hash-ignored.
- **Behavioural fields never drift:** NodePool `weight`, `limits`, `disruption.*`.
- **Empty drifted nodes** are just deleted; drifted nodes with pods get a replacement first.
- In v1.14.1 the disruption loop order is Emptiness, Drift, Multi-node, Single-node consolidation: drift wins over consolidation.

### Expiration
- `spec.template.spec.expireAfter` (default `720h`, or `Never`). When a NodeClaim's age reaches it, the expiration controller **deletes the NodeClaim** directly.
- **Forceful:** not rate-limited by budgets, no pre-spun replacement. Pods are evicted (PDBs and `do-not-disrupt` still hold the drain) and Karpenter provisions for them as soon as the node is marked for deletion.
- Pair it with `terminationGracePeriod`; max node lifetime = `expireAfter + terminationGracePeriod`.
- Changing `expireAfter` on a NodePool changes the template hash, so existing nodes **drift** (`NodePoolDrifted`) rather than adopting the new value.

### AMI pinning
```text
al2023@latest     -> resolves the newest AL2023 AMI for the cluster's K8s version
                     (re-checked every AMI_REFRESH_INTERVAL = 1m)
                     AWS publishes a new AMI -> every node drifts -> fleet-wide rolling replace, unplanned
al2023@v20260930  -> fixed release; you choose when to roll (change in Git, review, merge)
```
Pinned aliases still follow the control-plane version: upgrading EKS 1.36 → 1.37 changes the resolved AMI and drifts nodes. Docs guidance: pin in production, test `@latest` in lower environments, roll with drift budgets (for example `reasons: [Drifted]` limited to business hours) and PDBs.

### Capacity plan
| Part | Pools (sum of limits) | Peak vCPU |
|---|---|---|
| Drift | `default` (10) | up to 4 × 2 = 8 spot for ~25 s (2nd replacement launches while the 1st old node terminates); if spot quota is hit, `default` falls back to on-demand |
| Expiration | `default` (10, empty by then) + `expiring` (2) = 12 | 2 + 2 briefly (old node terminating while new launches) |

## Demo

Panes: `scripts/watch.sh claims`, `scripts/watch.sh logs`, `scripts/watch.sh nodes`.

### Step 1 — Two nodes on the pinned AMI
`drift-app`: 2 replicas, required anti-affinity on hostname, so 2 nodes.
```bash
source scripts/env.sh
kubectl apply -f manifests/09-drift/drift-app.yaml
kubectl rollout status deployment drift-app -n demo --timeout=5m
kubectl get ec2nodeclass default -o jsonpath='{.spec.amiSelectorTerms}{"\n"}{range .status.amis[*]}{.id}{"  "}{.name}{"\n"}{end}'
kubectl get nodeclaims -o wide
```
Expected: rollout in 30–45 s (measured 34 s), 2 NodeClaims (e.g. `c8i-flex.large` spot). `[{"alias":"al2023@v20260930"}]` then 5 AMIs:
```text
ami-067d27d47f88c442a  amazon-eks-node-al2023-x86_64-standard-1.36-v20260930
ami-0c5676b892cc5f26a  amazon-eks-node-al2023-arm64-standard-1.36-v20260930
ami-049636d44acbe769b  amazon-eks-node-al2023-x86_64-neuron-1.36-v20260930
ami-0b74c34b88f6d1170  amazon-eks-node-al2023-arm64-nvidia-1.36-v20260930
ami-0d5708a8364bd17e3  amazon-eks-node-al2023-x86_64-nvidia-1.36-v20260930
```
`-o wide`: both NodeClaims show `IMAGEID` `ami-067d27d47f88c442a` and `DRIFTED` empty.

### Step 2 — Check the budget that will pace the roll
```bash
kubectl get nodepool default -o jsonpath='{.spec.disruption.budgets}{"\n"}'
```
Expected: `[{"nodes":"10%"}]`, the API default. With 2 nodes: `roundup(2 × 0.1) = 1` node at a time.

### Step 3 — Bump the AMI
`manifests/09-drift/ec2nodeclass-new-ami.yaml` is the base EC2NodeClass with only the alias changed.
```bash
kubectl apply -f manifests/09-drift/ec2nodeclass-new-ami.yaml
kubectl wait nodeclaims -l karpenter.sh/nodepool=default --for=condition=Drifted --timeout=3m
kubectl get nodeclaims -o wide
kubectl get nodeclaims -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.status.conditions[?(@.type=="Drifted")].reason}{"\n"}{end}'
```
Expected: `ec2nodeclass.karpenter.k8s.aws/default configured`. Within a few seconds (measured 2 s) both NodeClaims `condition met`. `DRIFTED=True` on both; reason `AMIDrift`.

### Step 4 — Watch the rolling replacement
```bash
kubectl get nodeclaims -o wide -w
```
Expected (measured: about 2 min total, start the watch right away):
1. ~10 s: a **third** NodeClaim appears (new `IMAGEID` `ami-0697b4e9f2d2eb37a`); one old node is tainted `karpenter.sh/disrupted:NoSchedule`.
2. ~40 s: it is Ready; the first old NodeClaim gets its deletion timestamp, its `drift-app` pod moves to the new node.
3. ~45 s: the replacement for the second old node is already launched, while the first old node is still terminating (gone at ~70 s).
4. ~70 s: the second old NodeClaim is deleted once its replacement is Ready; gone at ~110 s.
Old nodes are deleted strictly one after the other: that is the 10% budget (1 node). Replacements can overlap, so briefly 4 NodeClaims exist.

Ctrl-C when 2 NodeClaims remain, both with the new `IMAGEID` and no `DRIFTED`.

### Step 5 — The evidence
```bash
kubectl logs -n "$KARPENTER_NAMESPACE" deploy/karpenter -c controller --since=10m \
  | jq -rR 'fromjson? | select(.message=="disrupting node(s)") | [.time, .command] | @tsv'
kubectl get events -A --field-selector involvedObject.kind=NodeClaim --sort-by=.lastTimestamp | grep -E 'DisruptionLaunching|DisruptionTerminating' | tail -4
kubectl get nodes -l karpenter.sh/nodepool=default -o custom-columns=NAME:.metadata.name,OS:.status.nodeInfo.osImage,KUBELET:.status.nodeInfo.kubeletVersion
```
Expected:
- Two log lines, about 35 s apart: `Drifted/32dbdab1-...: replace: nodepools=[default]: [ip-10-0-34-40.ap-south-1.compute.internal] -> [1 replacement] (savings: $0.00)`. The savings figure is irrelevant for drift (here 0).
- Events: `Launching NodeClaim: Drifted` and `Disrupting NodeClaim: Drifted`.
- Both nodes on the new image; `OS` shows `Amazon Linux 2023.12.20260930` (the OS release inside AMI v20261003 still carries this date; the `IMAGEID` column is the proof), kubelet `v1.36.4-eks-3b4a6ca`.

### Step 6 — Free the default pool
```bash
kubectl delete -f manifests/09-drift/drift-app.yaml
```
Expected: the two nodes become empty and are removed by consolidation within about 1.5 min (measured 22 s and 78 s; they keep running meanwhile; no need to wait).

### Step 7 — Expiration: a pool whose nodes live 4 minutes
`expiring`: `expireAfter: 4m`, budget `nodes: "0"`, limit 2. `expire-app`: 1 replica pinned to it.
```bash
kubectl apply -f manifests/09-drift/expiring-pool.yaml -f manifests/09-drift/expire-app.yaml
kubectl rollout status deployment expire-app -n demo --timeout=5m
NC=$(kubectl get nodeclaims -l karpenter.sh/nodepool=expiring -o jsonpath='{.items[0].metadata.name}'); echo "$NC"
kubectl get nodeclaim "$NC" -o jsonpath='{.spec.expireAfter}{"  created "}{.metadata.creationTimestamp}{"\n"}'
```
Expected: one NodeClaim `expiring-xxxxx`, rollout in 30–45 s (measured 33 s). `4m  created 2026-10-09T17:28:31Z`. Use the next ~3.5 minutes to discuss AMI pinning (Concepts).

### Step 8 — It expires, budget or not
```bash
kubectl wait nodeclaim "$NC" --for=delete --timeout=8m
kubectl get nodeclaims -l karpenter.sh/nodepool=expiring
kubectl get pods -n demo -l app=expire-app -o wide
```
Expected: at exactly creation + 4 min (measured 17:28:31 -> 17:32:31) the NodeClaim gets a deletion timestamp; the wait returns when it is gone (+24 s to +65 s). A **new** `expiring-xxxxx` NodeClaim already exists (created the same second, `READY Unknown`, or `True` if the old instance took a minute to go) (Karpenter provisions for pods on a deleting node right away); the pod was evicted and is Pending or Running on the new node. The `nodes: "0"` budget did not help: expiration is forceful. This new node will expire in 4 minutes too, so move on to Reset.

## Talking points
- Drift is how Karpenter does node upgrades: change the desired state in Git, Karpenter converges the fleet.
- Make-before-break + budgets + PDBs = a rolling update you control. `nodes: "0"` with `reasons: [Drifted]` during business hours is a common pattern.
- Static fields drift on any edit; selector fields drift on what they **resolve to**. That is why `@latest` can drift a fleet without anyone touching YAML.
- Pin AMIs in production. Promote a new version through environments like any other change.
- Expiration is a hard backstop for compliance ("no node older than N days"), not a rollout tool. It ignores budgets and does not pre-spin.
- Always set `terminationGracePeriod` when you use `expireAfter` with `do-not-disrupt` or strict PDBs, or nodes can hang in draining.

## Reset
Order matters: the pinned AMI must come back **after** the nodes are gone, otherwise reverting the alias drifts them again.
```bash
source scripts/env.sh
kubectl delete -f manifests/09-drift/expire-app.yaml -f manifests/09-drift/drift-app.yaml --ignore-not-found
kubectl scale deployment inflate -n demo --replicas 0
kubectl delete -f manifests/09-drift/expiring-pool.yaml --ignore-not-found
kubectl delete nodeclaims --all
kubectl wait nodeclaims --all --for=delete --timeout=300s
kubectl apply -f manifests/base/ec2nodeclass.yaml -f manifests/base/nodepool.yaml
kubectl get ec2nodeclass default -o jsonpath='{.spec.amiSelectorTerms}{"\n"}'
bash scripts/reset.sh
```
Expected: no NodeClaims, `expiring` gone, alias back to `[{"alias":"al2023@v20260930"}]`.

## Q&A prep
- **Can I stop drift entirely?** Budget `nodes: "0"` with `reasons: ["Drifted"]`. Nodes stay `Drifted=True` until the budget allows. There is no longer a Drift feature gate.
- **If I revert the AMI before the roll finishes, what happens?** Nodes still on the old AMI stop being drifted (condition removed); new nodes on the newer AMI become drifted. Karpenter always converges to the current spec.
- **Does a Kubernetes control-plane upgrade drift nodes?** Yes, even with a pinned alias, because the alias resolves per K8s minor.
- **Does widening requirements drift nodes?** No. Only when the node no longer satisfies them.
- **Do drift replacements respect `limits`?** Yes. If the pool is at its limit, the replacement cannot launch and drift waits. Keep headroom (quota and limits) for one extra node per budgeted disruption.
- **Is expiration affected by `do-not-disrupt`?** The NodeClaim is still deleted; the drain then waits for that pod until `terminationGracePeriod` (if set) forces it.
- **How do I see which AMI a node uses?** `kubectl get nodeclaims -o wide` (`IMAGEID` column) or `.status.imageID`.
- **Why `al2023@v20261003` and not `@latest` in this demo?** So the demo is repeatable: `@latest` would keep moving.

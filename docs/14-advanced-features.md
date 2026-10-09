# 14 — Advanced Features and Feature Gates

**Time:** 25 min · **Goal:** Know every v1.14.1 feature gate, enable two of them live (StaticCapacity, NodeOverlay), and explain the rest well enough to decide when to use them.

## What you'll show

- The six feature gates in chart 1.14.1, their maturity and defaults, and how the chart turns them into the `FEATURE_GATES` env var.
- Enabling `staticCapacity` and `nodeOverlay` with a layered values file.
- **StaticCapacity:** a NodePool with `replicas: 1` that keeps a node with no pods, plus `kubectl scale nodepool` and `limits.nodes`.
- **NodeOverlay:** a price override that makes Karpenter pick `m6i.large` over cheaper types.
- Explained, not run: NodeRepair, SpotToSpotConsolidation, ReservedCapacity / ODCR, CapacityBuffer.
- Reverting the gates to the BASELINE values.

## Concepts

### Feature gates in chart 1.14.1

| Helm value `settings.featureGates.*` | Gate name | Maturity | Default | What it unlocks |
|---|---|---|---|---|
| `reservedCapacity` | ReservedCapacity | Beta | **true** | ODCR / Capacity Block support: `capacityReservationSelectorTerms`, capacity-type `reserved` |
| `spotToSpotConsolidation` | SpotToSpotConsolidation | Alpha | false | Consolidation may *replace* a Spot node with a cheaper Spot node (not just delete) |
| `nodeRepair` | NodeRepair | Alpha | false | Force-replace nodes with unhealthy conditions |
| `nodeOverlay` | NodeOverlay | Alpha | false | `NodeOverlay` CRD (`karpenter.sh/v1alpha1`): price and extended-resource overrides |
| `staticCapacity` | StaticCapacity | Alpha | false | `NodePool.spec.replicas`: fixed node count |
| `capacityBuffer` | CapacityBuffer | Alpha | false | `CapacityBuffer` CRD (`autoscaling.x-k8s.io/v1beta1`): warm spare capacity |

The chart always renders all six into one env var:
`FEATURE_GATES=ReservedCapacity=true,SpotToSpotConsolidation=false,NodeRepair=false,NodeOverlay=false,StaticCapacity=false,CapacityBuffer=false`.

Drift is **not** a gate any more (GA since v1.0); control it with budgets `reasons: [Drifted]`.

**Important:** the CRDs for alpha features are always installed. With the gate off, the API server happily stores a `NodeOverlay` or a NodePool with `replicas`, and **nothing happens**. Always check the gate first.

### StaticCapacity

- `spec.replicas: N` on a NodePool = keep N nodes, whatever the pods need.
- Rules (CRD CEL): cannot switch a NodePool between static and dynamic after creation; `weight` not allowed; only `limits.nodes` allowed (no `cpu` / `memory` limits); consolidation fields ignored.
- Scale with `kubectl scale nodepool <name> --replicas=N` (the CRD has a scale subresource). Scale-down respects PDBs but not disruption budgets.
- Use cases: pre-warmed capacity for a known event, licensed software on a fixed fleet, latency-sensitive pools.
- Capacity note for this demo: a static pool cannot have a CPU limit, so we bound it with `limits.nodes: 1` and `instance-cpu In ["2"]` (= 2 vCPU). `default` 10 + 2 = 12.

### NodeOverlay

- Changes Karpenter's **simulation** inputs, not EC2: `price` (absolute) **or** `priceAdjustment` (`+0.5`, `-10%`), and `capacity` (extended resources only, added on top).
- `requirements` select instance types (same keys/operators as NodePools). `weight` 1–10000 resolves conflicts; capacity maps merge.
- When overlays exist, Karpenter launches with EC2 Fleet `prioritized` (on-demand) / `capacity-optimized-prioritized` (Spot) so EC2 respects the overlaid order.
- Use cases: Savings Plans / RIs (make covered families "cheaper"), licence costs, hugepages or device-plugin resources Karpenter cannot discover.
- Status condition `ValidationSucceeded` (reason `Conflict` when two equal-weight overlays disagree) → `Ready`.

### NodeRepair (explain only)

- Watches node conditions and force-replaces the node after a toleration period:
  - `Ready=False` or `Ready=Unknown` for **30 min**
  - with the EKS Node Monitoring Agent: `AcceleratedHardwareReady=False` 10 min; `StorageReady`, `NetworkingReady`, `KernelReady`, `ContainerRuntimeReady` `=False` 30 min
- Safety valve: no repair if more than **20%** of the NodePool's nodes are unhealthy (event `NodeRepairBlocked`).
- Repair is forceful: no drain wait, no budgets. Metric `karpenter_nodeclaims_unhealthy_disrupted_total`.
- Not demoed: it takes 30 minutes by design.

### SpotToSpotConsolidation (explain only)

- Without the gate, Spot nodes are only *deleted* by consolidation, never replaced by a cheaper Spot node.
- With it, single-node Spot→Spot replacement requires at least **15** cheaper instance types in the launch request (constant `MinInstanceTypesForSpotToSpotConsolidation = 15`), otherwise Karpenter emits an `Unconsolidatable` event. This stops Karpenter from racing to the cheapest, most-interrupted pool.
- Our `default` NodePool allows plenty of types, but the gain is small at this scale; we keep it off.

### ReservedCapacity / ODCR (explain only, beta, on by default)

- `EC2NodeClass.spec.capacityReservationSelectorTerms` (`id`, or `tags` + `ownerID`, `instanceMatchCriteria: open|targeted`).
- Nodes launched into a reservation get `karpenter.sh/capacity-type: reserved`, plus `karpenter.k8s.aws/capacity-reservation-id` and `-type` (`default` or `capacity-block`).
- Priority: **reserved > spot > on-demand** when a NodePool allows all three. Reservations have zero marginal price, so Karpenter fills them first.
- Since 1.6, open ODCRs are only used if selected.
- Not demoed: an ODCR is billed whether used or not, and on-demand quota is tight.

### CapacityBuffer (explain + dry run)

- `autoscaling.x-k8s.io/v1beta1`, namespaced (the v1.14 docs page says `v1alpha1`; the shipped CRD serves only `v1beta1`).
- `podTemplateRef` + `replicas` (or `limits`), or `scalableRef` to a Deployment/StatefulSet/ReplicaSet + `replicas` / `percentage`.
- Karpenter adds **virtual** pods to its simulation so spare nodes exist before real pods arrive. No real pods are created. Buffer nodes are protected from emptiness consolidation.

## Demo

### Step 1 — Load the environment and check BASELINE
```bash
source scripts/env.sh
kubectl get nodepools,ec2nodeclasses,nodeclaims
kubectl -n kube-system get deploy karpenter \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FEATURE_GATES")].value}{"\n"}'
```
Expected: `default` only, no NodeClaims, then `ReservedCapacity=true,SpotToSpotConsolidation=false,NodeRepair=false,NodeOverlay=false,StaticCapacity=false,CapacityBuffer=false`.

### Step 2 — Prove that a gated field does nothing while the gate is off
```bash
kubectl apply -f manifests/14-advanced/static-nodepool.yaml
sleep 30
kubectl get nodepool static-demo
kubectl get nodeclaims
kubectl delete -f manifests/14-advanced/static-nodepool.yaml
```
Expected: `nodepool.karpenter.sh/static-demo created`; the NodePool shows `NODECLASS default   NODES 0   READY True`; `No resources found` for NodeClaims. The API accepted `replicas: 1`, but no controller acted on it. Then `nodepool.karpenter.sh "static-demo" deleted`.

### Step 3 — Enable StaticCapacity and NodeOverlay
Same chart, same base values and settings as `scripts/install-karpenter.sh`, plus one extra values file.
```bash
cat manifests/14-advanced/feature-gates-values.yaml
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --values manifests/03-install/karpenter-values.yaml \
  --values manifests/14-advanced/feature-gates-values.yaml \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "settings.interruptionQueue=${KARPENTER_QUEUE}"
kubectl -n kube-system rollout status deploy/karpenter --timeout=180s
kubectl -n kube-system get deploy karpenter \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FEATURE_GATES")].value}{"\n"}'
```
Expected: `Release "karpenter" has been upgraded. Happy Helming!`, a new pod Ready in ~12 s, then `ReservedCapacity=true,SpotToSpotConsolidation=false,NodeRepair=false,NodeOverlay=true,StaticCapacity=true,CapacityBuffer=false`.

### Step 4 — StaticCapacity: a node with no pods
```bash
kubectl apply -f manifests/14-advanced/static-nodepool.yaml
kubectl get nodeclaims -l karpenter.sh/nodepool=static-demo -w
```
Expected: within ~2 s a NodeClaim `static-demo-xxxxx` appears (Spot, 2 vCPU; validation run `c8i-flex.large`) and becomes `READY True` in ~34 s, although **no pod asked for it**. Ctrl-C.

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller --tail=-1 --since=3m \
  | jq -cR 'fromjson? | select(.message | test("replica count|node limit")) | {message, current, desired, "provision-count"}'
kubectl get nodepool static-demo
```
Expected: `{"message":"provisioning nodeclaims to satisfy replica count","current":0,"desired":1,"provision-count":1}` and the NodePool with `NODES 1`.

### Step 5 — Scale the static pool against its node limit
```bash
kubectl scale nodepool static-demo --replicas=2
sleep 20
kubectl get nodeclaims -l karpenter.sh/nodepool=static-demo
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller --tail=-1 --since=1m \
  | jq -cR 'fromjson? | select(.message=="nodepool node limit reached") | {time, message, NodePool: .NodePool.name}' | tail -1
```
Expected: `nodepool.karpenter.sh/static-demo scaled`, still **one** NodeClaim, and `{"time":"…","message":"nodepool node limit reached","NodePool":"static-demo"}` (logged at once, then again on each resync). `limits.nodes: 1` is the guardrail (and here it also keeps us inside the vCPU quota).

### Step 6 — Show static nodes are not consolidated, then remove the pool
```bash
kubectl get nodeclaims -l karpenter.sh/nodepool=static-demo -o wide
kubectl delete -f manifests/14-advanced/static-nodepool.yaml --timeout=5m
kubectl wait nodeclaims --all --for=delete --timeout=300s
```
Expected: the empty static node is `AGE` 2+ minutes and was never consolidated (no `Disruption*` events except the early `Nodeclaim does not have an associated node`; the default pool would have removed an empty node after 1 minute). The NodePool delete returns at once; the wait ends ~20 s later when the node is terminated.

### Step 7 — NodeOverlay: create the overlay
The overlay says on-demand `m6i.large` costs `0.0001` per hour (think: fully covered by a Savings Plan). Real on-demand `m6i.large` is more expensive than `c5a.large` / `c6a.large` / `m5a.large`, so without the overlay Karpenter would never pick it first.
```bash
kubectl apply -f manifests/14-advanced/nodeoverlay.yaml
kubectl wait nodeoverlay/prefer-m6i-large --for=condition=Ready --timeout=60s
kubectl get nodeoverlays
```
Expected: `condition met` in under 1 s, then `prefer-m6i-large   True   1s` (columns are only `NAME READY AGE`). Conditions: `ValidationSucceeded True`, `Ready True`.

### Step 8 — Launch an on-demand pod and see the overlay win
```bash
kubectl apply -f manifests/14-advanced/overlay-workload.yaml
kubectl -n demo rollout status deploy/overlay-demo --timeout=180s
kubectl get nodes -l karpenter.sh/capacity-type=on-demand,karpenter.sh/nodepool=default \
  -L node.kubernetes.io/instance-type,karpenter.sh/capacity-type
```
Expected: rollout in ~32 s, one on-demand node, `INSTANCE-TYPE m6i.large`. The log shows `created nodeclaim` with `c5.large, c5.xlarge, c5a.large, c5a.xlarge, c5d.large and 73 other(s)` but `launched nodeclaim` `m6i.large`: the overlay reordered the fleet request. Capacity check: 2 (system) + 2 = 4 of 8 on-demand vCPU.

Optional: show the price Karpenter now uses.
```bash
kubectl -n kube-system port-forward svc/karpenter 8080:8080 >/dev/null 2>&1 &
PF=$!; sleep 2
curl -s localhost:8080/metrics | grep '^karpenter_cloudprovider_instance_type_offering_price_estimate' \
  | grep -E '"(m6i|c5a).large"' | grep on-demand
kill $PF
```
Expected: three `m6i.large` lines (one per zone) with the **overlay** price `0.0001`, and three `c5a.large` lines with its real list price `0.047`. The metric shows what Karpenter believes; the EC2 invoice still uses the real `m6i.large` price.

### Step 9 — Clean up the overlay demo
```bash
kubectl delete -f manifests/14-advanced/overlay-workload.yaml
kubectl delete -f manifests/14-advanced/nodeoverlay.yaml
```
Expected: both deleted; the empty `m6i.large` node is gone after ~1 min 50 s.

### Step 10 — CapacityBuffer: validate the API shape only
The gate stays off; this is a server-side dry run, nothing is created.
```bash
kubectl apply --dry-run=server -f manifests/14-advanced/capacitybuffer-example.yaml
kubectl explain capacitybuffer.spec --api-version=autoscaling.x-k8s.io/v1beta1 | grep -E '^  [a-zA-Z]'
```
Expected: `podtemplate/buffer-chunk created (server dry run)` and `capacitybuffer.autoscaling.x-k8s.io/warm-pool created (server dry run)`, then the six fields: `limits`, `percentage`, `podTemplateRef`, `provisioningStrategy`, `replicas`, `scalableRef`.

### Step 11 — Revert the gates to BASELINE
```bash
scripts/install-karpenter.sh
kubectl -n kube-system get deploy karpenter \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FEATURE_GATES")].value}{"\n"}'
helm get values karpenter -n kube-system -o json | jq '.settings'
```
Expected: the install script finishes with the pod `Running` (~20 s); gates back to `…NodeOverlay=false,StaticCapacity=false…`; `settings` contains only `clusterEndpoint`, `clusterName`, `interruptionQueue` (no `featureGates`). Helm 4 (verified, 4.2.3) resets to chart defaults when `--values`/`--set` are passed without `--reuse-values`, so the overlay file is dropped. Note: `helm upgrade … --reuse-values --set settings.featureGates.staticCapacity=true` also works (keeps every earlier value and adds the gate); `reset.sh` detects and removes such a gate.

## Talking points

- Feature gates are **per controller**, set at start-up. Changing one restarts Karpenter. Plan them like any config rollout.
- CRDs for alpha features always exist. "I applied it and nothing happened" usually means the gate is off.
- StaticCapacity is the answer to "Karpenter, but I want N nodes always". Before 1.8, people faked it with placeholder pods.
- NodeOverlay lets Karpenter's cost model match *your* bill (Savings Plans, RIs, licences). It changes decisions, not prices on the invoice.
- NodeRepair closes the gap with managed node groups' auto-repair, with a 20% blast-radius limit.
- SpotToSpotConsolidation's 15-type floor protects you from always chasing the cheapest, most-interrupted Spot pool.
- Reserved capacity: if you pay for ODCRs, Karpenter fills them first. It is beta and on by default.
- Alpha means: API can change between minors, read the upgrade guide, do not build production on it without testing.

## Reset

```bash
kubectl delete -f manifests/14-advanced/overlay-workload.yaml --ignore-not-found
kubectl delete -f manifests/14-advanced/nodeoverlay.yaml --ignore-not-found
kubectl delete -f manifests/14-advanced/static-nodepool.yaml --ignore-not-found --timeout=5m
scripts/install-karpenter.sh
scripts/reset.sh
```
`reset.sh` also re-runs the install script if it still sees `featureGates` in the Helm values.

## Q&A prep

- **Can I enable a gate without a restart?** No. It is read from `FEATURE_GATES` at start-up.
- **Does StaticCapacity cost money while idle?** Yes: the nodes run with no pods. That is the point.
- **Can a static NodePool also scale on demand?** No. A NodePool is static or dynamic for life. Run both: a static pool for the floor, a dynamic pool for bursts.
- **Do overlays change what I pay?** No. They change Karpenter's choice. Use them to reflect real discounts, not to lie.
- **NodeRepair vs EKS node auto-repair?** EKS auto-repair is for managed node groups. For Karpenter nodes, NodeRepair is the equivalent. Do not combine with other tools that terminate nodes on health checks.
- **What is `Balanced` consolidation?** A 1.14 consolidation *policy* (not a gate): only consolidates when savings outweigh disruption. Covered in the consolidation module.
- **Will these gates graduate?** Graduation is per release; check the upgrade guide. ReservedCapacity went alpha (1.3) → beta (1.6).

# 01 — Why Karpenter
**Time:** 25 min · **Goal:** Explain the problem Karpenter solves, how it differs from Cluster Autoscaler and EKS Auto Mode, and how its control loop works.

## What you'll show
- Why node autoscaling is hard: pending pods, wrong-sized nodes, idle capacity, slow scale-up.
- Cluster Autoscaler vs Karpenter vs EKS Auto Mode, side by side.
- The Karpenter control loop from a Pending pod to a Ready node.
- The three Karpenter CRDs (NodePool, EC2NodeClass, NodeClaim) and how they relate.
- Where Karpenter came from and why v1.14.1 is the version we use.

## Concepts

### The problem

Kubernetes schedules pods onto nodes that already exist. When no node has room, the pod stays `Pending` with a `FailedScheduling` event. Something outside the scheduler has to add capacity, and later remove it. Doing that well means answering four questions quickly:

1. **How much** capacity is missing (CPU, memory, pods, GPUs, volumes, zones)?
2. **Which shape** of instance fits the pending pods best and costs least right now?
3. **Where** (AZ, spot or on-demand) can it actually be launched?
4. **When** is capacity no longer needed, and can it be packed tighter?

### Cluster Autoscaler vs Karpenter vs EKS Auto Mode

| Aspect | Cluster Autoscaler (CA) | Karpenter 1.14 (self-managed) | EKS Auto Mode |
|---|---|---|---|
| Who runs it | You (Deployment) | You (Helm chart, IAM, SQS) | AWS, outside your cluster |
| Unit of scaling | Desired count of an ASG / managed node group | Individual EC2 instances via `CreateFleet`; no ASG | EC2 managed instances |
| Instance choice | Fixed per node group; CA picks a group with an expander (random, least-waste, priority, price…) | Any type matching NodePool requirements, chosen per batch of pending pods | Karpenter-based NodePools (built-in + custom) |
| Many instance types | One node group per shape, or mixed-instance ASGs that must have similar sizes | Hundreds of types in one NodePool; launch request carries up to 60 cheapest candidates | Same as Karpenter |
| Spot | Per-ASG mixed instances policy | Spot and on-demand in one NodePool; spot uses `price-capacity-optimized`, on-demand `lowest-price` | Supported, managed |
| Scale-down | Removes underutilized nodes after a delay (default 10 min) | Consolidation: delete **or replace** with a cheaper node; budgets; `consolidateAfter` | Karpenter consolidation |
| Upgrades / AMIs | Update the node group yourself | Drift: changed AMI/config → node replaced, paced by budgets | Automatic, nodes max 21 days old |
| Version coupling | Release per Kubernetes minor | Supported range (1.14.1: K8s 1.26–1.36) | Managed |
| OS / customization | Whatever the node group uses | AL2023, Bottlerocket, Windows, custom AMIs, kubelet tuning, user data | Bottlerocket only, no SSH/SSM, locked down |
| Price | Free (you pay EC2) | Free (you pay EC2) | EC2 + per-instance management fee |
| Fits best | Static, well-known node groups | Full control, many shapes, spot-heavy, cost focus | Teams that want AWS to run the data plane |

One-line version: **CA scales groups of identical nodes; Karpenter launches the right individual node for the pods that are waiting; Auto Mode is AWS running Karpenter for you.**

### The control loop

```text
 Pod created ──► kube-scheduler: no node fits ──► Pod Pending (PodScheduled=False, Unschedulable)
                                                          │
                                                          ▼
 ┌──────────────────── Karpenter provisioner ─────────────────────────────────────────────┐
 │ 1. Watch unschedulable pods                                                            │
 │ 2. Batch: wait until no new pod for batchIdleDuration (1s), max batchMaxDuration (10s) │
 │ 3. Scheduling simulation: existing nodes + in-flight NodeClaims first, then NodePools   │
 │    by weight; requirements, taints/tolerations, affinity, topology spread, limits,     │
 │    DaemonSet overhead, maxPods                                                         │
 │ 4. Create NodeClaim(s) with every compatible instance type (cheapest first)            │
 └────────────────────────────────────────────────────────────────────────────────────────┘
                                                          │
                                                          ▼
 NodeClaim ──► EC2 CreateFleet (type instant, ≤60 cheapest types, all allowed AZs)
            ──► Launched       (instance exists; type/zone/capacity-type labels set)
            ──► Registered     (kubelet joined; karpenter.sh/unregistered taint removed)
            ──► Initialized    (node Ready, startup taints gone, resources registered)
            ──► kube-scheduler binds the pending pods to the new node
```

Key points:
- Karpenter **does not bind pods**. It nominates (`Nominated` event: `Pod should schedule on: nodeclaim/...`) and the normal kube-scheduler binds once the node is Ready.
- One NodeClaim lists many instance types. EC2 Fleet picks the final one: for spot, `price-capacity-optimized` (cheap and deep pools); for on-demand, `lowest-price`. When both are allowed Karpenter launches **spot** first and falls back to on-demand on capacity errors (priority reserved > spot > on-demand).
- Failed offerings (`InsufficientInstanceCapacity`, vCPU limit…) are cached as unavailable for 3 minutes and Karpenter retries with the rest.
- The same simulation runs in reverse for **disruption**: "if I delete or replace this node, do its pods fit elsewhere, and is it cheaper?"

### The CRDs

```text
  NodePool "default"  (karpenter.sh/v1)              EC2NodeClass "default" (karpenter.k8s.aws/v1)
  - requirements (arch, capacity-type,     ───ref──► - role / instance profile
    instance-category, cpu, generation)              - amiSelectorTerms (alias al2023@v...)
  - limits.cpu                                       - subnet / security-group selectors
  - disruption (consolidation, budgets)              - kubelet (maxPods), tags, block devices
  - expireAfter, taints, labels, weight
          │ creates
          ▼
  NodeClaim "default-xxxxx" (karpenter.sh/v1, one per node, immutable spec)
          │ becomes
          ▼
  Node "ip-10-0-x-y.ap-south-1.compute.internal"  +  EC2 instance i-...
```

- **NodePool**: *what* nodes are allowed and *how* they are disrupted. Cloud-neutral (core project).
- **EC2NodeClass**: *how* to launch on AWS. Provider-specific.
- **NodeClaim**: Karpenter's record of one requested node. Created by Karpenter, not by you. Deleting it drains and terminates the node.
- Two more CRDs ship with 1.14.1 behind alpha gates: `NodeOverlay` (`karpenter.sh/v1alpha1`) and `CapacityBuffer` (`autoscaling.x-k8s.io/v1beta1`). Module 14 covers them.

### History

- Built by AWS; v0.5 announced as production-ready and open source in November 2021.
- The cloud-neutral core moved to `kubernetes-sigs/karpenter` under SIG Autoscaling; AWS code lives in `aws/karpenter-provider-aws`. Azure has its own provider.
- **v1.0** (2024) made the `v1` APIs stable: NodePool/EC2NodeClass/NodeClaim, drift GA, kubelet settings moved to EC2NodeClass, AMI aliases.
- Since then: NodeRepair (1.1), reserved capacity / ODCR (1.3, beta 1.6), NodeOverlay and static capacity (1.7–1.8), `limits.nodes` (1.11), do-not-disrupt durations (1.12), CapacityBuffer (1.13).
- **v1.14.0** (July 2026, LTS until July 2027) added `consolidationPolicy: Balanced`. **v1.14.1** (August 2026) is a patch with CVE fixes. Supports Kubernetes 1.26–1.36, so we run EKS 1.36.

## Demo

Mostly whiteboard. Two read-only commands make the "before" state concrete. The CRD and API checks happen in module 03, after install.

### Step 1 — Load the environment
```bash
source scripts/env.sh
```
Expected: the variable summary from module 00.

### Step 2 — Show that nothing autoscales today
There is no Cluster Autoscaler and no Karpenter yet.
```bash
kubectl get deploy -A
```
Expected: five deployments, all ready: `kube-system/coredns 2/2`, `kube-system/metrics-server 2/2`, and in `monitoring` `kube-prometheus-stack-grafana`, `-kube-state-metrics`, `-operator` (each `1/1`). No `cluster-autoscaler`, no `karpenter`.

Note: if CAST AI is connected read-only (sibling castai-demo course), you also see `castai-agent/castai-agent` and `castai-agent/castai-agent-cpvpa` (`1/1`) and six `shop` deployments at `0/0`. Neither is an autoscaler.

### Step 3 — Show the one node and its capacity
This node is all the cluster has. A pod that does not tolerate its taint can never run.
```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,TAINTS:.spec.taints[*].key'
```
Expected:
```text
NAME                                         TYPE        CPU     MEM         TAINTS
ip-10-0-19-127.ap-south-1.compute.internal   t3a.large   1930m   7272360Ki   CriticalAddonsOnly
```
One row: 1930m of 2000m CPU and `7272360Ki` (≈ 6.9 GiB of 8 GiB) memory are allocatable after kube-reserved and eviction thresholds. Node name differs.

## Talking points
- "Cluster Autoscaler asks: which group should get one more node? Karpenter asks: what single node would make these pending pods fit at the lowest price?"
- "No node groups means no pre-planning of shapes. You describe constraints; Karpenter picks the instance."
- "Karpenter works in batches. A burst of 50 pods inside a few seconds becomes a few right-sized nodes, not 50 decisions."
- "Karpenter never binds pods. If you ever see a node that Karpenter launched but pods are not on it, look at the scheduler, taints and affinity."
- "Auto Mode is the same engine run by AWS. Everything you learn today about NodePools and disruption carries over."

## Reset
Nothing in this module changes the cluster.

## Q&A prep
- **Can CA and Karpenter run together?** Technically yes on separate node groups, but they will fight over the same pods. Migrate node group by node group and scale CA's groups to zero.
- **Does Karpenter need ASGs or launch templates?** No ASGs. Karpenter creates and manages its own launch templates from the EC2NodeClass.
- **Is Karpenter AWS-only?** No. The core is cloud-neutral; AWS and Azure have providers.
- **Why not just use Auto Mode?** Auto Mode is simpler but restricts the OS (Bottlerocket only), access (no SSH/SSM) and some tuning, and adds a per-instance fee. Self-managed Karpenter gives full control.
- **How fast is a scale-up?** Typically 30–60 s from Pending pod to Ready node on AL2023 (about 30 s measured on this cluster). Most of it is EC2 boot and kubelet join, not Karpenter.
- **What is "price-capacity-optimized"?** An EC2 Fleet spot allocation strategy that picks pools with low interruption risk and low price, rather than only the cheapest pool.

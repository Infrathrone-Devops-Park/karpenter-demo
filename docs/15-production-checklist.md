# 15 — Production Checklist and Wrap-up

**Time:** 15 min · **Goal:** Turn everything from the course into a checklist a team can apply to a real cluster, and know when Karpenter is the wrong tool.

## What you'll show

- What this demo cluster does differently from production, and why.
- A checklist: HA, IAM, AMIs, disruption safety, workload hygiene, Spot, limits, monitoring, upgrades, cost.
- How to migrate from Cluster Autoscaler.
- When not to use Karpenter.
- Links for further reading.

## Concepts

### Demo vs production

| Area | This demo | Production |
|---|---|---|
| Controller replicas | 1 (only one non-Karpenter node) | **2**, chart default, with PDB `maxUnavailable: 1` |
| Where Karpenter runs | 1 x t3a.large managed node group | MNG with ≥ 2 nodes in ≥ 2 AZs, or Fargate (IRSA, since Pod Identity does not work on Fargate) |
| AMI | `al2023@v20260930` pinned | Pinned, promoted through environments, rolled with drift budgets |
| Limits | `cpu: 10` to fit an 8+8 vCPU quota | Sized to budget and quotas, alerts at 80% |
| Feature gates | Toggled live for teaching | Only what you need, changed through normal release process |
| Monitoring | kube-prometheus-stack on one node, 6 h retention | Managed Prometheus / long retention, alerts routed to on-call |

### Checklist

**1. Controller availability**
- `replicas: 2` (chart default), leader election on, PDB from the chart.
- Never on Karpenter-managed nodes: the chart affinity `karpenter.sh/nodepool DoesNotExist` enforces it. Use an MNG or Fargate.
- Requests = limits for CPU and memory (the guide uses 1 CPU / 1 Gi); `priorityClassName: system-cluster-critical` (chart default).
- Install in `kube-system` to get the API Priority and Fairness flow schemas.
- CoreDNS must not depend on Karpenter capacity (or set `dnsPolicy: Default`).

**2. IAM least privilege**
- Controller: the 6 scoped policies (NodeLifecycle, IAMIntegration, EKSIntegration, Interruption, ResourceDiscovery, ZonalShift). Every create/terminate is conditioned on tags `kubernetes.io/cluster/<name>=owned` and `karpenter.sh/nodepool`.
- Node role: `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy` (or CNI via Pod Identity), `AmazonEC2ContainerRegistryPullOnly`, optional `AmazonSSMManagedInstanceCore`.
- Node access via EKS access entry type `EC2_LINUX`.
- Keep IMDSv2 required and hop limit 1. Pods get AWS credentials from Pod Identity / IRSA, never from the node.
- The Spot service-linked role must exist before the first Spot launch.

**3. AMIs and drift**
- Pin `amiSelectorTerms` (alias version, `id`, or CI-promoted `tags`). Test new AMIs in a lower environment first.
- Roll forward by changing the pin. Drift replaces nodes; pace it with budgets:
  `budgets: [{nodes: "10%"}, {nodes: "0", schedule: "0 9 * * mon-fri", duration: 8h, reasons: [Drifted]}]`.
- Set `expireAfter` (default 720h) so no node lives forever, and `terminationGracePeriod` so a stuck drain cannot block replacement forever.
- Remember: control-plane upgrades also drift nodes (aliases resolve per Kubernetes version).

**4. Disruption safety for workloads**
- PDBs on every multi-replica service. Karpenter respects them on every voluntary drain.
- `karpenter.sh/do-not-disrupt: "true"` (or a duration like `"30m"`) for jobs that must not be interrupted. It does not stop expiration, interruption or repair.
- Graceful shutdown: handle SIGTERM, keep `terminationGracePeriodSeconds` below the Spot 2-minute warning for Spot workloads.
- Prefer `topologySpreadConstraints` with `DoNotSchedule` for zone spread; `ScheduleAnyway` and preferred anti-affinity can block consolidation.

**5. Requests and limits hygiene**
- Every pod sets CPU and memory **requests**. Karpenter sizes nodes from requests only; actual usage is invisible to it.
- Memory limit = request for critical services (avoids OOM after bin-packing).
- Watch DaemonSet overhead: it is added to every node.
- Use VPA recommendations / Goldilocks to right-size, then let consolidation remove the slack.

**6. Spot**
- Diverse requirements: several categories, generations and sizes, all AZs. Aim for **15+** instance types per pool (also the SpotToSpotConsolidation floor).
- Allow `on-demand` as fallback in the same NodePool unless the workload must never run on-demand.
- Configure the interruption queue (module 10). Do not run Node Termination Handler in queue mode.
- Keep stateful and single-replica workloads on on-demand (separate NodePool with a taint, or `capacity-type` selector).

**7. Limits and blast radius**
- Every NodePool has `limits` (`cpu`, `memory`, and since 1.11 `nodes`). This is your runaway-cost brake.
- Separate NodePools per team or workload class, mutually exclusive via taints or requirements, with `weight` for preferences (for example a Savings Plan pool first).
- Check Service Quotas (On-Demand Standard vCPUs, Spot vCPUs) against the sum of limits.

**8. Monitoring and alerts** (module 12, `manifests/12-observability/karpenter-alerts.yaml`)
- Controller up; pods unschedulable for > 5 min; launch failures by reason; NodePool usage > 80% of limit; cloud provider errors; NodeClaims not Ready > 15 min.
- Dashboards: Karpenter Capacity and Performance.
- Ship JSON logs centrally; alert on `ERROR` rate.
- Track cost: `karpenter_nodepools_cost_total`, Spot percentage, cluster utilization.

**9. Upgrades**
- Read the upgrade guide for every minor (https://karpenter.sh/docs/upgrading/upgrade-guide/). LTS releases (v1.9, v1.14) get 12 months of support.
- Order: IAM changes → **`karpenter-crd` chart** → `karpenter` chart (same version) → verify.
- Check the compatibility matrix before upgrading EKS: Karpenter 1.14.1 supports Kubernetes up to 1.36.
- Upgrade in a lower environment first; watch for drift caused by the upgrade itself (for example the 1.12 CA-bundle hash).
- Keep the chart pinned (`--version`), never `latest`.

**10. Cost**
- Consolidation `WhenEmptyOrUnderutilized` with a sensible `consolidateAfter` (minutes, not seconds, for busy clusters); or `Balanced` (1.14) when churn matters more than the last dollar.
- Spot for stateless; Savings Plans for the steady base (and NodeOverlay to tell Karpenter about them).
- Graviton (arm64) when images are multi-arch.
- Right-size requests: Karpenter cannot save money on reserved but unused CPU.

### Migrating from Cluster Autoscaler

```text
1. Prepare IAM (controller + node role), SQS queue + EventBridge rules, discovery tags on subnets/SGs, node access entry.
2. Install Karpenter (CRDs, then controller) on the existing managed node group.
3. Create EC2NodeClass + NodePool(s) that mirror your node groups (labels, taints, AMI, instance families).
4. Scale Cluster Autoscaler to 0 replicas (so they do not fight).
5. Lower the MNG desired/min size gradually; pods move to Karpenter nodes. Watch PDBs.
6. Keep a small MNG (2+ nodes) for Karpenter, CoreDNS and other critical add-ons.
7. Remove Cluster Autoscaler and its IAM once stable; remove ASG tags.
```

### When not to use Karpenter

- Non-AWS or on-prem clusters without a Karpenter provider (AWS and Azure have production providers; others vary).
- Very small, static clusters where 2–3 fixed nodes never change: an MNG is simpler.
- You want AWS to run it for you: **EKS Auto Mode** is Karpenter-based and managed (Bottlerocket only, 21-day max node lifetime, extra per-instance fee).
- Workloads that need node-level state preserved across replacement and cannot tolerate any disruption, unless you disable consolidation/expiry for those pools.
- Teams without capacity to own another controller, its IAM and its upgrades.

## Demo

### Step 1 — Load the environment
```bash
source scripts/env.sh
kubectl get nodepools,ec2nodeclasses,nodeclaims
```
Expected: BASELINE (`default` only, no NodeClaims).

### Step 2 — Render what a production install would deploy (local only)
`helm template` renders the chart locally; nothing reaches the cluster.
```bash
helm template karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" \
  --namespace kube-system \
  --values manifests/15-production/karpenter-values-production.yaml \
  --set settings.clusterName=example \
  | grep -E '^kind:|replicas:|maxUnavailable:|topologyKey:|key: karpenter.sh/nodepool'
```
Expected: `kind: PodDisruptionBudget` with `maxUnavailable: 1`, then ServiceAccount, 3 ClusterRoles, 2 ClusterRoleBindings, 2 Roles, 2 RoleBindings, `kind: Service`, `kind: Deployment` with `replicas: 2`, the rolling-update `maxUnavailable: 1`, `key: karpenter.sh/nodepool` (DoesNotExist affinity), `topologyKey: kubernetes.io/hostname` (anti-affinity) and `topologyKey: topology.kubernetes.io/zone` (spread). No ServiceMonitor appears: the chart only renders it when the cluster has the `monitoring.coreos.com/v1` API, which a local render cannot see.

### Step 3 — Compare with what this demo runs
```bash
helm get values karpenter -n kube-system -o yaml
kubectl -n kube-system get pdb karpenter
```
Expected: `replicas: 1`, the `karpenter.sh/controller: "true"` nodeSelector, `serviceMonitor.enabled: true`, plus the three settings. PDB `karpenter` with `MAX UNAVAILABLE 1`, `ALLOWED DISRUPTIONS 1` (with one replica the PDB protects nothing, another reason to run two).

### Step 4 — Audit the live NodePool against the checklist
```bash
kubectl get nodepool default -o json | jq '{limits: .spec.limits, budgets: .spec.disruption.budgets, consolidation: .spec.disruption.consolidationPolicy, after: .spec.disruption.consolidateAfter, expireAfter: .spec.template.spec.expireAfter, tgp: .spec.template.spec.terminationGracePeriod}'
kubectl get ec2nodeclass default -o json | jq '{ami: .spec.amiSelectorTerms, imds: .spec.metadataOptions}'
```
Expected: `limits {"cpu":"10"}`, budgets `[{"nodes":"10%"}]` (CRD default), `WhenEmptyOrUnderutilized`, `1m`, `720h`, `tgp null` (production: set one). AMI pinned `al2023@v20260930`; IMDS `httpTokens required`, hop limit `1`.

### Step 5 — Check the quotas the limits must respect
```bash
for q in L-1216C47A L-34B43A08; do
  aws service-quotas get-service-quota --service-code ec2 --quota-code "$q" --query 'Quota.[QuotaName,Value]' --output text
done
```
Expected: `Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances  8.0` and `All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests  8.0`.

### Step 6 — Show which workloads lack requests (hygiene check)
```bash
kubectl get pods -A -o json | jq -r '.items[] | select([.spec.containers[].resources.requests.cpu] | any(. == null)) | "\(.metadata.namespace)/\(.metadata.name)"' | head -10
```
Expected: three system pods without CPU requests: `kube-system/eks-pod-identity-agent-…`, `monitoring/kube-prometheus-stack-grafana-…`, `monitoring/prometheus-kube-prometheus-stack-prometheus-0`. Any app pod here is a Karpenter sizing risk.

## Talking points

- Karpenter is only as good as your **requests**, your **PDBs** and your **requirements diversity**.
- Run the controller where it cannot remove itself: 2 replicas on an MNG or Fargate.
- Pin AMIs, roll with drift + budgets, and always set `expireAfter`.
- Every NodePool needs limits; every limit needs an alert before it is hit.
- Upgrade CRDs first, read the upgrade guide, stay on an LTS line (v1.14 until mid-2027).
- Karpenter makes decisions in seconds; your monitoring should tell you about bad ones in minutes.
- Wrap-up: we covered install, NodePools, scheduling, consolidation, drift, Spot interruption, EC2NodeClass, observability, troubleshooting, feature gates and this checklist.

## Reset

Nothing to reset: this module only reads state and renders templates locally.
```bash
scripts/reset.sh
```
After the session, park the cluster:
```bash
scripts/downscale.sh
```

## Q&A prep

- **Karpenter vs EKS Auto Mode?** Auto Mode = AWS-managed Karpenter plus managed add-ons, Bottlerocket only, no SSH, 21-day node lifetime, extra fee. Self-managed Karpenter = full control (AMIs, kubelet, user data, gates).
- **Can Karpenter and Cluster Autoscaler run together?** Only on disjoint node groups, and only during migration. Never let both scale the same workloads.
- **How many NodePools?** As few as possible: one general pool plus pools that need different taints, capacity types or limits. Many tiny pools hurt bin-packing.
- **How fast is a node in production?** Typically 45–90 s from pending pod to Ready node on AL2023, less with Bottlerocket and cached images.
- **What breaks most often?** Missing requests, PDBs that never allow eviction, and too-narrow instance requirements on Spot.
- **Where to learn more?**
  - Karpenter docs (v1.14): https://karpenter.sh/v1.14/
  - Upgrade guide: https://karpenter.sh/docs/upgrading/upgrade-guide/
  - Compatibility matrix: https://karpenter.sh/docs/upgrading/compatibility/
  - Troubleshooting: https://karpenter.sh/docs/troubleshooting/
  - EKS Best Practices, Karpenter: https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html
  - Source and releases: https://github.com/aws/karpenter-provider-aws and https://github.com/kubernetes-sigs/karpenter
  - Terraform module: https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest/submodules/karpenter
  - eks-node-viewer: https://github.com/awslabs/eks-node-viewer

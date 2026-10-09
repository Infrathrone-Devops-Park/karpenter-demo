# 03 — Install Karpenter
**Time:** 25 min · **Goal:** Install Karpenter v1.14.1 with Helm, verify it is healthy and talking to AWS, then create the default EC2NodeClass and NodePool.

## What you'll show
- The Helm values file and why each value is set.
- Installing the `karpenter-crd` and `karpenter` charts from public ECR (OCI).
- Verifying the pod, the CRDs, the API resources, the Pod Identity credentials, the settings and the logs.
- Applying `manifests/base/ec2nodeclass.yaml` and reading its status (subnets, security groups, AMIs, instance profile).
- Applying `manifests/base/nodepool.yaml` and checking it is Ready.

`scripts/install-karpenter.sh` does steps 3–6 in one go. Here we run them by hand so the audience sees each piece.

## Concepts

### Install order
1. `kube-prometheus-stack` is already installed (`scripts/install-monitoring.sh`, done during setup). It must come first: the Karpenter chart only renders its `ServiceMonitor` when the `monitoring.coreos.com/v1` API exists (`.Capabilities.APIVersions.Has`). Installed in the other order, Karpenter would run fine but Prometheus would never scrape it.
2. `karpenter-crd` chart: the CRDs as normal templates, so `helm upgrade` can update them later. (CRDs in a chart's `crds/` folder are only installed once and never upgraded.)
3. `karpenter` chart: controller Deployment, Service, RBAC, PDB, ServiceMonitor. **No webhooks** in 1.14.1.

### Values file (`manifests/03-install/karpenter-values.yaml`)

| Value | Our setting | Chart default | Why |
|---|---|---|---|
| `replicas` | `1` | `2` | Only one non-Karpenter node. The default affinity (`karpenter.sh/nodepool DoesNotExist` + hostname anti-affinity) would leave a second replica Pending forever. |
| `nodeSelector` | `karpenter.sh/controller: "true"` (+ default `kubernetes.io/os: linux`, maps merge) | `kubernetes.io/os: linux` | Pin the controller to the system node group. |
| `tolerations` | `CriticalAddonsOnly Exists` | same | Kept explicit; the system node is tainted with it. |
| `dnsPolicy` | `ClusterFirst` | same | CoreDNS runs on the system node, not on Karpenter capacity, so cluster DNS is up before Karpenter needs it. `Default` is only needed when CoreDNS itself depends on Karpenter nodes. |
| `logLevel` | `info` | same | Shows the provisioning and disruption lines we want; `debug` is for module 13. |
| `controller.resources` | requests `250m` / `512Mi`, limit memory `1Gi` | `{}` | Fits next to monitoring on a 2-vCPU t3a.large. The docs suggest 1 CPU / 1Gi for real clusters. `GOMEMLIMIT` is derived from the memory limit. |
| `serviceMonitor.enabled` | `true` | `false` | Prometheus scrapes `:8080/metrics` (port `http-metrics`). Our Prometheus selects all ServiceMonitors, so no `release` label is needed. |
| `settings.clusterName` | `--set` from `$CLUSTER_NAME` | `""` | **Required**; the chart refuses to install without it. |
| `settings.clusterEndpoint` | `--set` from `$CLUSTER_ENDPOINT` | `""` | Optional (discovered via DescribeCluster), explicit is faster and clearer. |
| `settings.interruptionQueue` | `--set` from `$KARPENTER_QUEUE` | `""` | Enables interruption handling. Empty means disabled. |
| `featureGates.*` | defaults | `reservedCapacity=true`, rest `false` | Module 14 turns some on. |

The chart default topology spread (`topology.kubernetes.io/zone`, `maxSkew 1`, `DoNotSchedule`) is harmless with one replica on one node: skew is 0. Rolling updates also work on one node: `maxUnavailable: 1` lets the old pod stop before the new one is scheduled, which the hostname anti-affinity requires. Expect ~20–40 s with no controller during an upgrade.

### Base manifests

`manifests/base/ec2nodeclass.yaml` — **how** to launch on AWS:

| Field | Value | Meaning |
|---|---|---|
| `spec.role` | `karpenter-demo-karpenter-node` | IAM role for the nodes. Karpenter creates and manages the instance profile for it. |
| `spec.amiSelectorTerms[0].alias` | `al2023@v20260930` | Amazon Linux 2023 EKS-optimized AMI, **pinned** release. Resolved through public SSM parameters for the cluster's Kubernetes version (1.36). `@latest` would drift nodes whenever AWS publishes a new AMI; module 09 bumps this on purpose. |
| `spec.subnetSelectorTerms[0].tags` | `karpenter.sh/discovery: karpenter-demo` | Launch only into the three tagged private subnets. |
| `spec.securityGroupSelectorTerms[0].tags` | same tag | Attach only the tagged node SG. |
| `spec.kubelet.maxPods` | `110` | Prefix delegation is on, but Karpenter cannot detect it. Without this Karpenter assumes ENI-limited pods (29 on `*.large`). Also feeds kube-reserved memory (`11 × maxPods + 255` Mi). |
| `spec.tags` | `Project: karpenter-demo` | Extra tags on instances, volumes, launch templates. Karpenter always adds `karpenter.sh/nodepool`, `karpenter.sh/nodeclaim`, `karpenter.k8s.aws/ec2nodeclass`, `eks:eks-cluster-name`, `kubernetes.io/cluster/karpenter-demo: owned`, `Name`. |
| (defaults) | root volume 20Gi gp3 encrypted; IMDSv2 required, hop limit 1 | Not set, so Karpenter's defaults apply. |

`manifests/base/nodepool.yaml` — **what** nodes are allowed and **how** they are disrupted:

| Field | Value | Meaning |
|---|---|---|
| `spec.template.spec.nodeClassRef` | `karpenter.k8s.aws` / `EC2NodeClass` / `default` | Which EC2NodeClass to launch with. `group`/`kind` are required and immutable. |
| requirement `kubernetes.io/arch In [amd64]` | | No Graviton (house rule; images are x86). |
| requirement `kubernetes.io/os In [linux]` | | Linux only. |
| requirement `karpenter.sh/capacity-type In [spot, on-demand]` | | Both allowed; Karpenter tries spot first and falls back to on-demand. |
| requirement `karpenter.k8s.aws/instance-category In [c, m, r]` | | Compute, general, memory families. Burstable `t` excluded (also gen 3). |
| requirement `karpenter.k8s.aws/instance-cpu In ["2", "4"]` | | Small nodes only, so one replacement fits in the 8-vCPU quotas. |
| requirement `karpenter.k8s.aws/instance-generation Gt 4` | | Generation 5 and newer (c5, m6a, r7i…). Note: `t3`/`t3a` are generation 3, so this rule actually excludes the `t` category (the `t` entry is inert). |
| `spec.template.spec.expireAfter` | `720h` | Nodes are replaced after 30 days (the default, written explicitly). |
| `spec.limits.cpu` | `"10"` | Stop launching once Karpenter-owned capacity in this NodePool reaches 10 vCPU. Quota guard. |
| `spec.disruption.consolidationPolicy` | `WhenEmptyOrUnderutilized` | Delete empty nodes and delete/replace underutilized ones (the default). |
| `spec.disruption.consolidateAfter` | `1m` | A node must be unchanged for 1 minute before it is a consolidation candidate. Default is `0s`; 1m keeps the demo watchable. |
| `spec.disruption.budgets` | not set → `[{nodes: "10%"}]` | At most 10% of nodes (rounded up, so at least 1) disrupted voluntarily at once. |

## Demo

### Step 1 — Load the environment and show the values file
```bash
source scripts/env.sh
cat manifests/03-install/karpenter-values.yaml
```
Expected: the variable summary, then the values file (replicas 1, nodeSelector, tolerations, dnsPolicy, logLevel, controller resources, serviceMonitor).

### Step 2 — Prerequisites: monitoring CRD and spot service-linked role
The ServiceMonitor needs the CRD; the first spot launch needs the EC2 Spot service-linked role.
```bash
kubectl get crd servicemonitors.monitoring.coreos.com
aws iam get-role --role-name AWSServiceRoleForEC2Spot --query Role.Arn --output text || aws iam create-service-linked-role --aws-service-name spot.amazonaws.com --query Role.Arn --output text
```
Expected: `servicemonitors.monitoring.coreos.com` with its creation date; then `arn:aws:iam::146725924014:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot` (already exists in this account; if it did not exist yet, an error line from `get-role` appears first and then the create call prints the same ARN).

### Step 3 — Install the CRDs
Public ECR needs no login; a stale saved login causes 403, so log out first.
```bash
helm registry logout public.ecr.aws || true
helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd --version "$KARPENTER_VERSION" --namespace "$KARPENTER_NAMESPACE"
```
Expected: logout prints `Removing login credentials for public.ecr.aws`, or, when you were not logged in, `Error: failed to delete the credential for public.ecr.aws: credentials not found in native keychain` (both fine). Then, in about 3 s:
```text
Release "karpenter-crd" does not exist. Installing it now.
Pulled: public.ecr.aws/karpenter/karpenter-crd:1.14.1
Digest: sha256:c05c566740802506a34f3500b33e2fa3c9254f60469e84e5e294a3bd8adefb9f
NAME: karpenter-crd
...
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
```
On a re-run (Karpenter already installed) the same command prints `Release "karpenter-crd" has been upgraded. Happy Helming!`, `REVISION: 2` (or higher) and `DESCRIPTION: Upgrade complete`. That is safe: `upgrade --install` is idempotent.

### Step 4 — Install the controller
```bash
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version "$KARPENTER_VERSION" --namespace "$KARPENTER_NAMESPACE" --values manifests/03-install/karpenter-values.yaml --set "settings.clusterName=$CLUSTER_NAME" --set "settings.clusterEndpoint=$CLUSTER_ENDPOINT" --set "settings.interruptionQueue=$KARPENTER_QUEUE"
```
Expected: `Release "karpenter" does not exist. Installing it now.`, `Pulled: public.ecr.aws/karpenter/karpenter:1.14.1`, `Digest: sha256:91434e00fb102d6ee0d1bd34a4457a32fe01a8fa833fe1a2a37da4f50272079b`, `STATUS: deployed`, `REVISION: 1`, returned in about 3 s. On a re-run: `has been upgraded. Happy Helming!` and a higher `REVISION`; with unchanged values the pod is **not** restarted. Helm 4 does not wait for pods by default (`--wait` defaults to `hookOnly`), so we wait explicitly next.

### Step 5 — Wait for the pod
```bash
kubectl -n kube-system rollout status deploy/karpenter --timeout=180s
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter -o wide
```
Expected: `Waiting for deployment "karpenter" rollout to finish: 0 of 1 updated replicas are available...`, then `deployment "karpenter" successfully rolled out` after about 15–20 s. One pod `karpenter-<hash>-<id>` `1/1 Running`, `NODE` = the system node. Now start watch panes 2 and 3 (`scripts/watch.sh claims`, `scripts/watch.sh logs`).

### Step 6 — CRDs and API resources
```bash
kubectl get crd | grep -E 'karpenter|capacitybuffers'
kubectl api-resources --api-group=karpenter.sh
kubectl api-resources --api-group=karpenter.k8s.aws
```
Expected: five CRDs: `capacitybuffers.autoscaling.x-k8s.io`, `ec2nodeclasses.karpenter.k8s.aws`, `nodeclaims.karpenter.sh`, `nodeoverlays.karpenter.sh`, `nodepools.karpenter.sh`. `karpenter.sh` lists `nodeclaims`, `nodeoverlays` (short name `overlays`, `v1alpha1`), `nodepools`, all `NAMESPACED false`. `karpenter.k8s.aws` lists `ec2nodeclasses` with short names `ec2nc,ec2ncs`.

### Step 7 — Credentials and settings the pod received
Pod Identity injects credential env vars; the chart turns `settings.*` into env vars.
```bash
kubectl -n kube-system get pod -l app.kubernetes.io/name=karpenter -o jsonpath='{range .items[0].spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep -E '^(CLUSTER_NAME|CLUSTER_ENDPOINT|INTERRUPTION_QUEUE|FEATURE_GATES|LOG_LEVEL|AWS_CONTAINER_CREDENTIALS_FULL_URI)='
kubectl -n kube-system get servicemonitor karpenter
```
Expected:
```text
LOG_LEVEL=info
FEATURE_GATES=ReservedCapacity=true,SpotToSpotConsolidation=false,NodeRepair=false,NodeOverlay=false,StaticCapacity=false,CapacityBuffer=false
CLUSTER_NAME=karpenter-demo
CLUSTER_ENDPOINT=https://<id>.gr7.ap-south-1.eks.amazonaws.com
INTERRUPTION_QUEUE=Karpenter-karpenter-demo
AWS_CONTAINER_CREDENTIALS_FULL_URI=http://169.254.170.23/v1/credentials
```
and the ServiceMonitor `karpenter` with its age. `AWS_CONTAINER_CREDENTIALS_FULL_URI` is injected by the EKS Pod Identity webhook only when an association matches the pod's namespace and service account, so its presence proves the association works.

### Step 8 — Logs: started, leader, no errors
Karpenter logs JSON; at `info` level startup is quiet. Queue/endpoint discovery lines are debug-only.
```bash
kubectl -n kube-system logs deploy/karpenter -c controller --tail=300 | jq -rR 'fromjson? | select((.message | test("lease|Serving metrics")) or (.message=="Starting workers" and (.controller | test("^(provisioner|disruption|interruption|nodeclaim.lifecycle)$")))) | [.time, .message, (.controller // .lock // .bindAddress // "")] | @tsv'
kubectl -n kube-system logs deploy/karpenter -c controller --tail=300 | jq -rR 'fromjson? | select(.level=="ERROR") | .message'
```
Expected (timestamps differ):
```text
2026-10-09T16:16:36.443Z  Serving metrics server          :8080
2026-10-09T16:16:37.544Z  Attempting to acquire leader lease...  kube-system/karpenter-leader-election
2026-10-09T16:16:37.564Z  Successfully acquired lease     kube-system/karpenter-leader-election
2026-10-09T16:16:37.565Z  Starting workers                provisioner
2026-10-09T16:16:37.569Z  Starting workers                disruption
2026-10-09T16:16:37.593Z  Starting workers                interruption
2026-10-09T16:16:38.782Z  Starting workers                nodeclaim.lifecycle
```
The full startup is about 160 lines: ~58 `Starting EventSource`, ~49 `Starting Controller` / `Starting workers` pairs (one per controller). After a rehearsal uninstall, `Successfully acquired lease` can come ~15 s after `Attempting` (the old lease must expire first). The `interruption` controller starting means the queue is configured. Second command prints **nothing**. An error mentioning `QueueDoesNotExist` or `AccessDenied` means a wrong queue name or a broken Pod Identity association.

### Step 9 — Apply the EC2NodeClass
```bash
cat manifests/base/ec2nodeclass.yaml
kubectl apply -f manifests/base/ec2nodeclass.yaml
kubectl wait ec2nodeclass/default --for=condition=Ready --timeout=120s
```
Expected: `ec2nodeclass.karpenter.k8s.aws/default created`, then `ec2nodeclass.karpenter.k8s.aws/default condition met` within about 15 s (13 s measured). Pane 3 shows five `discovered ssm parameter` lines, one per AMI variant, e.g. `"parameter":"/aws/service/eks/optimized-ami/1.36/amazon-linux-2023/x86_64/standard/amazon-eks-node-al2023-x86_64-standard-1.36-v20260930/image_id","value":"ami-067d27d47f88c442a"`.

### Step 10 — Read what Karpenter resolved
```bash
kubectl get ec2nodeclass default -o json | jq '.status | {conditions: [.conditions[] | {type, status}], subnets: [.subnets[] | {id, zone}], securityGroups: [.securityGroups[] | {id, name}], amis: [.amis[] | {id, name}], instanceProfile}'
```
Expected (IDs differ):
- `conditions`: `AMIsReady`, `SubnetsReady`, `SecurityGroupsReady`, `InstanceProfileReady`, `ValidationSucceeded`, `PlacementGroupReady`, `CapacityReservationsReady` (reserved capacity gate is on by default) and `Ready`, all `"True"` (order may differ).
- `subnets`: 3 entries, zones `ap-south-1a/b/c`.
- `securityGroups`: 1 entry, name `karpenter-demo-node-...`.
- `amis`: five entries, all `-1.36-v20260930`: `amazon-eks-node-al2023-x86_64-standard-...`, `-arm64-standard-...`, `-x86_64-neuron-...`, `-arm64-nvidia-...`, `-x86_64-nvidia-...`. The NodePool's `amd64` requirement and the instance type (no GPU/Neuron) select `x86_64-standard` (`ami-067d27d47f88c442a` in ap-south-1).
- `instanceProfile`: a name generated by Karpenter, `karpenter-demo_<number>` (cluster name plus a hash, e.g. `karpenter-demo_9299248092360466610`).

### Step 11 — Apply the NodePool
```bash
cat manifests/base/nodepool.yaml
kubectl apply -f manifests/base/nodepool.yaml
kubectl wait nodepool/default --for=condition=Ready --timeout=60s
kubectl get nodepools -o wide
```
Expected: `nodepool.karpenter.sh/default created`, `condition met` (under 1 s), then:
```text
NAME      NODECLASS   NODES   READY   AGE   WEIGHT   CPU   MEMORY
default   default     0       True    1s             0     0
```
`WEIGHT` is empty because none is set; `CPU` and `MEMORY` are the capacity of this NodePool's nodes, `0` until nodes exist.

### Step 12 — Self-documenting API
```bash
kubectl explain nodepool.spec.disruption
kubectl get nodeclaims
```
Expected: field docs for `budgets`, `consolidateAfter` (`-required-`), `consolidationPolicy` (`enum: WhenEmpty, WhenEmptyOrUnderutilized, Balanced`). Then `No resources found`: Karpenter launches nothing until a pod is Pending.

## Talking points
- "Two charts: CRDs separately so they can be upgraded. That is the officially recommended way."
- "Karpenter has no webhooks since v1. Validation is in the CRD schema with CEL, so a bad NodePool is rejected by the API server itself."
- "The pod got AWS credentials without any annotation. That is Pod Identity: the association we saw in module 02 plus the agent DaemonSet."
- "Nothing happened after applying the NodePool. Karpenter is purely reactive: no pending pods, no nodes."
- "The EC2NodeClass status is your first debugging stop: if subnets, SGs, AMIs or the instance profile do not resolve, `Ready` is False and no node will ever launch."
- "Pin the AMI alias in production. `@latest` means every AMI release rolls your whole fleet."

## Reset
Module 03's end state is the start of BASELINE. Make sure the demo namespace and `inflate` exist too (module 04 relies on them):
```bash
kubectl apply -f manifests/base/
kubectl apply -f workloads/namespace.yaml -f workloads/inflate.yaml
kubectl get nodepools,ec2nodeclasses,nodeclaims
kubectl get deploy -n demo
```
Expected: both base objects `unchanged`, `namespace/demo created` and `deployment.apps/inflate created` (or `unchanged`), `default` NodePool and EC2NodeClass `READY True`, no nodeclaims (the API prints nothing for them), `inflate 0/0`.

**Re-running the install** (for example the morning of a later session) is safe: `scripts/install-karpenter.sh` prints `==> karpenter-crd 1.14.1`, `Release "karpenter-crd" has been upgraded. Happy Helming!`, `==> karpenter 1.14.1`, `Release "karpenter" has been upgraded. Happy Helming!` (each `REVISION` +1, `Upgrade complete`), `deployment "karpenter" successfully rolled out` and the same pod with its original age: nothing restarts when values are unchanged. Takes about 11 s.

To rehearse the install from scratch (not during the session), remove Karpenter completely **only when no Karpenter nodes exist**:
```bash
kubectl delete nodepools --all
kubectl delete ec2nodeclasses --all
helm uninstall karpenter -n kube-system
helm uninstall karpenter-crd -n kube-system
```
Expected: NodePool/EC2NodeClass deleted (Karpenter removes its instance profile while still running), then both releases `uninstalled`.

## Q&A prep
- **Why `kube-system`?** Karpenter gets the built-in high-priority API Priority and Fairness flow schemas there. In another namespace you need your own FlowSchemas.
- **Why not `--wait` on helm?** In Helm 4, bare `--wait` means the `watcher` strategy and works; we use `kubectl rollout status` so the output is the same on any Helm version.
- **Why one replica? Isn't that a single point of failure?** For the demo, yes. Karpenter being down only pauses new launches and disruption; running nodes and pods are unaffected. Production: 2 replicas on 2 non-Karpenter nodes in different AZs (leader election picks one active).
- **Do I need `clusterEndpoint`?** No; Karpenter discovers it with `eks:DescribeCluster`. Setting it saves an API call and makes the config explicit.
- **What if `Ready` is False on the EC2NodeClass?** Check which condition is False: `SubnetsReady` (tags), `SecurityGroupsReady` (tags), `AMIsReady` (alias/version, SSM permission), `InstanceProfileReady` (IAM). After fixing IAM, add any annotation to the EC2NodeClass to force re-validation.
- **Where does the AMI ID come from?** Public SSM parameters `/aws/service/eks/optimized-ami/1.36/amazon-linux-2023/...` for the pinned release. Karpenter re-checks every minute.
- **Can I install with Terraform instead?** Yes, a `helm_release` works the same; we show it by hand for teaching.

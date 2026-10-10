# 11 — EC2NodeClass Deep Dive

**Time:** 20 min · **Goal:** Walk every EC2NodeClass field, then launch a Bottlerocket node with custom disks and kubelet reservations and inspect the result without SSH.

## What you'll show

- The full `karpenter.k8s.aws/v1` EC2NodeClass schema, validated live with a server-side dry run.
- `role` vs `instanceProfile`, AMI selection (alias / id / name / tags / owner / ssmParameter), subnet and security group selectors.
- `userData` merge for AL2023 (MIME + NodeConfig) and Bottlerocket (TOML).
- `kubelet` settings and how they change node allocatable.
- `blockDeviceMappings`, `instanceStorePolicy`, `metadataOptions` (IMDSv2, hop limit 1), `detailedMonitoring`, `associatePublicIPAddress`, `tags`, `capacityReservationSelectorTerms`.
- A second EC2NodeClass `bottlerocket` + NodePool `bottlerocket` (limit 2 CPU) + one pod, and how to read `status` (amis, subnets, securityGroups, instanceProfile, conditions).

## Concepts

### NodePool vs EC2NodeClass

```text
NodePool  (karpenter.sh/v1)              EC2NodeClass  (karpenter.k8s.aws/v1)
"WHAT and WHEN"                          "HOW on AWS"
- requirements (type, arch, zone, cap)   - AMI, subnets, security groups
- limits, weight, taints, labels         - IAM role / instance profile
- disruption (consolidation, budgets)    - kubelet, disks, IMDS, user data, tags
          │  spec.template.spec.nodeClassRef ──▶  name: default | bottlerocket
```

Many NodePools can point at one EC2NodeClass. A NodePool is only used when its EC2NodeClass is `Ready`.

### Field reference (v1.14.1)

| Field | What it does | Notes / defaults |
|---|---|---|
| `role` | IAM role name. Karpenter **creates and manages** an instance profile for it | Path `/karpenter/<region>/<cluster>/<nodeclass-uid>/`. Mutable since 1.7. Exactly one of `role` / `instanceProfile` |
| `instanceProfile` | Pre-created instance profile, Karpenter does not touch it | Use when the controller has no IAM write access (private / regulated accounts) |
| `amiSelectorTerms[]` (required, 1–30) | Which AMI to boot | One of: `alias` (exclusive), `id` (exclusive), `ssmParameter`, `name` (+`owner`, default `self,amazon`), `tags`. Terms are ORed; newest matching AMI wins |
| `alias` | `family@version`. Families `al2023`, `bottlerocket`, `al2`, `windows2019`, `windows2022`, `windows2025` | Resolves through public SSM parameters for the **cluster's** K8s version. `@latest` drifts on every AMI release. Pin `al2023@vYYYYMMDD` / `bottlerocket@v1.x.y`. Windows: `latest` only. AL2 stops at K8s 1.32 |
| `amiFamily` | Bootstrap format | `AL2023`, `Bottlerocket`, `AL2`, `Windows20xx`, `Custom`. Implied by `alias`; required without one |
| `subnetSelectorTerms[]` (required) | Where ENIs go | `tags` (wildcard `*` ok) or `id`. Terms ORed, fields ANDed |
| `securityGroupSelectorTerms[]` (required) | Node SGs | `tags`, `id` or `name` |
| `userData` | Extra bootstrap | AL2023: MIME / NodeConfig / shell, **merged** with the generated NodeConfig (Karpenter wins on conflicts). Bottlerocket: TOML merged into settings. AL2: bash before bootstrap. `Custom`: used verbatim |
| `kubelet` | Kubelet flags Karpenter must know about for scheduling | `maxPods`, `podsPerCore` (ignored on Bottlerocket), `systemReserved`, `kubeReserved`, `evictionHard`, `evictionSoft` + `evictionSoftGracePeriod`, `evictionMaxPodGracePeriod`, `imageGCHigh/LowThresholdPercent`, `cpuCFSQuota`, `clusterDNS`. Anything else goes in `userData` |
| `blockDeviceMappings[]` | EBS volumes | AL2023 default: `/dev/xvda` 20Gi gp3 encrypted. Bottlerocket default: `/dev/xvda` 4Gi (OS) + `/dev/xvdb` 20Gi (data). `rootVolume: true` marks the kubelet/containerd disk |
| `instanceStorePolicy` | `RAID0` | Stripes local NVMe and uses it for ephemeral storage; allocatable ephemeral-storage = NVMe size |
| `metadataOptions` | IMDS settings | Default `httpTokens: required` (IMDSv2), **`httpPutResponseHopLimit: 1`**, endpoint enabled, IPv6 off |
| `detailedMonitoring` | 1-minute CloudWatch metrics | default false (costs extra) |
| `associatePublicIPAddress` | Public IP on the primary ENI | Defaults to the subnet's setting |
| `tags` | Extra tags on instances, volumes, ENIs, LTs, instance profiles | Cannot set `karpenter.sh/nodepool`, `karpenter.sh/nodeclaim`, `karpenter.k8s.aws/ec2nodeclass`, `eks:eks-cluster-name`, `kubernetes.io/cluster/*` |
| `capacityReservationSelectorTerms[]` | ODCRs / Capacity Blocks to use | `id`, or `tags` + `ownerID`, `instanceMatchCriteria`. Nodes get capacity-type `reserved` |
| Also in 1.14 | `ipPrefixCount`, `networkInterfaces`, `placementGroupSelector`, `connectionTracking`, `cpuOptions.nestedVirtualization` | Mention only |

### IMDSv2 hop limit 1, in one sentence

A pod's packets to `169.254.169.254` cross one extra network hop (the pod network namespace), so with hop limit 1 the IMDSv2 token response is dropped and **pods cannot read the node role credentials**. Pods use EKS Pod Identity or IRSA instead. Set hop limit 2 only if a workload truly needs IMDS.

### Status fields

| Field | Meaning |
|---|---|
| `status.amis[]` | Resolved AMI `id`, `name`, `requirements` (arch, GPU / accelerator), `deprecated` |
| `status.subnets[]` | `id`, `zone`, `zoneID`, sorted by free IPs |
| `status.securityGroups[]` | `id`, `name` |
| `status.instanceProfile` | Name of the instance profile Karpenter created |
| `status.capacityReservations[]` | Resolved ODCRs |
| `status.conditions` | `AMIsReady`, `SubnetsReady`, `SecurityGroupsReady`, `InstanceProfileReady`, `ValidationSucceeded`, `CapacityReservationsReady`, `PlacementGroupReady` → `Ready` |

`ValidationSucceeded` comes from real dry-run calls to `ec2:CreateLaunchTemplate`, `ec2:CreateFleet` and `ec2:RunInstances`. An IAM problem shows up here before the first launch.

### Capacity used in this module

`default` (limit 10) + `bottlerocket` (limit 2, Spot only, 2-vCPU types) = 12. One 2-vCPU Spot node.

## Demo

### Step 1 — Load the environment and check BASELINE
```bash
source scripts/env.sh
kubectl get nodepools,ec2nodeclasses,nodeclaims
```
Expected: `default` NodePool and EC2NodeClass `READY True`, no NodeClaims.

### Step 2 — Read the live default EC2NodeClass status
```bash
kubectl get ec2nodeclass default -o jsonpath='{.status}' \
  | jq '{instanceProfile, amis: [.amis[] | {id, name}], subnets, securityGroups, conditions: [.conditions[] | {type, status}]}'
```
Expected:
- `instanceProfile`: `karpenter-demo_<long number>`.
- `amis`: 5 entries named `amazon-eks-node-al2023-<arch>-<variant>-1.36-v20260930`: `x86_64-standard` (`ami-067d27d47f88c442a`), `arm64-standard`, `x86_64-neuron`, `arm64-nvidia`, `x86_64-nvidia`.
- `subnets`: 3 entries, one per zone `ap-south-1a|b|c` (with `zoneID` `aps1-az1|2|3`).
- `securityGroups`: 1 entry, `karpenter-demo-node-00baf0bc…`.
- 8 conditions, all `"True"`, in this order: `AMIsReady`, `CapacityReservationsReady`, `PlacementGroupReady`, `SubnetsReady`, `SecurityGroupsReady`, `InstanceProfileReady`, `ValidationSucceeded`, `Ready`. `CapacityReservationsReady` and `PlacementGroupReady` are listed even with no selector terms set.

### Step 3 — Validate a manifest that uses every field (server dry run, nothing created)
CEL rules run in the API server. A dry run proves the schema without launching anything.
```bash
kubectl apply --dry-run=server -f manifests/11-ec2nodeclass/reference-all-fields.yaml
```
Expected: `ec2nodeclass.karpenter.k8s.aws/reference-only created (server dry run)`.

Walk the file on screen: `role`, alias + `amiFamily`, two subnet terms (tags OR id), SG `name` term, `capacityReservationSelectorTerms`, every `kubelet` key, a gp3 root volume, `RAID0`, IMDS defaults, AL2023 `NodeConfig` user data.

### Step 4 — Show a CEL rule rejecting a bad change
```bash
kubectl patch ec2nodeclass default --type merge --dry-run=server \
  -p '{"spec":{"instanceProfile":"some-profile"}}'
```
Expected: `The EC2NodeClass "default" is invalid: spec: Invalid value: must specify exactly one of ['role', 'instanceProfile']`. Nothing is changed.

### Step 5 — Check the pinned Bottlerocket version exists for K8s 1.36
Aliases resolve through SSM. Check before you pin.
```bash
aws ssm get-parameter --name /aws/service/bottlerocket/aws-k8s-1.36/x86_64/1.65.0/image_id \
  --query Parameter.Value --output text
aws ssm get-parameter --name /aws/service/bottlerocket/aws-k8s-1.36/x86_64/latest/image_version \
  --query Parameter.Value --output text
```
Expected: `ami-0f12ab53c59e75111`, then the latest version string, `1.66.0-1ad6b4a4` at validation time. The pin is one version behind latest on purpose. If the first command fails with `ParameterNotFound`, edit `manifests/11-ec2nodeclass/bottlerocket-nodeclass.yaml` to the version printed by the second command (format `bottlerocket@v1.x.y`).

### Step 6 — Create the Bottlerocket EC2NodeClass
Custom data volume (30Gi gp3, 4000 IOPS, 250 MB/s), kubelet reservations, explicit IMDS defaults.
```bash
kubectl apply -f manifests/11-ec2nodeclass/bottlerocket-nodeclass.yaml
kubectl wait ec2nodeclass/bottlerocket --for=condition=Ready --timeout=120s
kubectl get ec2nodeclasses
```
Expected: `condition met` in ~11 s, then two rows (`bottlerocket`, `default`) both `READY True` (columns are only `NAME READY AGE`).

### Step 7 — Compare the two EC2NodeClass statuses
```bash
kubectl get ec2nodeclass bottlerocket -o jsonpath='{.status}' \
  | jq '{instanceProfile, amis: [.amis[] | {id, name}]}'
```
Expected: a **different** `instanceProfile` name from `default` (validation run: `karpenter-demo_9012955385018923981`; one per EC2NodeClass, same role) and 5 AMI entries: `bottlerocket-aws-k8s-1.36-x86_64-v1.65.0-0be31b34` (`ami-0f12ab53c59e75111`, listed twice), `…-aarch64-v1.65.0-…`, `…-nvidia-x86_64-v1.65.0-…`, `…-nvidia-aarch64-v1.65.0-…`.

### Step 8 — Create the NodePool and a pod that selects it
The NodePool allows only Spot, 2-vCPU types, limit 2 CPU. The pod selects `karpenter.sh/nodepool: bottlerocket`.
```bash
kubectl apply -f manifests/11-ec2nodeclass/bottlerocket-nodepool.yaml
kubectl apply -f manifests/11-ec2nodeclass/bottlerocket-workload.yaml
kubectl -n demo rollout status deploy/br-demo --timeout=240s
kubectl get nodeclaims -o wide
```
Expected: NodeClaim `bottlerocket-xxxxx`, `CAPACITY spot`, a 2-vCPU type (validation run: `c8i-flex.large`), `READY True`; rollout finished in ~25 s (Bottlerocket boots fast). `-o wide` shows `IMAGEID ami-…` (the Bottlerocket AMI) and `NODECLASS bottlerocket`.

### Step 9 — Inspect the node without SSH
```bash
BR_NODE=$(kubectl get nodes -l karpenter.sh/nodepool=bottlerocket -o jsonpath='{.items[0].metadata.name}')
kubectl get node "$BR_NODE" -o jsonpath='{.status.nodeInfo.osImage}{"  "}{.status.nodeInfo.containerRuntimeVersion}{"\n"}'
kubectl get node "$BR_NODE" -o json | jq '{capacity: .status.capacity, allocatable: .status.allocatable}'
```
Expected: `Bottlerocket OS 1.65.0 (aws-k8s-1.36)  containerd://2.2.7+bottlerocket`. Capacity `cpu "2"`, `pods "110"`, `ephemeral-storage "30654Mi"` (the 30Gi data volume). Allocatable CPU = 2000m − 100m system − 150m kube = **`1750m`**. Allocatable memory = capacity − 256Mi − 768Mi − 200Mi eviction: on c8i-flex.large `3905200Ki` → `2651824Ki` (or `3905188Ki` → `2651812Ki`): always capacity − `1253376Ki`.

### Step 10 — Read the live kubelet config from the API server
`configz` returns the running kubelet configuration. No SSH, works on Bottlerocket.
```bash
kubectl get --raw "/api/v1/nodes/${BR_NODE}/proxy/configz" \
  | jq '.kubeletconfig | {maxPods, systemReserved, kubeReserved, evictionHard, clusterDNS}'
```
Expected: `maxPods 110`, `systemReserved {cpu: "100m", memory: "256Mi"}`, `kubeReserved {cpu: "150m", ephemeral-storage: "1Gi", memory: "768Mi"}` (Bottlerocket adds the `1Gi` default), `evictionHard` exactly `memory.available: "200Mi"` and `nodefs.available: "10%"`, `clusterDNS ["172.20.0.10"]` (EKS default service CIDR 172.20.0.0/16).

### Step 11 — Show the EBS volumes and IMDS settings on the instance
```bash
BR_ID=$(kubectl get node "$BR_NODE" -o jsonpath='{.spec.providerID}'); BR_ID=${BR_ID##*/}
aws ec2 describe-instances --instance-ids "$BR_ID" \
  --query 'Reservations[].Instances[].{IMDS:MetadataOptions,Disks:BlockDeviceMappings[].{dev:DeviceName,vol:Ebs.VolumeId}}' --output json
aws ec2 describe-volumes --filters Name=attachment.instance-id,Values="$BR_ID" \
  --query 'Volumes[].{dev:Attachments[0].Device,size:Size,type:VolumeType,iops:Iops,tput:Throughput,enc:Encrypted}' --output table
```
Expected: `HttpTokens required`, `HttpPutResponseHopLimit 1`. Two volumes: `/dev/xvda 4 gp3 3000 125 True` and `/dev/xvdb 30 gp3 4000 250 True`.

### Step 12 — Clean up the Bottlerocket resources
Delete in this order: workload, NodePool (drains and terminates its node), then the EC2NodeClass (Karpenter deletes its instance profile).
```bash
kubectl delete -f manifests/11-ec2nodeclass/bottlerocket-workload.yaml
kubectl delete -f manifests/11-ec2nodeclass/bottlerocket-nodepool.yaml --timeout=5m
kubectl delete -f manifests/11-ec2nodeclass/bottlerocket-nodeclass.yaml --timeout=3m
kubectl get nodepools,ec2nodeclasses,nodeclaims
```
Expected: the NodePool delete returns at once. The EC2NodeClass delete blocks until its NodeClaim is gone and the instance profile deleted (~35 s). Final listing shows only `default` NodePool and EC2NodeClass and no NodeClaims.

## Talking points

- Split of concerns: NodePool = scheduling and lifecycle policy; EC2NodeClass = AWS launch config. Teams often share one EC2NodeClass across many NodePools.
- Prefer `role`: Karpenter owns the instance profile lifecycle (create, rotate on role change, delete). Use `instanceProfile` only when IAM writes are forbidden.
- Pin AMIs (`al2023@vYYYYMMDD`, `bottlerocket@v1.x.y`). `@latest` is a rolling deployment that you did not schedule. Roll AMIs forward through drift with budgets (module on drift).
- `kubelet` fields live in the EC2NodeClass because Karpenter **simulates** the node before launching it. If you set `maxPods` or reservations only in `userData`, Karpenter's math would be wrong.
- Prefix delegation is on in this cluster, but Karpenter does not detect it. That is why `maxPods: 110` is set explicitly.
- `kubeReserved` default memory is `11 x maxPods + 255 Mi`. With `maxPods: 110` that is 1465Mi, more than a third of a 4 GiB `c` instance. Setting it explicitly (as on the Bottlerocket class) gives the pods more room.
- IMDS hop limit 1 is a security control: pods cannot steal the node role. Keep it.
- Bottlerocket: minimal, immutable OS, API-driven settings (TOML), separate OS and data volumes, faster boot. `podsPerCore` is ignored on it.
- `ValidationSucceeded` runs real EC2 dry-run calls. IAM mistakes surface on the EC2NodeClass status instead of as failed launches.

## Reset

```bash
kubectl delete -f manifests/11-ec2nodeclass/bottlerocket-workload.yaml --ignore-not-found
kubectl delete -f manifests/11-ec2nodeclass/bottlerocket-nodepool.yaml --ignore-not-found --timeout=5m
kubectl delete -f manifests/11-ec2nodeclass/bottlerocket-nodeclass.yaml --ignore-not-found --timeout=3m
scripts/reset.sh
```

## Q&A prep

- **Can I use my own golden AMI?** Yes: `amiSelectorTerms` with `id`, `name`, `tags` or `ssmParameter`, plus `amiFamily` (`AL2023` if it bootstraps like AL2023, otherwise `Custom` with full `userData`). Custom AMIs must register with the taint `karpenter.sh/unregistered:NoExecute`.
- **What happens when I change a field?** Static fields change the EC2NodeClass hash, so existing nodes become `Drifted` (reason `NodeClassDrift`) and are replaced under budgets. Selector fields (`amiSelectorTerms`, subnets, SGs) drift only when the **resolved** value changes.
- **Two EC2NodeClasses with the same role?** Fine. Each gets its own instance profile.
- **Is there SSH?** Not needed. Use `kubectl debug node/<name> -it --image=…` for a privileged pod, or SSM Session Manager (the node role has `AmazonSSMManagedInstanceCore`). On Bottlerocket, use its admin container.
- **Windows?** `windows2022@latest` / `windows2025@latest` aliases. Windows only allows `latest`.
- **Why did a launch use 3 subnets?** Karpenter picks the subnet in the chosen zone with the most free IPs. `status.subnets` is sorted that way.
- **Can I set `clusterDNS`?** Yes, `kubelet.clusterDNS`. In 1.14 AL2 / Bottlerocket / Windows use only the first entry.

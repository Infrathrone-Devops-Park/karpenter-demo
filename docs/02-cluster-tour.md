# 02 — Cluster tour
**Time:** 20 min · **Goal:** Walk through the Terraform and prove, read-only, that every AWS piece Karpenter needs exists.

## What you'll show
- The VPC and the `karpenter.sh/discovery` tags on private subnets and the node security group.
- The EKS 1.36 cluster, its add-ons, and VPC CNI prefix delegation.
- The single `system` managed node group: label, taint, and why.
- The Karpenter Terraform submodule: controller role + Pod Identity association, SQS queue + 5 EventBridge rules, node role + access entry, and the FIS role.

## Concepts

### Terraform layout

```text
terraform/
  versions.tf    aws provider ~> 6.68, profile infrathrone-demo, default tags
  variables.tf   region ap-south-1, cluster_name karpenter-demo, kubernetes_version 1.36
  main.tf        module "vpc" (vpc 6.7.3) + module "eks" (eks 21.29.0)
  karpenter.tf   module "karpenter" (eks//modules/karpenter 21.29.0) + FIS role
  outputs.tf     cluster_name, cluster_endpoint, karpenter_queue_name, node role, controller role, fis role
```

Karpenter itself is **not** installed by Terraform. We install it with Helm in module 03 so you can see every step.

### VPC (`module "vpc"`)
- `10.0.0.0/16`, three AZs `ap-south-1a/b/c`.
- **Private /20 subnets** (one per AZ): nodes live here. Large subnets because prefix delegation hands out contiguous /28 blocks.
- Public /24s for the single NAT gateway, intra /24s for the EKS control-plane ENIs.
- Private subnets carry `karpenter.sh/discovery=karpenter-demo`. The EC2NodeClass selects subnets by this tag.

### EKS (`module "eks"`)
- Kubernetes **1.36** (newest version Karpenter 1.14.1 supports), public endpoint, cluster creator gets admin via an access entry.
- **Add-ons** (pinned versions): `vpc-cni`, `eks-pod-identity-agent` (both `before_compute` so nodes join with them ready), `kube-proxy`, `coredns`, `metrics-server` (tolerates `CriticalAddonsOnly`).
- **VPC CNI prefix delegation** (`ENABLE_PREFIX_DELEGATION=true`, `WARM_PREFIX_TARGET=1`): each ENI slot gets a /28 (16 IPs) instead of one IP, so small instances can run many pods.
  - **Karpenter does not detect prefix delegation.** Left alone it computes ENI-limited max pods (29 on a `*.large`). That is why the EC2NodeClass sets `kubelet.maxPods: 110`.
- **Node security group** tagged `karpenter.sh/discovery=karpenter-demo` (only this one SG). The EC2NodeClass selects it by tag.

### System managed node group
- 1x `t3a.large` (2 vCPU / 8 GiB), on-demand, AL2023.
- Labels `role=system` and `karpenter.sh/controller=true`; taint `CriticalAddonsOnly=true:NoSchedule`.
- Why the taint: demo pods must **never** land here, otherwise scale-ups would be hidden. Only system pods that tolerate `CriticalAddonsOnly` run here: CoreDNS, metrics-server, Karpenter, the monitoring stack.
- Why not Karpenter-managed: Karpenter must not run on nodes it can delete. Its chart requires `karpenter.sh/nodepool DoesNotExist`.

### Karpenter submodule (`module "karpenter"`)

| Resource | Name in this lab | Purpose |
|---|---|---|
| Controller IAM role | `KarpenterController-<suffix>` (name prefix) | EC2/IAM/SSM/pricing/SQS permissions for the controller |
| Pod Identity association | `kube-system` / `karpenter` → controller role | Pod gets AWS creds from the Pod Identity agent; no SA annotation needed |
| SQS queue | `Karpenter-karpenter-demo` | Interruption events; 300 s retention, SSE on |
| EventBridge rules x5 | `KarpenterHealthEvent-*`, `KarpenterSpotInterrupt-*`, `KarpenterInstanceRebalance-*`, `KarpenterInstanceStateChange-*`, `KarpenterCRInterruption-*` | Send EC2/Health events to the queue |
| Node IAM role | `karpenter-demo-karpenter-node` | Instance role for Karpenter nodes (worker, ECR pull, CNI, SSM) |
| EKS access entry | node role, type `EC2_LINUX` | Lets Karpenter nodes join the cluster |
| FIS role (`karpenter.tf`) | `karpenter-demo-fis-spot` | Used in module 10 to send real spot interruptions |

Karpenter creates the **instance profile** for the node role itself (from `spec.role` on the EC2NodeClass), so Terraform does not.

## Demo

### Step 1 — Load the environment
```bash
source scripts/env.sh
```
Expected: variable summary; `KARPENTER_QUEUE=Karpenter-karpenter-demo`.

### Step 2 — Terraform outputs
The names every later module uses.
```bash
terraform -chdir=terraform output
```
Expected: `cluster_name = "karpenter-demo"`, `cluster_endpoint = "https://...eks.amazonaws.com"`, `karpenter_queue_name = "Karpenter-karpenter-demo"`, `karpenter_node_role_name = "karpenter-demo-karpenter-node"`, `karpenter_controller_role_arn = "arn:aws:iam::146725924014:role/KarpenterController-..."`, `fis_role_arn = "arn:aws:iam::146725924014:role/karpenter-demo-fis-spot"`, plus `configure_kubectl`.

### Step 3 — Cluster facts
```bash
aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.{Version:version,Status:status,Platform:platformVersion,AuthMode:accessConfig.authenticationMode,PublicEndpoint:resourcesVpcConfig.endpointPublicAccess}' --output table
```
Expected: `Version 1.36`, `Status ACTIVE`, `AuthMode API_AND_CONFIG_MAP`, `PublicEndpoint True`, platform `eks.N`.

### Step 4 — Discovery-tagged subnets
These are the only subnets Karpenter will launch into.
```bash
aws ec2 describe-subnets --filters Name=tag:karpenter.sh/discovery,Values="$CLUSTER_NAME" --query 'Subnets[].{Id:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,FreeIPs:AvailableIpAddressCount}' --output table
```
Expected: 3 rows, `10.0.0.0/20`, `10.0.16.0/20`, `10.0.32.0/20` in `ap-south-1a/b/c`, each with roughly 4,000 free IPs (fewer in the system node's AZ).

### Step 5 — Discovery-tagged security group
```bash
aws ec2 describe-security-groups --filters Name=tag:karpenter.sh/discovery,Values="$CLUSTER_NAME" --query 'SecurityGroups[].{Id:GroupId,Name:GroupName}' --output table
```
Expected: exactly 1 row, name starting `karpenter-demo-node-`. More than one tagged SG would attach all of them to Karpenter nodes.

### Step 6 — Add-ons and prefix delegation
```bash
aws eks list-addons --cluster-name "$CLUSTER_NAME" --query addons --output text
aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name vpc-cni --query 'addon.{Version:addonVersion,Config:configurationValues}' --output table
kubectl -n kube-system get ds aws-node -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-node")].env[?(@.name=="ENABLE_PREFIX_DELEGATION")].value}{"\n"}'
```
Expected: `coredns  eks-pod-identity-agent  kube-proxy  metrics-server  vpc-cni` (order may vary); vpc-cni `v1.22.4-eksbuild.3` with `{"env":{"ENABLE_PREFIX_DELEGATION":"true","WARM_PREFIX_TARGET":"1"}}`; last line `true`.

### Step 7 — The system node: labels, taint, pod capacity
```bash
kubectl get nodes -L role,karpenter.sh/controller,node.kubernetes.io/instance-type,topology.kubernetes.io/zone,eks.amazonaws.com/nodegroup
kubectl describe node -l role=system | grep -E '^Taints:|^  pods:'
```
Expected: one node, `system`, `true`, `t3a.large`, its zone, nodegroup `system-<suffix>`. Then `Taints: CriticalAddonsOnly=true:NoSchedule` and two `pods:` lines (Capacity and Allocatable), both `110`: the managed node group's AL2023 bootstrap sees prefix delegation and raises max pods (ENI-limited it would be 35 on a t3a.large).

### Step 8 — What runs on the system node
Everything here tolerates `CriticalAddonsOnly`.
```bash
kubectl get pods -A -o wide --field-selector spec.nodeName="$(kubectl get nodes -l role=system -o jsonpath='{.items[0].metadata.name}')"
```
Expected: `aws-node`, `kube-proxy`, `eks-pod-identity-agent`, `coredns` x2, `metrics-server` x2, and the five `monitoring` pods (grafana, kube-state-metrics, operator, node-exporter, `prometheus-kube-prometheus-stack-prometheus-0`): 12 pods. No `demo` pods.

Note: with CAST AI connected read-only, two more pods run here (`castai-agent`, `castai-agent-cpvpa`): 14 pods.

### Step 9 — Pod Identity association for the controller
```bash
aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --query 'associations[].{Namespace:namespace,ServiceAccount:serviceAccount,Id:associationId}' --output table
aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --namespace kube-system --service-account karpenter --query 'associations[0].associationId' --output text)" --query 'association.roleArn' --output text
```
Expected: one row `kube-system` / `karpenter` / `a-...`; then the controller role ARN (same as the Terraform output). The service account does not exist yet: Helm creates it in module 03, and the association already waits for it.

### Step 10 — Controller role permissions
```bash
aws iam list-role-policies --role-name "$(terraform -chdir=terraform output -raw karpenter_controller_role_arn | awk -F/ '{print $NF}')" --query PolicyNames --output table
```
Expected: one **inline** policy named `KarpenterController-...` (the role has no attached managed policies; `terraform/karpenter.tf` sets `enable_inline_policy = true` because the full policy is longer than the 6,144-character managed-policy limit). It covers EC2 fleet/launch-template/terminate (tag-scoped), instance-profile management, `iam:PassRole` for the node role, SSM/pricing/describe reads, `eks:DescribeCluster`, and the SQS receive/delete actions.

### Step 11 — Interruption queue and EventBridge rules
```bash
aws sqs get-queue-attributes --queue-url "$(aws sqs get-queue-url --queue-name "$KARPENTER_QUEUE" --query QueueUrl --output text)" --attribute-names MessageRetentionPeriod SqsManagedSseEnabled ApproximateNumberOfMessages --query Attributes --output table
aws events list-rules --name-prefix Karpenter --query 'Rules[].{Name:Name,State:State}' --output table
```
Expected: `MessageRetentionPeriod 300`, `SqsManagedSseEnabled true`, `ApproximateNumberOfMessages 0`. Five rules, all `ENABLED`: `KarpenterCRInterruption-…`, `KarpenterHealthEvent-…`, `KarpenterInstanceRebalance-…`, `KarpenterInstanceStateChange-…`, `KarpenterSpotInterrupt-…`.

### Step 12 — Node role and access entry
```bash
aws iam list-attached-role-policies --role-name karpenter-demo-karpenter-node --query 'AttachedPolicies[].PolicyName' --output table
aws eks list-access-entries --cluster-name "$CLUSTER_NAME" --output table
aws eks describe-access-entry --cluster-name "$CLUSTER_NAME" --principal-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/karpenter-demo-karpenter-node" --query 'accessEntry.{Type:type,Groups:kubernetesGroups}' --output json
```
Expected: four policies `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryPullOnly`, `AmazonEKS_CNI_Policy`, `AmazonSSMManagedInstanceCore`. Four access entries: `role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS`, `role/karpenter-demo-karpenter-node`, `role/system-eks-node-group-...` (the system node group) and the Terraform caller (`user/sai` here). The Karpenter node role entry shows `"Type": "EC2_LINUX"` and `"Groups": ["system:nodes"]`.

Note: with CAST AI connected, a fifth entry `role/castai-eks-instance-karpenter-demo` is listed (its node role, unused in read-only mode).

### Step 13 — FIS role (for module 10)
```bash
aws iam get-role --role-name karpenter-demo-fis-spot --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal' --output json
aws iam list-attached-role-policies --role-name karpenter-demo-fis-spot --query 'AttachedPolicies[].PolicyName' --output text
```
Expected: `{"Service": "fis.amazonaws.com"}` and `AWSFaultInjectionSimulatorEC2Access`.

## Talking points
- "Karpenter finds infrastructure by **tags**, not by IDs. Tag a subnet or SG with `karpenter.sh/discovery` and it becomes a launch target. Tag only what you mean."
- "One small tainted node group for system pods is the standard Karpenter pattern. Karpenter must never run on capacity it manages."
- "Pod Identity is the modern way to give a pod an IAM role: an association on the EKS side, no OIDC provider trust policy edits, no service-account annotation."
- "The queue plus five rules is how Karpenter hears about spot interruptions 2 minutes early, and about instances that stop or get scheduled maintenance."
- "The access entry with type `EC2_LINUX` replaces editing the `aws-auth` ConfigMap."
- "Prefix delegation is a cluster setting Karpenter cannot see. If you enable it, tell Karpenter through `maxPods`."

## Reset
Nothing in this module changes the cluster.

## Q&A prep
- **Why does the queue name start with `Karpenter-`?** It is the Terraform module default `Karpenter-<cluster>`. The Karpenter docs use the cluster name; either works because Helm gets the name explicitly.
- **Why only the node SG and not the cluster primary SG?** The module's node SG already allows node-to-node and control-plane traffic. Tagging more SGs attaches all of them.
- **What if a subnet runs out of IPs?** Karpenter treats `InsufficientFreeAddressesInSubnet` as capacity unavailable for that subnet and tries other AZs.
- **Does the node role need SSM?** No. It is there for Session Manager access when debugging nodes.
- **Where is the instance profile?** Karpenter creates it from `spec.role` and reports it in `status.instanceProfile` (module 03).
- **Can I use IRSA instead?** Yes, but the v21 Terraform module only wires Pod Identity; IRSA needs an extra trust statement and a service-account annotation.

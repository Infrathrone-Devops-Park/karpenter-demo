# 00 — Agenda & setup
**Time:** 15 min · **Goal:** Set expectations, show the lab, and confirm the cluster is ready before anything moves.

## What you'll show
- The full agenda (modules 00–15) and where the breaks are.
- The lab architecture: one EKS 1.36 cluster, one tiny system node, everything else launched by Karpenter.
- The vCPU quota budget and why every NodePool in this course has a `limits.cpu`.
- The presenter terminal layout used for the rest of the day.
- A live health check of the cluster (the same commands as the pre-demo checklist).

## Concepts

### Agenda

Times are targets. Total ≈ 7 h 40 min including breaks (≈ 6 h 40 min of content). Run as one day, or split after module 07 (session 1 ≈ 3 h 45, session 2 ≈ 3 h 25 after `scripts/resume.sh`).

| # | Module | Min | Starts at (T+) |
|---|---|---|---|
| 00 | Agenda & setup | 15 | 0:00 |
| 01 | Why Karpenter | 25 | 0:15 |
| 02 | Cluster tour | 20 | 0:40 |
| 03 | Install Karpenter | 25 | 1:00 |
| 04 | First scale-up | 30 | 1:25 |
| — | Break | 10 | 1:55 |
| 05 | NodePools deep dive | 35 | 2:05 |
| 06 | Scheduling constraints | 30 | 2:40 |
| 07 | Consolidation | 35 | 3:10 |
| — | Lunch | 30 | 3:45 |
| 08 | Disruption controls | 30 | 4:15 |
| 09 | Drift & expiration | 20 | 4:45 |
| 10 | Spot interruption | 25 | 5:05 |
| — | Break | 10 | 5:30 |
| 11 | EC2NodeClass deep dive | 20 | 5:40 |
| 12 | Observability | 20 | 6:00 |
| 13 | Troubleshooting | 30 | 6:20 |
| — | Break | 10 | 6:50 |
| 14 | Advanced features & feature gates | 25 | 7:00 |
| 15 | Production checklist & wrap-up | 15 | 7:25 |
| | **End** | | **7:40** |

If you run behind, cut in this order: 11 (fold into 09), 14 (talk only), 12 (show one dashboard).

### Lab architecture

```text
                        AWS account 146725924014 · ap-south-1
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ VPC 10.0.0.0/16 (karpenter-demo)                                         │
 │                                                                          │
 │  public /24 x3  ── NAT GW (single) ── Internet                           │
 │  intra  /24 x3  ── EKS control-plane ENIs                                │
 │  private /20 x3 (tag karpenter.sh/discovery=karpenter-demo)              │
 │   ┌─────────────────────────────┐   ┌──────────────────────────────────┐ │
 │   │ MNG "system" 1x t3a.large   │   │ Karpenter nodes (0..N)           │ │
 │   │ label role=system           │   │ NodePool default + EC2NodeClass  │ │
 │   │ taint CriticalAddonsOnly    │   │ c/m/r gen>4, 2 or 4 vCPU,        │ │
 │   │ karpenter (1 replica)       │   │ spot preferred, on-demand ok     │ │
 │   │ coredns, metrics-server     │   │ demo workloads (ns demo)         │ │
 │   │ prometheus, grafana, ksm    │   │ daemonsets: aws-node, kube-proxy,│ │
 │   │ daemonsets                  │   │ pod-identity-agent, node-exporter│ │
 │   └─────────────────────────────┘   └──────────────────────────────────┘ │
 └──────────────────────────────────────────────────────────────────────────┘
        ▲ Pod Identity (controller role)          ▲ EC2 CreateFleet / Terminate
        │                                         │
 EKS 1.36 API ◄── Karpenter controller ──► EC2, SSM (AMI alias), Pricing, IAM
                        ▲
                        │ SQS Karpenter-karpenter-demo ◄── EventBridge x5
                        │ (spot interruption, rebalance, state change, health, CR)
```

### Quota budget (hard limit, no increase possible)

| Quota (ap-south-1) | Limit | Used at baseline | Free |
|---|---|---|---|
| Running On-Demand Standard (A,C,D,H,I,M,R,T,Z) vCPU | 8 | 2 (system t3a.large) | 6 |
| All Standard Spot Instance Requests vCPU | 8 | 0 | 8 |

Rules this course follows:
- Every NodePool has `limits.cpu`. The `default` NodePool is capped at **10 vCPU**; the sum of simultaneously active NodePool limits stays ≤ 12.
- Instances are 2 or 4 vCPU only (`karpenter.k8s.aws/instance-cpu In ["2","4"]`), so a single replacement node always fits.
- Consolidation, drift and interruption **launch the replacement before** terminating the old node. Keep headroom: never plan to sit at the limit when a disruption demo runs.
- We hit the quota on purpose only once, in module 13, and revert it.

### Presenter prerequisites

Tools on the laptop: `aws` v2, `kubectl` 1.35, `helm` v4.2.3, `terraform` 1.15, `jq`, `k9s`, and `eks-node-viewer` v0.7.4. Recent Homebrew refuses formulae from untrusted taps, so trust the tap first:

```bash
brew tap aws/tap && brew trust aws/tap && brew install eks-node-viewer
```

Alternative without Homebrew (release binary into `~/.local/bin`, which must be on `PATH`):

```bash
gh release download v0.7.4 -R awslabs/eks-node-viewer -p 'eks-node-viewer_Darwin_all'
install -m 755 eks-node-viewer_Darwin_all ~/.local/bin/eks-node-viewer
eks-node-viewer --version
```

Kubeconfig: nothing to do. `source scripts/env.sh` creates `.kube/karpenter-demo.kubeconfig` on first use and exports `KUBECONFIG` to it. Your global `~/.kube/config` and current context are never touched.

Every module starts from the repo root with `source scripts/env.sh`. It exports `AWS_PROFILE`, `AWS_REGION`, `CLUSTER_NAME`, `KARPENTER_VERSION`, `KARPENTER_NAMESPACE`, `KARPENTER_QUEUE`, `CLUSTER_ENDPOINT`, `KUBECONFIG` and `AWS_ACCOUNT_ID`. Run it in every terminal pane (eks-node-viewer and k9s read `KUBECONFIG` too).

### Terminal layout

`scripts/watch.sh` prints the pane commands; `scripts/watch.sh nodes|claims|logs|pods` runs one.

```text
┌───────────────────────────────────────┬──────────────────────────────┐
│ Pane 1: eks-node-viewer               │ Pane 2: kubectl get          │
│ (scripts/watch.sh nodes)              │   nodeclaims -w              │
│                                       │ (scripts/watch.sh claims)    │
├───────────────────────────────────────┼──────────────────────────────┤
│ Main pane: commands from docs/NN-*.md │ Pane 3: karpenter logs       │
│                                       │ (scripts/watch.sh logs)      │
└───────────────────────────────────────┴──────────────────────────────┘
```

Font size ≥ 16 pt. Pane 3 is noisy; widen it during modules 04, 07 and 10.

### Pre-demo checklist (morning of each session)

Run every step below about 30 min before the audience arrives. The order of first-time setup is: Terraform apply → `scripts/install-monitoring.sh` (the day before) → module 03 installs Karpenter live.

| Check | Session 1 (before module 03) | Later sessions (resume from PARKED) |
|---|---|---|
| Cluster ACTIVE, 1 system node Ready | yes | yes |
| Monitoring pods Running | yes | yes |
| Karpenter installed | **no** (installed live) | yes, 1/1 Running |
| NodePool/EC2NodeClass | none | run `scripts/reset.sh` → BASELINE |
| Karpenter nodes | none | none |

If you rehearsed module 03 already and want a clean live install, follow module 03 Reset ("rehearse from scratch"): delete the NodePools and EC2NodeClasses while Karpenter still runs, then `helm uninstall karpenter -n kube-system` and `helm uninstall karpenter-crd -n kube-system`. If you skip the uninstall, module 03 still works: every `helm upgrade --install` just becomes a new revision.

## Demo

### Step 1 — Load the environment
Every command in the course uses these variables.
```bash
source scripts/env.sh
```
Expected: six lines:
```text
AWS_PROFILE=infrathrone-demo AWS_REGION=ap-south-1 CLUSTER_NAME=karpenter-demo
KARPENTER_VERSION=1.14.1 KARPENTER_NAMESPACE=kube-system
KARPENTER_QUEUE=Karpenter-karpenter-demo
CLUSTER_ENDPOINT=https://<id>.gr7.ap-south-1.eks.amazonaws.com
KUBECONFIG=<repo>/.kube/karpenter-demo.kubeconfig
AWS_ACCOUNT_ID=146725924014
```

Note: `env.sh` points kubectl at a dedicated kubeconfig, so other contexts on the laptop can't be hit by mistake. Source it in **every** terminal pane. If the endpoint shows `<not found>`, your AWS credentials are not working.

### Step 2 — Confirm identity and cluster state
Proves the profile points at the right account and the control plane is up.
```bash
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table
aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.{Status:status,Version:version}' --output table
```
Expected: account `146725924014`; `Status ACTIVE`, `Version 1.36`.

### Step 3 — System node Ready
Only one node exists, and it carries the system label and taint.
```bash
kubectl get nodes -L role,karpenter.sh/controller,node.kubernetes.io/instance-type,topology.kubernetes.io/zone
```
Expected: exactly one node, `STATUS Ready`, `ROLE system`, `CONTROLLER true`, `INSTANCE-TYPE t3a.large`, zone one of `ap-south-1a/b/c`. At later sessions there must still be only this one node.

### Step 4 — Quota headroom
Shows the two vCPU quotas and what is running now.
```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query 'Quota.{Name:QuotaName,Value:Value}' --output table
aws service-quotas get-service-quota --service-code ec2 --quota-code L-34B43A08 --query 'Quota.{Name:QuotaName,Value:Value}' --output table
aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].[InstanceId,InstanceType,InstanceLifecycle||`on-demand`,Placement.AvailabilityZone]' --output table
```
Expected: `Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances` = `8.0`; `All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests` = `8.0`; one running instance, `t3a.large`, `on-demand`. Any other instance is a leftover: stop and clean it up before the session.

### Step 5 — Monitoring and (later sessions) Karpenter
Monitoring is pre-installed; Karpenter only from session 2 on.
```bash
kubectl get pods -n monitoring
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter -o wide
```
Expected: in `monitoring`, five pods `Running` before any Karpenter node exists (grafana `3/3`, operator `1/1`, kube-state-metrics `1/1`, `prometheus-kube-prometheus-stack-prometheus-0` `2/2`, one node-exporter `1/1` per node). Karpenter: `No resources found` in session 1; `1/1 Running` on the system node in later sessions.

### Step 6 — Baseline objects (later sessions only)
Confirms the BASELINE state from the previous session's reset.
```bash
kubectl get nodepools,ec2nodeclasses,nodeclaims
kubectl get deploy -n demo
```
Expected: `nodepool.karpenter.sh/default` and `ec2nodeclass.karpenter.k8s.aws/default` with `READY True`, **no** nodeclaims, `inflate 0/0`. If anything differs, run `scripts/reset.sh`. In session 1 (before module 03) the first command fails with `the server doesn't have a resource type "nodepools"` (or, if kubectl still caches the old CRDs after a rehearsal uninstall, three `Error from server (NotFound): Unable to list "karpenter.sh/v1, Resource=nodepools"...` lines) and the second prints `No resources found in demo namespace.`: both expected.

### Step 7 — Grafana port-forward
Leave this running in a spare tab for module 12.
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```
Expected: `Forwarding from 127.0.0.1:3000 -> 3000` and `Forwarding from [::1]:3000 -> 3000`. Open http://localhost:3000, log in `admin` / `karpenter-demo`. The `Karpenter` folder already holds `Karpenter Capacity v1` and `Karpenter Performance v1` (empty until module 03). This password is for a throwaway demo cluster reachable only through port-forward.

### Step 8 — Open the watch panes
```bash
scripts/watch.sh
```
Expected: the four pane commands printed. Start panes 1–3. Pane 1 shows `Waiting for update or no nodes found...` for a few seconds, then `1 nodes (870m/1930m) 45.1% cpu` (the system node; exact numbers depend on what runs there) and a price line. Press `q` to quit it. Before Karpenter is installed, pane 2 errors with `the server doesn't have a resource type "nodeclaims"` and pane 3 shows nothing; start them after module 03 step 5.

## Talking points
- "Everything you see today is real AWS: real EC2 launches, real spot capacity, real interruptions. Nothing is simulated except where I say so."
- "The cluster starts with exactly one small node. Every other node is created and deleted by Karpenter in front of you."
- "We have a hard budget of 8 on-demand and 8 spot vCPUs. That is a feature: it forces us to configure Karpenter the way you should in production, with limits on every NodePool."
- "Karpenter v1.14.1 is the current LTS release; EKS 1.36 is the newest Kubernetes version it supports."

## Reset
Nothing in this module changes the cluster. To stop the port-forward, press `Ctrl+C` in its tab.

## Q&A prep
- **Why one system node and not two?** Quota. The Karpenter chart defaults to 2 replicas with hostname anti-affinity; we run 1 replica. In production run 2+ replicas on 2+ non-Karpenter nodes (or Fargate) in different AZs.
- **Why not Fargate for the controller?** EKS Pod Identity does not work on Fargate, and this cluster uses Pod Identity for Karpenter. Fargate would need IRSA instead.
- **Why ap-south-1?** Close to the audience; all instance families we use are offered in all three AZs with good spot placement scores.
- **Can I follow along?** You need your own account and the Terraform in `terraform/`. Do not use a shared account with low quotas.
- **What does the lab cost?** Fixed cost is the EKS control plane, the single NAT gateway and the on-demand t3a.large system node (eks-node-viewer prices that node at about $0.075/hour), plus short-lived spot nodes during demos.

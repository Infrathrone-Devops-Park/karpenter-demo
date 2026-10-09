# Karpenter Live Demo (EKS)

Instructor-led, hands-on Karpenter **v1.14.1** demo on Amazon EKS **1.36**.
About 6 h 40 min of content (7 h 40 min with breaks) across 16 modules.
Every command was run on a live cluster and the expected output in each doc is real.

## Modules

| # | Module | Min |
|---|---|---|
| 00 | [Agenda & setup](docs/00-agenda-and-setup.md) | 15 |
| 01 | [Why Karpenter](docs/01-why-karpenter.md) | 25 |
| 02 | [Cluster tour](docs/02-cluster-tour.md) | 20 |
| 03 | [Install Karpenter](docs/03-install-karpenter.md) | 25 |
| 04 | [First scale-up](docs/04-first-scale-up.md) | 30 |
| 05 | [NodePools deep dive](docs/05-nodepools-deep-dive.md) | 35 |
| 06 | [Scheduling constraints](docs/06-scheduling-constraints.md) | 30 |
| 07 | [Consolidation](docs/07-consolidation.md) | 35 |
| 08 | [Disruption controls](docs/08-disruption-controls.md) | 30 |
| 09 | [Drift & expiration](docs/09-drift-and-expiration.md) | 20 |
| 10 | [Spot interruption](docs/10-spot-interruption.md) | 25 |
| 11 | [EC2NodeClass deep dive](docs/11-ec2nodeclass-deep-dive.md) | 20 |
| 12 | [Observability](docs/12-observability.md) | 20 |
| 13 | [Troubleshooting](docs/13-troubleshooting.md) | 30 |
| 14 | [Advanced features & feature gates](docs/14-advanced-features.md) | 25 |
| 15 | [Production checklist & wrap-up](docs/15-production-checklist.md) | 15 |

## Layout

```text
terraform/   VPC, EKS 1.36, system node group, Karpenter IAM/SQS/EventBridge, FIS role
manifests/   base/ EC2NodeClass + NodePool, plus one folder per module
workloads/   demo namespace and inflate deployment
scripts/     env, install, watch, reset, downscale, resume, teardown
docs/        module guides, run in order
```

## Quick start

```bash
cd terraform && terraform init && terraform apply && cd ..
source scripts/env.sh
scripts/install-monitoring.sh
scripts/install-karpenter.sh
kubectl apply -f manifests/base/ -f workloads/
```

`env.sh` sets the AWS profile, region and a dedicated kubeconfig. Install monitoring before Karpenter (ServiceMonitor CRD). Module 03 does the Karpenter install live.

## Operating the cluster

| Script | Purpose |
|---|---|
| `scripts/reset.sh` | Return to BASELINE between modules |
| `scripts/downscale.sh` | Park: remove all Karpenter nodes, keep system node |
| `scripts/resume.sh` | Parked to BASELINE |
| `scripts/teardown.sh --yes-destroy` | Ordered full teardown, then `terraform destroy` |

## Capacity budget

The account has 8 on-demand + 8 spot vCPU. The system node uses 2 on-demand vCPU.
Every NodePool sets `limits.cpu` and only 2–4 vCPU instance types are allowed.

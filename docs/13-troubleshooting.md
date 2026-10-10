# 13 — Troubleshooting Labs

**Time:** 30 min · **Goal:** Plant six common faults, read the exact symptom Karpenter gives for each, diagnose it, and fix it.

## What you'll show

Each lab follows **break → symptom → diagnose → fix → clean up**.

1. No NodePool matches the pod (arm64 selector).
2. NodePool CPU limit reached.
3. EC2NodeClass not Ready (wrong subnet tag) → NodePool not Ready.
4. Pod too big for any allowed instance type.
5. Controlled EC2 vCPU quota hit (on-demand) → `VcpuLimitExceeded`, offerings marked unavailable.
6. Karpenter controller itself down: health checks, leader lease, recovery.

## Concepts

### The diagnostic ladder

```text
1. kubectl describe pod <pending>        → FailedScheduling events (kube-scheduler AND karpenter)
2. kubectl get nodepools,ec2nodeclasses  → READY column; describe for conditions
3. kubectl get nodeclaims -o wide        → stuck Launched/Registered/Initialized?
4. kubectl get events -A --field-selector source=karpenter
5. karpenter logs | jq                   → "could not schedule pod", "failed launching nodeclaim"
6. metrics                               → launch failures, unschedulable pods, usage vs limit
```

### Where each fault shows up (v1.14.1 strings)

| Fault | Where | Exact text |
|---|---|---|
| Pod requirement conflicts with every NodePool | Pod event `FailedScheduling` (source karpenter), log `could not schedule pod` | `incompatible requirements, key <k>, <k> In [<pod value>] not in <k> In [<pool values>]` |
| NodePool limit | same | `all available instance types exceed limits for nodepool (NodePool=<name>)` |
| Nothing big enough | same | `no instance type has enough resources, requirements=…, resources=…` |
| Subnet selector matches nothing | EC2NodeClass condition `SubnetsReady=False` | reason `SubnetsNotFound`, `SubnetSelector did not match any Subnets` |
| Any dependency False | EC2NodeClass `Ready=False` | reason `UnhealthyDependents`, message like `SubnetsReady=False, ValidationSucceeded=False` |
| EC2NodeClass not Ready | NodePool `NodeClassReady=False`, `Ready=False` | NodePool is skipped for scheduling |
| EC2 capacity or quota | NodeClaim event `InsufficientCapacityError`, log `failed launching nodeclaim` | `creating instance, insufficient capacity, with fleet error(s), VcpuLimitExceeded: …` |
| NodeClass role not usable | EC2NodeClass `InstanceProfileReady=Unknown`, log `Reconciler error` | `creating instance profile, ensuring role attached, adding role to instance profile, … AccessDenied` |

The kube-scheduler also posts its own `FailedScheduling` event (`0/1 nodes are available: 1 node(s) had untolerated taint(s). …`). That one is expected; it only means "no existing node fits". Karpenter's event is the one with source `karpenter`.

### Capacity used in this module

- Labs 1–4 use at most three 2-vCPU Spot nodes at once (Lab 3: two leftover `default` nodes + one `lab3-broken`) = 6 of 8 Spot vCPU; pool limits `default` 10 + `lab3-broken` 2 = 12.
- **Lab 5 is the only place in the course that hits the quota on purpose.** It uses on-demand only (`lab5-quota` limit 8 = the quota; the pool sum 10 + 8 is the one deliberate exception to the 12-vCPU rule), the system node (t3a.large, on-demand, managed node group) is never touched, and everything is deleted within ~2 minutes.

## Demo

### Step 0 — Load the environment and check BASELINE
```bash
source scripts/env.sh
kubectl get nodepools,ec2nodeclasses,nodeclaims
```
Expected: `default` NodePool and EC2NodeClass `READY True`, no NodeClaims.

Keep `scripts/watch.sh claims` running in a second terminal for the whole module.

---

**Lab 1 — No NodePool matches (arm64)**

### Step 1.1 — Break
```bash
kubectl apply -f manifests/13-troubleshooting/lab1-arm64.yaml
sleep 20
kubectl -n demo get pods -l app=lab1-arm64
```
Expected: one pod `Pending`. No NodeClaim appears.

### Step 1.2 — Symptom and diagnosis
```bash
kubectl -n demo get events --field-selector reason=FailedScheduling -o json \
  | jq -r '.items[] | select(.involvedObject.name|startswith("lab1"))
      | "\(if (.source.component // "") != "" then .source.component else .reportingComponent end): \(.message)"' | sort -u
```
Expected: two `FailedScheduling` warnings:
- `default-scheduler`: `0/1 nodes are available: 1 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.`
- `karpenter`: `Failed to schedule pod, incompatible requirements, key kubernetes.io/arch, kubernetes.io/arch In [arm64] not in kubernetes.io/arch In [amd64]`

The log says the same:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller --tail=-1 --since=2m \
  | jq -cR 'fromjson? | select(.message=="could not schedule pod") | {Pod: .Pod.name, error}' | tail -1
```
Expected: `{"Pod":"lab1-arm64-5d94cd9f87-fvrqn","error":"incompatible requirements, key kubernetes.io/arch, kubernetes.io/arch In [arm64] not in kubernetes.io/arch In [amd64]"}`.

### Step 1.3 — Fix
Either add a NodePool that allows the value, or fix the workload. Here the image is multi-arch and the selector was a mistake:
```bash
kubectl -n demo patch deploy lab1-arm64 --type json \
  -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
kubectl -n demo rollout status deploy/lab1-arm64 --timeout=180s
```
Expected: a `default-xxxxx` NodeClaim (Spot, amd64; validation run `c8i-flex.large`) and the pod `Running` in ~30 s.

### Step 1.4 — Clean up
```bash
kubectl delete -f manifests/13-troubleshooting/lab1-arm64.yaml
```
Expected: `deployment.apps "lab1-arm64" deleted`. Leave the node; Lab 2 reuses it or consolidation removes it.

---

**Lab 2 — NodePool limit reached**

### Step 2.1 — Break: shrink the limit to 2 CPU and ask for 3 CPU
```bash
kubectl patch nodepool default --type merge -p '{"spec":{"limits":{"cpu":"2"}}}'
kubectl -n demo scale deploy/inflate --replicas 6
sleep 60
kubectl -n demo get pods -l app=inflate -o wide
```
Expected: 3 pods `Running` on one 2-vCPU Spot node, 3 pods `Pending`. In the validation run Lab 1's node was still there: the 3 pods landed on it and no new node was created (same result).

### Step 2.2 — Symptom and diagnosis
```bash
kubectl get nodepool default -o jsonpath='{"limit: "}{.spec.limits.cpu}{"  in use: "}{.status.resources.cpu}{"\n"}'
kubectl -n demo get events --field-selector reason=FailedScheduling -o json \
  | jq -r '.items[] | select(.source.component=="karpenter" and (.involvedObject.name|startswith("inflate"))) | .message' | sort -u
```
Expected: `limit: 2  in use: 2`, then `Failed to schedule pod, all available instance types exceed limits for nodepool (NodePool=default)`.

### Step 2.3 — Fix
```bash
kubectl apply -f manifests/base/nodepool.yaml
kubectl -n demo rollout status deploy/inflate --timeout=180s
```
Expected: `nodepool.karpenter.sh/default configured`, a second NodeClaim, all 6 pods `Running` in ~33 s.

### Step 2.4 — Clean up
```bash
kubectl -n demo scale deploy/inflate --replicas 0
```

---

**Lab 3 — EC2NodeClass not Ready (wrong subnet tag)**

### Step 3.1 — Break
`lab3-broken` selects subnets tagged `karpenter.sh/discovery: karpenter-demo-typo`, which do not exist.
```bash
kubectl apply -f manifests/13-troubleshooting/lab3-broken-nodeclass.yaml
kubectl apply -f manifests/13-troubleshooting/lab3-broken-nodepool.yaml
kubectl apply -f manifests/13-troubleshooting/lab3-workload.yaml
sleep 20
kubectl get ec2nodeclasses,nodepools
```
Expected: `ec2nodeclass lab3-broken READY False`, `nodepool lab3-broken READY False`. The pod `lab3-pinned-…` is `Pending`.

### Step 3.2 — Symptom and diagnosis
```bash
kubectl get ec2nodeclass lab3-broken -o json | jq -c '.status.conditions[] | {type, status, reason, message}'
kubectl get nodepool lab3-broken -o json | jq -c '.status.conditions[] | {type, status, reason, message}'
```
Expected for the EC2NodeClass:
- `SubnetsReady False SubnetsNotFound "SubnetSelector did not match any Subnets"`
- `ValidationSucceeded False DependenciesNotReady "Awaiting AMI, Instance Profile, Security Group, and Subnet resolution"`
- `AMIsReady`, `SecurityGroupsReady`, `InstanceProfileReady` `True`
- `CapacityReservationsReady`, `PlacementGroupReady` `True`
- `Ready False UnhealthyDependents "ValidationSucceeded=False, SubnetsReady=False"`

Expected for the NodePool: `ValidationSucceeded True`, `NodeRegistrationHealthy Unknown AwaitingReconciliation`, `NodeClassReady False UnhealthyDependents "ValidationSucceeded=False, SubnetsReady=False"` (copied from the EC2NodeClass `Ready`), `Ready False UnhealthyDependents "NodeClassReady=False"`.

The pod's Karpenter event:
```bash
kubectl -n demo get events --field-selector reason=FailedScheduling -o json \
  | jq -r '.items[] | select(.source.component=="karpenter" and (.involvedObject.name|startswith("lab3"))) | .message' | sort -u
```
Expected: `Failed to schedule pod, incompatible requirements, key karpenter.sh/nodepool, karpenter.sh/nodepool In [lab3-broken] not in karpenter.sh/nodepool In [default]`. The broken NodePool is invisible to the scheduler, so only `default` is considered.

Check what the selector *should* match:
```bash
aws ec2 describe-subnets --filters Name=tag:karpenter.sh/discovery,Values=karpenter-demo \
  --query 'Subnets[].[SubnetId,AvailabilityZone]' --output text
```
Expected: three private subnets, one per AZ.

### Step 3.3 — Fix
```bash
kubectl patch ec2nodeclass lab3-broken --type merge \
  -p '{"spec":{"subnetSelectorTerms":[{"tags":{"karpenter.sh/discovery":"karpenter-demo"}}]}}'
kubectl wait ec2nodeclass/lab3-broken --for=condition=Ready --timeout=120s
kubectl wait nodepool/lab3-broken --for=condition=Ready --timeout=60s
kubectl -n demo rollout status deploy/lab3-pinned --timeout=180s
```
Expected: both `condition met` within ~2 s, then a `lab3-broken-xxxxx` NodeClaim and the pod `Running` in ~40 s.

Wrong `role` variant (talk, do not run): `spec.role: does-not-exist` leaves `InstanceProfileReady Unknown AwaitingReconciliation`, `Ready Unknown ReconcilingDependents "InstanceProfileReady=Unknown, ValidationSucceeded=Unknown"`, and the controller logs `Reconciler error` `creating instance profile, ensuring role attached, adding role to instance profile, operation error IAM: AddRoleToInstanceProfile, … api error AccessDenied`. It is `AccessDenied`, not `NoSuchEntity`: the controller may only pass the node role. After fixing IAM, add any annotation to the EC2NodeClass to force re-validation.

### Step 3.4 — Clean up
```bash
kubectl delete -f manifests/13-troubleshooting/lab3-workload.yaml
kubectl delete -f manifests/13-troubleshooting/lab3-broken-nodepool.yaml --timeout=5m
kubectl delete -f manifests/13-troubleshooting/lab3-broken-nodeclass.yaml --timeout=3m
```
Expected: the NodePool delete returns at once; the EC2NodeClass delete blocks until the `lab3-broken` node is terminated (~40 s).

---

**Lab 4 — Pod too big for any instance type**

### Step 4.1 — Break
The `default` NodePool only allows 2- or 4-vCPU instances. This pod asks for 8 CPU.
```bash
kubectl apply -f manifests/13-troubleshooting/lab4-too-big.yaml
sleep 20
kubectl -n demo get events --field-selector reason=FailedScheduling -o json \
  | jq -r '.items[] | select(.source.component=="karpenter" and (.involvedObject.name|startswith("lab4"))) | .message' | sort -u | cut -c1-200
```
Expected: pod `Pending`, no NodeClaim, and `Failed to schedule pod, no instance type has enough resources, requirements=karpenter.k8s.aws/ec2nodeclass In [default], karpenter.k8s.aws/instance-category In [c m r], karpenter.k8s.aws/instance-cpu …` (cut at 200 chars; requirements are sorted by key). The full message ends with `kubernetes.io/os In [linux], resources={"cpu":"8160m","memory":"1056Mi","pods":"5"}` (pod + 160m / 32Mi DaemonSet overhead). With CAST AI connected its spot-handler DaemonSet adds one pod: `{"cpu":"8180m","memory":"1096Mi","pods":"6"}`.

### Step 4.2 — Fix
Right-size the request to fit a 4-vCPU node (about 3.8 CPU allocatable after reservations and DaemonSets):
```bash
kubectl -n demo set resources deploy/lab4-too-big --requests=cpu=3,memory=1Gi
kubectl -n demo rollout status deploy/lab4-too-big --timeout=180s
kubectl get nodeclaims -L karpenter.k8s.aws/instance-cpu
```
Expected: a new 4-vCPU Spot NodeClaim (validation run `c5a.xlarge`, `INSTANCE-CPU 4`), pod `Running` in ~35 s.

### Step 4.3 — Clean up
```bash
kubectl delete -f manifests/13-troubleshooting/lab4-too-big.yaml
kubectl get nodeclaims -w
```
Expected: within ~2 minutes every NodeClaim is consolidated away (`consolidateAfter: 1m`). Ctrl-C when the list is empty. **Lab 5 must start with zero Karpenter nodes.**

---

**Lab 5 — Hitting the EC2 vCPU quota (controlled)**

Math: on-demand Standard quota 8 vCPU. The system node uses 2. `lab5-quota` is on-demand only, 4-vCPU types only, limit 8 (4 + 4 = 8 fits, so the limit is not the blocker). Two pods of 3 CPU each need two 4-vCPU nodes = 8 vCPU. The first launch succeeds (2 + 4 = 6), the second fails (6 + 4 = 10 > 8). Spot quota is untouched.

### Step 5.1 — Confirm the starting point
```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.[QuotaName,Value]' --output text
aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].[InstanceType,InstanceLifecycle||`on-demand`,Tags[?Key==`karpenter.sh/nodepool`]|[0].Value]' --output text
```
Expected: `Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances  8.0`, then exactly one line: `t3a.large  on-demand  None` (the system node). If any other instance is listed, wait for it to terminate first.

### Step 5.2 — Break
```bash
kubectl apply -f manifests/13-troubleshooting/lab5-quota-nodepool.yaml
kubectl apply -f manifests/13-troubleshooting/lab5-quota-workload.yaml
sleep 30
kubectl get nodeclaims -l karpenter.sh/nodepool=lab5-quota
kubectl -n demo get pods -l app=lab5-quota
```
Expected: one NodeClaim `lab5-quota-xxxxx` on-demand `c6a.xlarge` (READY `Unknown`, True ~30 s after creation). Pods: one `ContainerCreating` / `Running`, one `Pending`. The second NodeClaim is created at the same second, fails 3 s later and is deleted; a third try 10 s later fails the same way; you only see them in the claims watch or the logs. After that every 4-vCPU on-demand offering is cached as unavailable and Karpenter stops trying.

Note: if you re-run this lab within 3 minutes of a previous run, **nothing** launches until the cache expires (log `skipping, nodepool requirements filtered out all instance types`). Wait 3 minutes between runs.

### Step 5.3 — Symptom and diagnosis
```bash
kubectl get events -A --field-selector reason=InsufficientCapacityError -o json \
  | jq -r '.items[].message' | sort -u | cut -c1-300
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller --tail=-1 --since=3m \
  | jq -cR 'fromjson? | select(.message=="failed launching nodeclaim") | {NodeClaim: .NodeClaim.name, error: (.error[0:200])}' | tail -2
kubectl -n kube-system port-forward svc/karpenter 8080:8080 >/dev/null 2>&1 &
PF=$!; sleep 2
curl -s localhost:8080/metrics | grep '^karpenter_cloudprovider_instance_launch_failures_total'
kill $PF
```
Expected:
- Two events (one per failed NodeClaim): `NodeClaim lab5-quota-xxxxx event: creating instance, insufficient capacity, with fleet error(s), VcpuLimitExceeded: You have requested more vCPU capacity than your current vCPU limit of 8 allows for the instance bucket that the specified instance type belongs to. Please visit http://aws.amazon.com/c…`
- Log: two `failed launching nodeclaim` lines with the same error.
- Metric: three lines, one per zone, `karpenter_cloudprovider_instance_launch_failures_total{capacity_type="on-demand",reason="VCPULimitExceeded",zone="ap-south-1a",zone_id="aps1-az1"} 39` (one count per offering in the failed fleet request, ~40 per zone). A few `capacity_type="spot",reason="SpotQuotaExceeded"` lines can also show: Lab 4 launched while Lab 2's spot nodes still ran, and EC2 Fleet reported the over-quota spot pools it skipped.

Karpenter treats `VcpuLimitExceeded` like an insufficient-capacity error: it deletes the failed NodeClaim, caches the instance type + zone + on-demand offering as **unavailable for 3 minutes**, and retries with other offerings. Once every 4-vCPU on-demand offering is cached (~20 s in), the log says `skipping, nodepool requirements filtered out all instance types` and the pending pod's event becomes `Failed to schedule pod, incompatible requirements, key karpenter.sh/nodepool, karpenter.sh/nodepool In [lab5-quota] not in karpenter.sh/nodepool In [default]`: the emptied pool is skipped like a broken one.

If module 12's alert rules are loaded, `KarpenterLaunchFailures` (label `reason="VCPULimitExceeded"`) shows `firing` at http://localhost:9090/alerts within ~1 minute.

### Step 5.4 — Fix (revert immediately)
A real fix is a Service Quotas increase, Spot capacity, or smaller nodes. Here we remove the experiment.
```bash
kubectl delete -f manifests/13-troubleshooting/lab5-quota-workload.yaml
kubectl delete -f manifests/13-troubleshooting/lab5-quota-nodepool.yaml --timeout=5m
kubectl wait nodeclaims --all --for=delete --timeout=300s
aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].[InstanceType,InstanceLifecycle||`on-demand`]' --output text
```
Expected: the NodePool delete returns at once; the wait ends ~35 s later. Only `t3a.large  on-demand` remains. The unavailable-offering cache expires on its own within 3 minutes.

---

**Lab 6 — The Karpenter controller itself is unhealthy**

### Step 6.1 — Health checklist (healthy state)
```bash
kubectl -n kube-system get deploy,pods -l app.kubernetes.io/name=karpenter -o wide
kubectl get lease -n kube-system karpenter-leader-election \
  -o jsonpath='{.spec.holderIdentity}{"  renewed: "}{.spec.renewTime}{"\n"}'
KPOD=$(kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system port-forward "pod/${KPOD}" 8081:8081 >/dev/null 2>&1 &
PF=$!; sleep 2; curl -s localhost:8081/readyz; echo; kill $PF
kubectl get crd -o name | grep -E 'karpenter|capacitybuffers'
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -ci karpenter
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller --tail=-1 --since=15m \
  | jq -cR 'fromjson? | select(.level=="ERROR") | {time, message, error: (.error // "" | .[0:150])}' | tail -5
```
Expected:
- Deployment `1/1`, pod `Running` on the system node, 0 or few restarts.
- Lease holder `karpenter-<pod-hash>_<uuid>`, renewed within the last few seconds.
- `readyz` returns `ok` (the API pod proxy times out here, hence the port-forward).
- 5 CRDs: `nodepools.karpenter.sh`, `nodeclaims.karpenter.sh`, `nodeoverlays.karpenter.sh`, `ec2nodeclasses.karpenter.k8s.aws`, `capacitybuffers.autoscaling.x-k8s.io`.
- `0`: v1.14 ships **no webhooks**; a dead controller never blocks API writes.
- Recent ERROR lines: harmless `Reconciler error` `NodePool.karpenter.sh "lab5-quota" not found (nodeclaim=lab5-quota-…)` from the Lab 5 cleanup (with 5 lines, the earlier launch failures scroll off).

### Step 6.2 — Break: take the controller away
```bash
kubectl -n kube-system scale deploy/karpenter --replicas 0
kubectl -n demo scale deploy/inflate --replicas 2
sleep 45
kubectl -n demo get pods -l app=inflate
kubectl get nodeclaims
kubectl get lease -n kube-system karpenter-leader-election -o jsonpath='{"renewed: "}{.spec.renewTime}{"\n"}'
```
Expected: 2 pods `Pending`, `No resources found` for NodeClaims, and a lease `renewTime` from ~45 s ago that is no longer moving. Nothing else in the cluster notices: no webhook means `kubectl apply` of NodePools still works, it just has no effect.

### Step 6.3 — Fix
```bash
kubectl -n kube-system scale deploy/karpenter --replicas 1
kubectl -n kube-system rollout status deploy/karpenter --timeout=180s
kubectl -n demo rollout status deploy/inflate --timeout=240s
```
Expected: controller Ready in ~11 s, takes the lease, finds the pending pods, and a NodeClaim launches; inflate `Running` about 55 s after the scale-up.

### Step 6.4 — Clean up
```bash
kubectl -n demo scale deploy/inflate --replicas 0
```

## Talking points

- Always read **Karpenter's** `FailedScheduling` event, not just the scheduler's. The scheduler only says "no existing node fits"; Karpenter says why no *new* node can be made.
- Error messages name the offending requirement or resource. `In [arm64] not in … In [amd64]` means "pod wants X, pools allow Y".
- A NodePool referencing a non-Ready EC2NodeClass is silently skipped. Always check `kubectl get ec2nodeclasses` READY first.
- Limits are a guardrail against runaway cost. Expect `all available instance types exceed limits` before your AWS bill does.
- Quota and ICE errors are the same class to Karpenter: it caches the offering as unavailable for 3 minutes and falls back. Diversity (types, zones, Spot + on-demand) is the real fix; quota increases are the other.
- The controller is stateless: kill it and it rebuilds state from the API server and EC2. Running 2 replicas (leader election) makes restarts invisible.

## Reset

```bash
kubectl delete -f manifests/13-troubleshooting/ --ignore-not-found --timeout=5m
kubectl apply -f manifests/base/nodepool.yaml
kubectl -n kube-system scale deploy/karpenter --replicas 1
scripts/reset.sh
```

## Q&A prep

- **Pod Pending but no Karpenter event at all?** The pod may be ignored: already nominated, has a `nodeName`, uses unsupported DRA claims, or Karpenter is down (Lab 6). Check the controller first.
- **NodeClaim exists but never becomes Ready?** `kubectl describe nodeclaim`: `Launched=True, Registered=False` means the node cannot join (IAM access entry, SG, user data). Karpenter deletes it after the registration timeout (15 min) with reason `registration_timeout`.
- **How do I see ICE before it hurts?** `karpenter_cloudprovider_instance_launch_failures_total` by `reason` and `zone`.
- **Can I raise quotas from Karpenter?** No. Service Quotas is a manual (or automated) AWS request.
- **What if the subnets run out of IPs?** `InsufficientFreeAddressesInSubnet`; Karpenter marks that subnet as ICE'd and prefers other subnets.
- **Why is the karpenter pod Pending after an upgrade?** Default chart affinity (`karpenter.sh/nodepool DoesNotExist` + hostname anti-affinity + zone spread) with only one non-Karpenter node. Use 2 system nodes or `replicas: 1` as in this demo.
- **Debugging a single decision?** Turn on `logLevel=debug` (module 12), reproduce, revert.

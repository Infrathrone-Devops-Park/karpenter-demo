# 10 — Spot Interruption Handling

**Time:** 25 min · **Goal:** Show how Karpenter receives EC2 interruption events through SQS and replaces a Spot node before AWS takes it away.

## What you'll show

- The event path: EC2 / AWS Health → EventBridge rules → SQS queue → Karpenter interruption controller.
- Which events Karpenter acts on and which only produce a Kubernetes event (rebalance recommendation).
- **Demo A (real):** an AWS FIS experiment sends a genuine 2-minute Spot interruption notice to one Karpenter Spot node.
- Karpenter logs, events and metrics for the interruption, and a new NodeClaim created before the old one is gone.
- **Demo B (fallback, no FIS):** a hand-crafted SQS message in the exact shape Karpenter parses.
- Cleanup of the FIS experiment template.

## Concepts

### The event path

```text
 EC2 / AWS Health                 EventBridge rules (Terraform module)          SQS queue
 ────────────────                 ───────────────────────────────────           ─────────
 Spot Interruption Warning   ──▶  KarpenterSpotInterrupt-*            ──┐
 Instance Rebalance Recommend ──▶ KarpenterInstanceRebalance-*         ──┤
 Instance State-change        ──▶ KarpenterInstanceStateChange-*       ──┼──▶  Karpenter-karpenter-demo
 AWS Health Event (EC2)       ──▶ KarpenterHealthEvent-*               ──┤      (retention 300 s)
 Capacity Reservation warning ──▶ KarpenterCRInterruption-*            ──┘
                                                                               │ long-poll
                                                                               ▼
                                                          Karpenter controller "interruption"
                                                          settings.interruptionQueue = queue name
```

- The queue and the five rules are created by the Terraform `karpenter` module. Karpenter only needs `sqs:ReceiveMessage`, `sqs:DeleteMessage` and `sqs:GetQueueUrl`.
- Karpenter is told about the queue with Helm value `settings.interruptionQueue` (env `INTERRUPTION_QUEUE`). Empty means interruption handling is off.
- The parser matches each message on `version` + `source` + `detail-type`. Unknown messages become a `no_op` and are deleted.

### What Karpenter does per message kind (v1.14.1 source)

| EventBridge detail-type | Message kind (metric label) | Action |
|---|---|---|
| `EC2 Spot Instance Interruption Warning` | `spot_interrupted` | **CordonAndDrain**: delete the NodeClaim (taint, drain, terminate). Also marks that instance type + zone as unavailable for Spot (3 min) |
| `EC2 Instance Rebalance Recommendation` | `rebalance_recommendation` | **NoAction**: only a Kubernetes event `SpotRebalanceRecommendation` |
| `AWS Health Event` (service `EC2`, category `scheduledChange`) | `scheduled_change` | CordonAndDrain |
| `EC2 Instance State-change Notification` (`stopping`, `stopped`) | `instance_stopped` | CordonAndDrain |
| `EC2 Instance State-change Notification` (`shutting-down`, `terminated`) | `instance_terminated` | CordonAndDrain |
| `EC2 Capacity Reservation Instance Interruption Warning` | `capacity_reservation_interrupted` | CordonAndDrain |
| DescribeInstanceStatus poll (no queue needed): instance / system status failed | `instance_status` / `system_status` | ForcefulTermination |

- "CordonAndDrain" = Karpenter deletes the NodeClaim. The normal termination flow runs: taint `karpenter.sh/disrupted:NoSchedule`, evict pods (PDBs respected), terminate the instance.
- Pods on a node that is being deleted count as pending for the provisioner. Karpenter creates the replacement NodeClaim **right away**, in parallel with the drain. With a 2-minute warning and a ~30 s node launch, the new node is usually Ready before AWS reclaims the old one.
- Interruption is a **forceful** disruption: NodePool disruption budgets and `karpenter.sh/do-not-disrupt` do not block it.
- Do not run AWS Node Termination Handler in queue mode next to Karpenter. Both would act on the same events.

### Capacity used in this module

- One Spot node, 2 vCPU (2 pods x 500m). During replacement there are 2 Spot nodes for about a minute = 4 of 8 Spot vCPU.
- Only the `default` NodePool (limit 10 CPU) is active. No on-demand capacity is used.

## Demo

### Step 1 — Load the environment and check BASELINE
Every module starts from the same state.
```bash
source scripts/env.sh
kubectl get nodepools,ec2nodeclasses,nodeclaims
kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type
```
Expected: `nodepool default` and `ec2nodeclass default` with `READY True`, `No resources found` for nodeclaims, and one node (the `system` node) with empty NODEPOOL / CAPACITY-TYPE columns.

### Step 2 — Show the queue wiring
Prove Karpenter is pointed at the queue Terraform created.
```bash
echo "$KARPENTER_QUEUE"
kubectl -n kube-system get deploy karpenter \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="INTERRUPTION_QUEUE")].value}{"\n"}'
aws events list-rules --name-prefix Karpenter --query 'Rules[].Name' --output table
```
Expected: `Karpenter-karpenter-demo` twice, then a table of five rules whose names start with `KarpenterHealthEvent-`, `KarpenterSpotInterrupt-`, `KarpenterInstanceRebalance-`, `KarpenterInstanceStateChange-`, `KarpenterCRInterruption-`, each followed by a Terraform-generated suffix.

### Step 3 — Show the queue is empty and short-lived
```bash
QUEUE_URL=$(aws sqs get-queue-url --queue-name "$KARPENTER_QUEUE" --query QueueUrl --output text)
aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages MessageRetentionPeriod --output table
```
Expected: `ApproximateNumberOfMessages 0` and `MessageRetentionPeriod 300`. Karpenter drains the queue continuously; messages older than 5 minutes are useless anyway.

### Step 4 — Open the watch panes
Use a second and third terminal (both from repo root).
```bash
scripts/watch.sh claims
```
```bash
scripts/watch.sh pods
```
Expected: an empty NodeClaim watch and an empty pod watch for namespace `demo`.

### Step 5 — Create a Spot node on purpose
The workload pins itself to Spot with `nodeSelector: karpenter.sh/capacity-type: spot`.
```bash
kubectl apply -f manifests/10-spot/spot-workload.yaml
kubectl -n demo rollout status deploy/spot-demo --timeout=180s
kubectl get nodes -l karpenter.sh/capacity-type=spot \
  -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type,topology.kubernetes.io/zone
```
Expected: one NodeClaim `default-xxxxx` appears in the watch within ~5 s, the rollout finishes in about 30 s, and one node with `CAPACITY-TYPE spot`, a 2-vCPU type (validation run: `c8i-flex.large`; also seen `c6a.large`, `c5a.large`) and a zone `ap-south-1a|b|c`.

### Step 6 — Record which instance will be interrupted
```bash
SPOT_NODE=$(kubectl get nodes -l karpenter.sh/capacity-type=spot -o jsonpath='{.items[0].metadata.name}')
SPOT_ID=$(kubectl get node "$SPOT_NODE" -o jsonpath='{.spec.providerID}'); SPOT_ID=${SPOT_ID##*/}
echo "$SPOT_NODE $SPOT_ID"
aws ec2 describe-instances --instance-ids "$SPOT_ID" \
  --query 'Reservations[].Instances[].{Lifecycle:InstanceLifecycle,NodePool:Tags[?Key==`karpenter.sh/nodepool`]|[0].Value,State:State.Name}' --output table
```
Expected: node name `ip-10-0-…` and instance ID `i-…`. The table shows `Lifecycle spot`, `NodePool default`, `State running`. This tag is what the FIS template selects on.

### Step 7 — Demo A: create the FIS experiment template
The template targets `aws:ec2:spot-instance` with tags `karpenter.sh/nodepool=default` and `eks:eks-cluster-name=karpenter-demo`, picks `COUNT(1)`, and uses `durationBeforeInterruption: PT2M`. The role comes from Terraform; jq injects it.
```bash
FIS_ROLE_ARN=$(terraform -chdir=terraform output -raw fis_role_arn)
TEMPLATE_ID=$(aws fis create-experiment-template \
  --cli-input-json "$(jq --arg role "$FIS_ROLE_ARN" '.roleArn = $role' manifests/10-spot/fis-spot-template.json)" \
  --query 'experimentTemplate.id' --output text)
echo "$TEMPLATE_ID"
```
Expected: an ID like `EXTFA3W24fYzEiC`. FIS accepts the JSON as-is; the two `resourceTags` are ANDed.

### Step 8 — Start the experiment
```bash
EXPERIMENT_ID=$(aws fis start-experiment --experiment-template-id "$TEMPLATE_ID" \
  --tags Name=karpenter-spot-demo --query 'experiment.id' --output text)
aws fis get-experiment --id "$EXPERIMENT_ID" --query 'experiment.state' --output json
```
Expected: `EXP…` ID, state `{"status": "initiating"}` or `"running"`. FIS immediately sends a **rebalance recommendation** and the **2-minute interruption warning** to the selected instance.

### Step 9 — Watch Karpenter react
About 35 s after the experiment starts (FIS initiation, then EventBridge → SQS) the NodeClaim watch changes. Then read the controller log lines for the interruption.
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller --tail=-1 --since=5m \
  | jq -cR 'fromjson? | select(.message | test("interruption|provisionable|nodeclaim|tainted|deleted")) | {time, message, messageKind, action, NodeClaim: .NodeClaim.name}'
```
Expected (real run; `messageKind`/`action` are `null` on all but the first line; if Step 5 ran under 5 minutes ago, its `created`/`launched` lines for the original node come first):
```text
{"time":"...T17:41:36.269Z","message":"initiating delete from interruption message","messageKind":"spot_interrupted","action":"CordonAndDrain","NodeClaim":"default-wxdjj"}
{"time":"...T17:41:36.304Z","message":"tainted node",...,"NodeClaim":"default-wxdjj"}
{"time":"...T17:41:37.539Z","message":"found provisionable pod(s)",...}
{"time":"...T17:41:37.539Z","message":"computed new nodeclaim(s) to fit pod(s)",...}
{"time":"...T17:41:37.554Z","message":"created nodeclaim",...,"NodeClaim":"default-l2dv7"}
{"time":"...T17:41:40.026Z","message":"launched nodeclaim",...,"NodeClaim":"default-l2dv7"}
{"time":"...T17:41:56.016Z","message":"registered nodeclaim",...,"NodeClaim":"default-l2dv7"}
{"time":"...T17:42:09.001Z","message":"initialized nodeclaim",...,"NodeClaim":"default-l2dv7"}
{"time":"...T17:42:15.293Z","message":"deleted node",...,"NodeClaim":"default-wxdjj"}
{"time":"...T17:42:15.505Z","message":"deleted nodeclaim",...,"NodeClaim":"default-wxdjj"}
```
In the NodeClaim watch, the replacement is created 1 s after the warning, **while** the old NodeClaim still exists. The pod watch shows both pods go Pending at once (`terminationGracePeriodSeconds: 0`), then Running on the new node ~33 s later. The old node is gone ~40 s after the warning, well inside the 2 minutes.

### Step 10 — Show the Kubernetes events
```bash
kubectl get events -A --field-selector reason=SpotInterrupted
kubectl get events -A --field-selector reason=SpotRebalanceRecommendation
kubectl get events -A --field-selector reason=TerminatingOnInterruption
```
Expected:
- `SpotInterrupted` Warning on the NodeClaim and on the Node: `Spot interruption warning was triggered`.
- `SpotRebalanceRecommendation` Normal: `Spot rebalance recommendation was triggered` (event only, no drain), on the NodeClaim and the Node. FIS sends it together with the warning.
- All events are in namespace `default`, `LAST SEEN` about 1 min.
- `TerminatingOnInterruption` Warning: `Interruption triggered termination for the NodeClaim` and `... for the Node`.

### Step 11 — Show the replacement landed elsewhere
```bash
kubectl get nodes -l karpenter.sh/capacity-type=spot \
  -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone
kubectl -n demo get pods -o wide
```
Expected: one Spot node with a new name. Its instance type and/or zone usually differ from Step 5, because Karpenter put the interrupted offering (type + zone, Spot) in its unavailable-offerings cache for 3 minutes. Both pods Running on it.

### Step 12 — Show the interruption metrics
Port-forward to the controller metrics port. Note: the API server proxy (`kubectl get --raw .../services/karpenter:http-metrics/proxy/metrics`) times out on this cluster; the control plane cannot reach pod port 8080.
```bash
kubectl -n kube-system port-forward svc/karpenter 8080:8080 >/dev/null 2>&1 &
PF=$!; sleep 2
curl -s localhost:8080/metrics \
  | grep -E '^karpenter_interruption_(received|deleted)_messages_total|^karpenter_nodeclaims_disrupted_total'
kill $PF
```
Expected (counters are cumulative since the controller started, so earlier modules add to them):
- `karpenter_interruption_received_messages_total{message_type="spot_interrupted"} 1`
- `karpenter_interruption_received_messages_total{message_type="rebalance_recommendation"} 1`
- `message_type="instance_terminated"` and `message_type="no_op"` with large counts: every EC2 state change of every Karpenter node so far (validation run: 94 and 97)
- `karpenter_interruption_deleted_messages_total` equal to the sum of the received messages (193)
- `karpenter_nodeclaims_disrupted_total{capacity_type="spot",nodepool="default",reason="spot_interrupted"} 1`, next to earlier reasons (`empty`, `drifted`, `underutilized`, ...)

### Step 13 — Confirm the experiment finished and delete the template
```bash
aws fis get-experiment --id "$EXPERIMENT_ID" --query 'experiment.state' --output json
aws fis delete-experiment-template --id "$TEMPLATE_ID" --query 'experimentTemplate.id' --output text
```
Expected: `{"status": "completed", "reason": "Experiment completed."}`. The experiment completes ~35 s after start, once the notice is sent; it does not wait out the 2 minutes. Then the template ID is echoed back by the delete. The old instance shows `terminated` with `Client.UserInitiatedShutdown`: Karpenter terminated it before EC2 did.

### Step 14 — Demo B (fallback): send a synthetic interruption message
Use this when FIS is unavailable or as a second run. Karpenter only checks `version`, `source`, `detail-type` and reads `detail.instance-id`. It does not verify the sender.
```bash
SPOT_NODE=$(kubectl get nodes -l karpenter.sh/capacity-type=spot -o jsonpath='{.items[0].metadata.name}')
SPOT_ID=$(kubectl get node "$SPOT_NODE" -o jsonpath='{.spec.providerID}'); SPOT_ID=${SPOT_ID##*/}
QUEUE_URL=$(aws sqs get-queue-url --queue-name "$KARPENTER_QUEUE" --query QueueUrl --output text)
MSG=$(jq -cn --arg id "$SPOT_ID" --arg acct "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" \
  --arg uuid "$(uuidgen)" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{version:"0", id:$uuid, "detail-type":"EC2 Spot Instance Interruption Warning", source:"aws.ec2",
    account:$acct, time:$now, region:$region,
    resources:["arn:aws:ec2:\($region):\($acct):instance/\($id)"],
    detail:{"instance-id":$id, "instance-action":"terminate"}}')
echo "$MSG" | jq .
aws sqs send-message --queue-url "$QUEUE_URL" --message-body "$MSG" --query MessageId --output text
```
Expected: the pretty-printed JSON, then a message ID. Within ~1 s the same flow as Step 9 runs (re-run the Step 9 log command): `initiating delete from interruption message` with `messageKind spot_interrupted`, a replacement NodeClaim 1 s later, pods Running ~33 s later, old node gone ~33 s after the message. This time **Karpenter** terminates the instance; EC2 never reclaims it. Same-account IAM principals can send to the queue (their identity policy allows it).

### Step 15 — Clean up
```bash
kubectl delete -f manifests/10-spot/spot-workload.yaml
kubectl get nodeclaims -w
```
Expected: the deployment is deleted. About 1 min 40 s later (`consolidateAfter: 1m`) the empty Spot NodeClaim disappears. Press Ctrl-C when the watch shows no NodeClaims.

## Talking points

- Spot gives you a **2-minute** warning. Karpenter turns that into: cordon, start the replacement, drain, terminate. The replacement is already booting while pods drain.
- The interrupted offering (instance type + zone, Spot) is avoided for 3 minutes. That is why the replacement often lands on a different type or AZ. Diverse NodePool requirements make this work; a single-type Spot pool would have nowhere to go.
- Rebalance recommendations are an early, noisy signal. Karpenter deliberately only records an event for them. Acting on every rebalance causes churn.
- Interruption is forceful. Budgets and `do-not-disrupt` do not stop it. **PDBs are still respected during the drain**, but AWS will not wait past the 2 minutes, so keep PDBs and `terminationGracePeriodSeconds` realistic for Spot workloads.
- Without the queue, Karpenter still finds unhealthy instances through `DescribeInstanceStatus` (1.12+), but it would not see the 2-minute Spot warning. Always configure `settings.interruptionQueue`.
- The FIS experiment is a real AWS-side interruption. The SQS message is a simulation of the event only: it tests the Karpenter path, not the EC2 path.

## Reset

```bash
kubectl delete -f manifests/10-spot/spot-workload.yaml --ignore-not-found
for id in $(aws fis list-experiment-templates --query "experimentTemplates[?tags.Name=='karpenter-spot-demo'].id" --output text); do
  aws fis delete-experiment-template --id "$id" --query 'experimentTemplate.id' --output text
done
scripts/reset.sh
```
Expected: `reset.sh` ends with zero NodeClaims, only `default` NodePool / EC2NodeClass, and `inflate` at 0 replicas.

## Q&A prep

- **Does Karpenter need the queue for Spot?** For the 2-minute warning, yes. Without it, the instance just disappears and pods are rescheduled after the node goes NotReady.
- **What if all Spot capacity is gone?** If the NodePool also allows `on-demand`, Karpenter falls back to it after Spot offerings are marked unavailable. Our `spot-demo` pods pin `spot`, so they would stay Pending.
- **Does FIS cost anything?** FIS charges per action-minute (cents). The Spot replacement costs the normal Spot price.
- **Can I see the raw SQS messages?** Not easily: Karpenter deletes them as soon as they are handled. Use the `karpenter_interruption_*` metrics and events instead.
- **What about the Spot "instance-action: stop/hibernate"?** Karpenter launches Spot via EC2 Fleet `instant` with terminate behaviour. The parser reads `instance-action`, but the action is always CordonAndDrain.
- **Is the rebalance recommendation ever useful?** You can alert on it. If you want proactive replacement on rebalance, Karpenter does not do it; that is a design choice to avoid churn.
- **Node Termination Handler?** Not needed with Karpenter. Running NTH in queue mode next to Karpenter makes both consume the same messages.

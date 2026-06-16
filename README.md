# Knative on Kind — Local Demo

A self-contained local setup of Knative Serving + Eventing on a Kind cluster, demonstrating scale-to-zero HTTP services and event-driven workloads.

---

## Prerequisites

Install the following before running the setup script.

### 1. Kind
```bash
# macOS
brew install kind

# Linux
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind
```

### 2. kubectl
```bash
# macOS
brew install kubectl

# Linux
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

### 3. kn (Knative CLI)
```bash
# macOS
brew install kn

# Linux — check https://github.com/knative/client/releases for latest
curl -LO https://github.com/knative/client/releases/latest/download/kn-linux-amd64
chmod +x kn-linux-amd64 && sudo mv kn-linux-amd64 /usr/local/bin/kn
```

### 4. kn-quickstart plugin
```bash
# macOS
brew install knative-extensions/kn-plugins/quickstart

# Linux — check https://github.com/knative-extensions/kn-plugin-quickstart/releases
curl -LO https://github.com/knative-extensions/kn-plugin-quickstart/releases/latest/download/kn-quickstart-linux-amd64
chmod +x kn-quickstart-linux-amd64 && sudo mv kn-quickstart-linux-amd64 /usr/local/bin/kn-quickstart
```

Verify the plugin is visible to `kn`:
```bash
kn plugin list
# Should show: kn-quickstart
```

---

## Setup

Run the setup script — it handles everything end to end:

```bash
chmod +x setup-knative.sh
./setup-knative.sh
```

The script will:

1. Create a Kind cluster named `knative` via the quickstart plugin
2. Install Knative Eventing (CRDs, core, in-memory channel, MT broker)
3. Patch Kourier's NodePort to `31080` (mapped to `localhost:8090` by Kind)
4. Deploy the `helloworld-go` Serving demo
5. Deploy the `event-display` Eventing sink
6. Create a Broker, PingSource (fires every minute), and Trigger

> **Note:** The quickstart plugin creates its own Kind cluster config. If you need a custom Kind config (e.g. a different `hostPort`), edit the `hostPort` in the script's Kourier patch step to match.

---

## Demo Walkthrough

### Part 1 — Knative Serving: Scale-to-Zero HTTP Service

**Call the service:**

```bash
curl -H "Host: helloworld-go.default.127.0.0.1.sslip.io" http://localhost
# → Hello Knative on Kind!!
```

**Watch scale-to-zero in action:**

Open two terminals.

Terminal 1 — watch pods:
```bash
kubectl get pods --watch
```

Terminal 2 — make a request, then wait:
```bash
curl -H "Host: helloworld-go.default.127.0.0.1.sslip.io" http://localhost
```

After ~90 seconds of no traffic you'll see the pod terminate in Terminal 1. Make another request — watch it cold-start back up in under a second.

**Deploy a new revision and split traffic:**

```bash
kn service update helloworld-go \
  --env TARGET="Revision 2" \
  --traffic helloworld-go-00001=50 \
  --traffic @latest=50
```

Now curl several times — roughly half the responses will say `Hello Revision 2!`. This is Knative's built-in canary/traffic splitting, with no extra tooling.

List all revisions:
```bash
kn revisions list
```

Roll back by shifting traffic:
```bash
kn service update helloworld-go --traffic helloworld-go-00001=100
```

**Cron Job Trigger**

Run in this cron task to run every 2 minutes:

```bash
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hello-cron
  namespace: default
spec:
  schedule: "*/2 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: curl
              image: curlimages/curl:latest
              args:
                - curl
                - -H
                - "Host: helloworld-go.default.127.0.0.1.sslip.io"
                - http://kourier.kourier-system.svc.cluster.local
          restartPolicy: OnFailure
EOF
```

You have two options: a native Kubernetes CronJob, or a Knative PingSource. Since `helloworld-go` just responds to plain HTTP (it doesn't parse CloudEvents), It is a more correct to use a CronJob. PingSource is better suited to services built to receive CloudEvents, like `event-display`.

Kubernetes CronJobs don't support sub-minute scheduling — 2 minutes is the minimum practical interval if you need something more frequent than that, you'd need a long-running pod with an internal loop instead.

---

### Part 2 — Knative Eventing: Event-Driven Services

**Check all resources are healthy:**

```bash
kubectl get ksvc,broker,pingsource,trigger -n default
```

All items should show `READY = True`. If anything shows `False`, see Troubleshooting below.

**Watch events arrive:**

```bash
kubectl logs -l serving.knative.dev/service=event-display -c user-container --follow
```

Wait up to 60 seconds for the PingSource to fire. You'll see a CloudEvent printed each minute:

```
☁️  cloudevents.Event
Context Attributes,
  specversion: 1.0
  type: dev.knative.sources.ping
  source: /apis/v1/namespaces/default/pingsources/ping-source
  id: <uuid>
  time: 2025-06-12T11:00:00Z
  datacontenttype: application/json
Data,
  {"message": "Hello from Knative!"}
```

**Understand the event chain:**

```
PingSource (every 1 min)
    │
    │  CloudEvent (HTTP POST)
    ▼
  Broker (default)
    │
    │  matches all events (no filter on Trigger)
    ▼
  Trigger (ping-trigger)
    │
    ▼
  Knative Service (event-display)
    │
    ▼
  Pod spins up, logs the event, spins back down
```

**Add a second Trigger with a filter:**

You can have multiple Triggers on the same Broker with different filters. Only events whose attributes match the filter are forwarded:

```bash
kubectl apply -f - <<EOF
apiVersion: eventing.knative.dev/v1
kind: Trigger
metadata:
  name: filtered-trigger
  namespace: default
spec:
  broker: default
  filter:
    attributes:
      type: dev.knative.sources.ping   # only ping events
  subscriber:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: event-display
EOF
```

**Send a manual CloudEvent:**

You can POST a CloudEvent directly to the Broker's URL without waiting for the PingSource:

```bash
# Get the Broker's in-cluster URL
BROKER_URL=$(kubectl get broker default -o jsonpath='{.status.address.url}')
echo $BROKER_URL

# Port-forward the broker ingress so you can reach it from localhost
kubectl port-forward -n knative-eventing svc/broker-ingress 8888:80 &

# Send a CloudEvent
curl -X POST http://localhost:8888/default/default \
  -H "Content-Type: application/json" \
  -H "Ce-Id: manual-001" \
  -H "Ce-Specversion: 1.0" \
  -H "Ce-Type: com.example.manual" \
  -H "Ce-Source: /local/manual" \
  -d '{"message": "Manually triggered event!"}'
```

Watch the logs — the event should appear within a few seconds.

---

## Resource Reference

| Command | Description |
|---|---|
| `kubectl get ksvc` | List all Knative Services |
| `kubectl get revisions` | List all Serving revisions |
| `kubectl get broker` | List Eventing brokers |
| `kubectl get pingsource` | List PingSources |
| `kubectl get trigger` | List Triggers |
| `kn service list` | kn CLI service overview |
| `kn revisions list` | kn CLI revision list |
| `kubectl get pods --watch` | Watch pod scale-up/down |

---

## Troubleshooting

**Broker shows no URL / READY is blank**

The broker controller may not have reconciled it. Delete and recreate:
```bash
kubectl delete broker default
kubectl apply -f - <<EOF
apiVersion: eventing.knative.dev/v1
kind: Broker
metadata:
  name: default
  namespace: default
EOF
kubectl wait --for=condition=ready broker/default --timeout=60s
```

Then delete and recreate the PingSource and Trigger so they re-resolve against the healthy Broker.

**PingSource shows `READY=False / NotFound`**

The Broker wasn't ready when PingSource was created. Delete and recreate after the Broker is healthy:
```bash
kubectl delete pingsource ping-source
# re-apply the PingSource YAML from the setup script
```

**curl returns `Connection reset by peer`**

Kourier's NodePort doesn't match the Kind port mapping. Check:
```bash
kubectl get svc kourier -n kourier-system
```
The HTTP NodePort must be `31080`. If it's different, patch it:
```bash
kubectl patch svc kourier -n kourier-system \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":31080}]'
```

**curl returns `404` or `no healthy upstream`**

The pod may have scaled to zero and is cold-starting. Wait 2–3 seconds and retry. If it persists, check:
```bash
kubectl get ksvc helloworld-go
kubectl describe ksvc helloworld-go
```

**No events appearing in logs**

Check the full chain:
```bash
kubectl get broker,pingsource,trigger -n default
# All should show READY=True

kubectl get pods -n knative-eventing
# All should show Running
```

---

## Teardown

```bash
kind delete cluster --name knative
```

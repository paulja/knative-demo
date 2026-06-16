#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# Knative on Kind — full setup script
# ─────────────────────────────────────────────
# Prerequisites: kind, kubectl, kn, kn-quickstart

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}▶ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}✗ $*${NC}"; exit 1; }
wait_ready() {
  local resource=$1 namespace=$2 label=$3
  info "Waiting for $resource in $namespace to be ready..."
  kubectl wait --for=condition=ready pod \
    -l "$label" \
    -n "$namespace" \
    --timeout=120s
}

# ─── 0. Check prerequisites ──────────────────
info "Checking prerequisites..."
for cmd in kind kubectl kn; do
  command -v "$cmd" &>/dev/null || die "$cmd is not installed. See README.md for install instructions."
done
kn plugin list 2>/dev/null | grep -q "kn-quickstart" \
  || die "kn-quickstart plugin not found. Install it and place it on your PATH as 'kn-quickstart'."
info "All prerequisites found."

# ─── 1. Create Kind cluster via quickstart ───
CLUSTER_NAME="knative"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Kind cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  info "Creating Kind cluster + installing Knative Serving via quickstart..."
  kn quickstart kind
fi

# ─── 2. Install Knative Eventing ─────────────
info "Installing Knative Eventing CRDs..."
kubectl apply -f https://github.com/knative/eventing/releases/latest/download/eventing-crds.yaml

info "Installing Knative Eventing core..."
kubectl apply -f https://github.com/knative/eventing/releases/latest/download/eventing-core.yaml

info "Installing in-memory channel..."
kubectl apply -f https://github.com/knative/eventing/releases/latest/download/in-memory-channel.yaml

info "Installing MT channel broker..."
kubectl apply -f https://github.com/knative/eventing/releases/latest/download/mt-channel-broker.yaml

info "Waiting for Eventing deployments to be ready..."
for deploy in eventing-controller eventing-webhook imc-controller imc-dispatcher \
              job-sink mt-broker-controller mt-broker-filter mt-broker-ingress; do
  kubectl rollout status deployment/"$deploy" -n knative-eventing --timeout=120s
done

# ─── 3. Fix Kourier NodePort to match kind config ───
# kn quickstart kind assigns a random NodePort; we pin it to 31080
# so that the Kind extraPortMappings (31080→8090) work correctly.
info "Patching Kourier NodePort to 31080..."
kubectl patch svc kourier \
  -n kourier-system \
  --type='json' \
  -p='[
    {"op":"replace","path":"/spec/ports/0/nodePort","value":31080},
    {"op":"replace","path":"/spec/ports/1/nodePort","value":31443}
  ]' || warn "Kourier NodePort patch failed — you may need to patch manually (see README)."

# ─── 4. Deploy the event-display service ─────
info "Deploying event-display Knative Service..."
kubectl apply -f - <<EOF
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: event-display
  namespace: default
spec:
  template:
    spec:
      containers:
        - image: gcr.io/knative-releases/knative.dev/eventing/cmd/event_display
          ports:
            - containerPort: 8080
EOF

info "Waiting for event-display to be ready..."
kubectl wait --for=condition=ready ksvc/event-display \
  -n default \
  --timeout=120s

# ─── 5. Create the Broker ─────────────────────
info "Creating default Broker..."
kubectl apply -f - <<EOF
apiVersion: eventing.knative.dev/v1
kind: Broker
metadata:
  name: default
  namespace: default
EOF

info "Waiting for Broker to be ready..."
kubectl wait --for=condition=ready broker/default \
  -n default \
  --timeout=60s

# ─── 6. Create the PingSource ─────────────────
info "Creating PingSource (fires every minute)..."
kubectl apply -f - <<EOF
apiVersion: sources.knative.dev/v1
kind: PingSource
metadata:
  name: ping-source
  namespace: default
spec:
  schedule: "*/1 * * * *"
  contentType: "application/json"
  data: '{"message": "Hello from Knative!"}'
  sink:
    ref:
      apiVersion: eventing.knative.dev/v1
      kind: Broker
      name: default
EOF

# ─── 7. Create the Trigger ────────────────────
info "Creating Trigger to route events to event-display..."
kubectl apply -f - <<EOF
apiVersion: eventing.knative.dev/v1
kind: Trigger
metadata:
  name: ping-trigger
  namespace: default
spec:
  broker: default
  subscriber:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: event-display
EOF

info "Waiting for Trigger to be ready..."
kubectl wait --for=condition=ready trigger/ping-trigger \
  -n default \
  --timeout=60s

# ─── 8. Deploy the helloworld-go service ──────
info "Deploying helloworld-go Knative Service..."
kn service create helloworld-go \
  --image ghcr.io/knative/helloworld-go:latest \
  --env TARGET="Knative on Kind!" \
  --namespace default 2>/dev/null \
  || kn service update helloworld-go \
       --image ghcr.io/knative/helloworld-go:latest \
       --env TARGET="Knative on Kind!" \
       --namespace default

info "Waiting for helloworld-go to be ready..."
kubectl wait --for=condition=ready ksvc/helloworld-go \
  -n default \
  --timeout=120s

# ─── Done ──────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       Knative setup complete! 🎉             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "  Serving demo:"
echo "    curl -H 'Host: helloworld-go.default.127.0.0.1.sslip.io' http://localhost"
echo ""
echo "  Eventing demo (watch for events every ~60s):"
echo "    kubectl logs -l serving.knative.dev/service=event-display -c user-container --follow"
echo ""
echo "  Check resource status:"
echo "    kubectl get ksvc,broker,pingsource,trigger -n default"
echo ""

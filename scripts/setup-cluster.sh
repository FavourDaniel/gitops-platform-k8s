#!/bin/bash

# Exit on failure + unset variables + pipeline failures
set -euo pipefail

# --- MINIMALIST COLORS & TYPOGRAPHY ---
BOLD='\033[1m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m' # No Color

# --- SLEEK LOGGING FUNCTIONS ---
info() { echo -e "${BLUE}::${NC} $1"; }
success() { echo -e "${GREEN}✔${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
error() { echo -e "${RED}✘${NC} $1"; exit 1; }
header() { echo -e "\n${BOLD}==> $1${NC}"; }

# --- DOCKER-STYLE COMMAND EXECUTION ---
# Runs a command, showing its output in grey on a single refreshing line
run_live() {
    "$@" 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
        local width=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
        local truncated=${line:0:$((width - 5))}
        printf "\r\033[K${DIM}  > %s${NC}" "$truncated"
    done

    local exit_code=${PIPESTATUS[0]}
    printf "\r\033[K"
    return $exit_code
}

# Navigate to project root so relative paths work automatically
cd "$(dirname "$0")/.."

# ==============================================================================
# 1. PRE-FLIGHT CHECKS
# ==============================================================================
header "System Checks"
for tool in kind kubectl argocd docker jq; do
    if ! command -v $tool &> /dev/null; then
        error "$tool is not installed. Please install it first."
    fi
done

if ! docker info > /dev/null 2>&1; then
  error "Docker is not running. Please start Docker."
fi
success "All dependencies verified."

# ==============================================================================
# 2. CLUSTER BOOTSTRAP
# ==============================================================================
header "Provisioning Infrastructure"
for CLUSTER in mgmt dev staging; do
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER}$"; then
        warn "Cluster '$CLUSTER' already exists. Skipping creation."
    else
        info "Creating cluster: $CLUSTER"
        run_live kind create cluster --name "$CLUSTER"
    fi
done
success "Clusters are active."

# ==============================================================================
# 3. ARGO CD INSTALLATION
# ==============================================================================
header "Installing Control Plane (Argo CD)"
kubectl config use-context kind-mgmt > /dev/null 2>&1
kubectl config set-context --current --namespace=argocd > /dev/null 2>&1

if kubectl get deployment argocd-server -n argocd > /dev/null 2>&1; then
    warn "Argo CD already exists. Skipping installation."
else
    info "Downloading and applying Argo CD manifests..."
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
    run_live kubectl apply --server-side=true --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
fi

# THE AUTOMATION FIX: Declaratively patch Argo CD to support Kustomize + Helm
info "Configuring Argo CD engine (Enabling Helm for Kustomize)..."
kubectl patch configmap argocd-cm -n argocd --context kind-mgmt --type merge \
  -p '{"data":{"kustomize.buildOptions":"--enable-helm --load-restrictor=LoadRestrictionsNone"}}' > /dev/null 2>&1

# Restart the repo-server to ensure it picks up the new config map immediately
kubectl rollout restart deployment argocd-repo-server -n argocd --context kind-mgmt > /dev/null 2>&1

info "Waiting for Argo CD components to be fully ready..."

# The Self-Healing Watchdog Loop
for i in {1..30}; do
    if kubectl wait --for=condition=available --timeout=10s deployment --all -n argocd --context kind-mgmt > /dev/null 2>&1; then
        break
    fi
    CRASHED_PODS=$(kubectl get pods -n argocd --context kind-mgmt | grep "CrashLoopBackOff" | awk '{print $1}')
    if [ -n "$CRASHED_PODS" ]; then
        warn "Detected crashed Argo CD pods (likely local resource starvation). Auto-healing..."
        for pod in $CRASHED_PODS; do
            run_live kubectl delete pod "$pod" -n argocd --context kind-mgmt
        done
    fi
done

run_live kubectl wait --for=condition=available --timeout=300s deployment --all -n argocd --context kind-mgmt

success "Control plane is operational."

# ==============================================================================
# 4. TARGET CLUSTER REGISTRATION
# ==============================================================================
header "Linking Environments"

# PRE-SYNC CLEANUP: Remove stale cluster secrets and apps to force a clean state.
info "Clearing existing cluster metadata for a clean sync..."
kubectl delete secret -n argocd -l argocd.argoproj.io/secret-type=cluster --context kind-mgmt > /dev/null 2>&1 || true

info "Clearing stale applications to force template regeneration..."
run_live kubectl delete apps -n argocd --all --context kind-mgmt --wait=false


# Best Practice: Force-remove finalizers if they are hanging
info "Clearing stale applications..."
# 1. Trigger the standard delete (non-blocking)
kubectl delete apps -n argocd --all --context kind-mgmt --wait=false > /dev/null 2>&1 || true

# 2. Force-remove finalizers to prevent the "application is deleting" hang
# We use a subshell to avoid formatting characters breaking the command
STALE_APPS=$(kubectl get apps -n argocd -o name --context kind-mgmt 2>/dev/null)
if [ -n "$STALE_APPS" ]; then
    info "Force-clearing finalizers for stale apps..."
    echo "$STALE_APPS" | xargs -I {} kubectl patch {} -n argocd --context kind-mgmt --type merge -p '{"metadata":{"finalizers":null}}' > /dev/null 2>&1 || true
    success "Finalizers cleared."
fi



register_cluster() {
  local cluster_name=$1
  local env_label=$2
  local context="kind-${cluster_name}"

  # 1. Get the internal Docker IP (for Argo CD to use later)
  local cluster_ip
  cluster_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${cluster_name}-control-plane")
  local internal_server="https://${cluster_ip}:6443"

  info "Registering '$cluster_name' (Host will use local port, Argo CD will use $cluster_ip)"

  # Get the original localhost server URL that kind generated
  local original_server=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='${context}')].cluster.server}")

  # Ensure we are in the mgmt context so the Argo CLI saves the secret in the right place
  kubectl config use-context kind-mgmt > /dev/null 2>&1

  # 2. Add the cluster using the default host-accessible kubeconfig
  run_live argocd cluster add "$context" \
    --core \
    --upsert \
    --name "$cluster_name" \
    --label "env=$env_label" \
    --label "type=workload" \
    --system-namespace kube-system \
    --insecure \
    -y

  # 3. THE FIX: Patch the Argo CD secret to use the internal Docker IP
  info "Patching cluster secret for internal Docker routing..."
  
  # Find the secret Argo CD just created by matching the original localhost server URL
  local secret_name
  secret_name=$(kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=cluster -o json | jq -r ".items[] | select(.data.server | @base64d == \"$original_server\") | .metadata.name")

  if [ -n "$secret_name" ]; then
    # Use stringData to safely patch the server address without dealing with base64 quirks
    kubectl patch secret "$secret_name" -n argocd -p="{\"stringData\": {\"server\": \"$internal_server\"}}" > /dev/null 2>&1
    success "Registered '$cluster_name' successfully mapped to $internal_server"
  else
    error "Failed to find the Argo CD cluster secret to patch."
  fi
}

info "Registering workload clusters..."
register_cluster "dev" "development"
register_cluster "staging" "staging"

# ==============================================================================
# 4.5 REGISTER SOURCE REPOSITORY (DYNAMIC)
# ==============================================================================
header "Securing Git Source"
REPO_URL=$(git config --get remote.origin.url)
[ -z "$REPO_URL" ] && error "Could not detect a Git remote. Are you running this inside the repo?"

info "Detected repository: $REPO_URL"
run_live argocd repo add "$REPO_URL" --core --upsert
success "Repository trusted."

# ================================================
# 5. DEPLOY ROOT APPLICATION SET (THE SEED)
# ==============================================================================
header "Planting the GitOps Seeds"

if [ -d "bootstrap" ]; then
    for appset in bootstrap/*.yaml; do
        if [ -f "$appset" ]; then
            # REMOVED 'local' because we aren't inside a function
            appset_name=$(basename "$appset" .yaml)
            
            # Wipe old appsets to prevent "Invalid Value" schema conflicts
            kubectl delete appset "$appset_name" -n argocd --context kind-mgmt --wait=false > /dev/null 2>&1 || true
            
            info "Applying $(basename "$appset") to Management Cluster..."
            run_live kubectl apply -f "$appset" --context kind-mgmt
        fi
    done
    success "All ApplicationSets deployed! Argo CD is now watching the entire platform."
else
    error "bootstrap/ folder not found! Check your folder structure."
fi



# ==============================================================================
# 6. CREDENTIALS & ACCESS
# ==============================================================================
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo -e "\n${BOLD}------------------------------------------------------------${NC}"
echo -e "${GREEN}✔ GitOps Platform Bootstrap Complete${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo -e "  Dashboard URL :  https://localhost:8080"
echo -e "  Username      :  admin"
echo -e "  Password      :  ${BOLD}${ARGOCD_PASSWORD}${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}\n"

info "Establishing secure tunnel to dashboard... (Press Ctrl+C to disconnect)"
kubectl port-forward svc/argocd-server -n argocd 8080:443
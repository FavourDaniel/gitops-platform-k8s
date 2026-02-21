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
        # Get terminal width so long lines don't wrap and break the UI
        local width=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
        local truncated=${line:0:$((width - 5))}
        
        # \r moves to start of line, \033[K clears the line
        printf "\r\033[K${DIM}  > %s${NC}" "$truncated"
    done
    
    # Capture the exit code of the actual command, not the while loop
    local exit_code=${PIPESTATUS[0]}
    
    # Clear the transient line completely when done
    printf "\r\033[K"
    
    return $exit_code
}

# Navigate to project root so relative paths work automatically
cd "$(dirname "$0")/.."

# ==============================================================================
# 1. PRE-FLIGHT CHECKS
# ==============================================================================
header "System Checks"
for tool in kind kubectl argocd docker; do
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

    info "Waiting for Argo CD components to initialize..."
    run_live kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
fi
success "Control plane is operational."

# ==============================================================================
# 4. TARGET CLUSTER REGISTRATION
# ==============================================================================
header "Linking Environments"
run_live argocd login --core

register_cluster() {
  local cluster_name=$1
  local context="kind-${cluster_name}"
  local env_label=$2

  info "Registering target: $cluster_name (env=$env_label)"
  # We use the internal Docker DNS name (e.g., dev-control-plane) so Argo CD
  # can talk to the clusters from inside its own container.
  run_live argocd cluster add "$context" \
    --name "$cluster_name" \
    --label "env=$env_label" \
    --label "type=workload" \
    --server "https://${cluster_name}-control-plane:6443" \
    --upsert \
    -y
}

register_cluster "dev" "development"
register_cluster "staging" "staging"
success "Environments successfully linked."

# ==============================================================================
# 5. DEPLOY ROOT APPLICATION SET (THE SEED)
# ==============================================================================
header "Planting the GitOps Seed"
if [ -f "bootstrap/root-appset.yaml" ]; then
    info "Applying root-appset.yaml to Management Cluster..."
    run_live kubectl apply -f bootstrap/root-appset.yaml --context kind-mgmt
    success "ApplicationSet deployed! Argo CD is now watching Git."
else
    error "bootstrap/root-appset.yaml not found! Check your folder structure."
fi

# ==============================================================================
# 6. CREDENTIALS & ACCESS
# ==============================================================================
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo -e "\n${BOLD}------------------------------------------------------------${NC}"
echo -e "${GREEN}✔ GitOps Platform Bootstrap Complete${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo -e "  Dashboard URL :  https://localhost:8080"
echo -e "  Username      :  admin"
echo -e "  Password      :  ${BOLD}${ARGOCD_PASSWORD}${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}\n"

info "Establishing secure tunnel to dashboard... (Press Ctrl+C to disconnect)"
kubectl port-forward svc/argocd-server -n argocd 8080:443
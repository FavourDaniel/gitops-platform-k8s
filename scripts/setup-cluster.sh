#!/bin/bash

# Exit on failure + unset variables + pipeline failures
set -euo pipefail

# --- MINIMALIST COLORS & TYPOGRAPHY ---
BOLD='\033[1m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- SLEEK LOGGING FUNCTIONS ---
info() { echo -e "${BLUE}::${NC} $1"; }
success() { echo -e "${GREEN}✔${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
error() { echo -e "${RED}✘${NC} $1"; exit 1; }
header() { echo -e "\n${BOLD}==> $1${NC}"; }

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
        kind create cluster --name "$CLUSTER" > /dev/null 2>&1
    fi
done
success "Clusters are active."

# ==============================================================================
# 3. ARGO CD INSTALLATION
# ==============================================================================
header "Installing Control Plane (Argo CD)"
kubectl config use-context kind-mgmt > /dev/null 2>&1
kubectl config set-context --current --namespace=argocd > /dev/null 2>&1

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
kubectl apply --server-side=true --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml > /dev/null 2>&1

info "Waiting for Argo CD components to initialize..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd > /dev/null 2>&1
success "Control plane is operational."

# ==============================================================================
# 4. TARGET CLUSTER REGISTRATION
# ==============================================================================
header "Linking Environments"
argocd login --core > /dev/null 2>&1

register_cluster() {
  local cluster_name=$1
  local context="kind-${cluster_name}"
  local env_label=$2

  info "Registering target: $cluster_name (env=$env_label)"
  argocd cluster add "$context" \
    --name "$cluster_name" \
    --label "env=$env_label" \
    --label "type=workload" \
    --upsert \
    -y > /dev/null 2>&1
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
    kubectl apply -f bootstrap/root-appset.yaml --context kind-mgmt > /dev/null 2>&1
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
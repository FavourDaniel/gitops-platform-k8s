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
info()    { echo -e "${BLUE}::${NC} $1"; }
success() { echo -e "${GREEN}✔${NC} $1"; }
warn()    { echo -e "${YELLOW}!${NC} $1"; }
error()   { echo -e "${RED}✘${NC} $1"; exit 1; }
header()  { echo -e "\n${BOLD}==> $1${NC}"; }

# Navigate to project root so relative paths work automatically
cd "$(dirname "$0")/.."

# ==============================================================================
# PHASE 1: PRE-FLIGHT CHECKS
# In production this section is replaced by Terraform outputting a kubeconfig.
# Here we just verify local tooling is present.
# ==============================================================================
header "System Checks"
for tool in kind kubectl argocd docker jq; do
    command -v "$tool" &>/dev/null || error "$tool is not installed. Please install it first."
done
docker info &>/dev/null || error "Docker is not running. Please start Docker."
success "All dependencies verified."

# ==============================================================================
# PHASE 2: CLUSTER PROVISIONING
# In production: terraform apply. Here: kind create cluster.
# Treated as infrastructure — idempotent, no watchdog loops.
# ==============================================================================
header "Provisioning Infrastructure"
for CLUSTER in mgmt dev staging; do
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER}$"; then
        warn "Cluster '$CLUSTER' already exists. Skipping creation."
    else
        info "Creating cluster: $CLUSTER"
        kind create cluster --name "$CLUSTER"
    fi
done
success "Clusters are active."

# ==============================================================================
# PHASE 3: ARGO CD INSTALLATION
# In production: installed via Terraform or a dedicated Helm release.
# Here we treat this as a one-time infrastructure operation.
# NOTE: No watchdog loop. If pods crash, fix the root cause — don't mask it.
# ==============================================================================
header "Installing Control Plane (Argo CD)"
kubectl config use-context kind-mgmt

if kubectl get deployment argocd-server -n argocd &>/dev/null; then
    warn "Argo CD already installed. Skipping."
else
    info "Applying Argo CD manifests..."
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

    # Pin to a specific version — never use 'stable' in production as it is a
    # moving target and will cause non-deterministic behaviour across environments.
    ARGOCD_VERSION="v2.13.0"
    kubectl apply --server-side=true --force-conflicts -n argocd \
        -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
fi

# Configure Kustomize+Helm support declaratively
info "Configuring Argo CD engine (enabling Helm for Kustomize)..."
kubectl patch configmap argocd-cm -n argocd --context kind-mgmt --type merge \
    -p '{"data":{"kustomize.buildOptions":"--enable-helm --load-restrictor=LoadRestrictionsNone"}}' \
    &>/dev/null

# Restart the repo-server so it picks up the updated configmap immediately
kubectl rollout restart deployment argocd-repo-server -n argocd --context kind-mgmt &>/dev/null

# Wait for Argo CD — if this times out the script fails loudly.
# This is intentional: a timeout means something is genuinely broken and needs fixing.
info "Waiting for Argo CD to be ready (timeout: 5m)..."
kubectl wait --for=condition=available --timeout=300s \
    deployment --all -n argocd --context kind-mgmt

success "Control plane operational."

# ==============================================================================
# PHASE 4: SPOKE CLUSTER REGISTRATION
# Registers dev and staging into the mgmt Argo CD with Docker-internal IPs
# so in-cluster Argo CD can reach them across the Docker bridge network.
# This is the kind-specific workaround that would be replaced by proper
# VPC peering / private endpoints in a real cloud environment.
# ==============================================================================
header "Registering Spoke Clusters"

# Clean up stale cluster secrets only — do not touch applications
info "Clearing stale cluster registration secrets..."
kubectl delete secret -n argocd \
    -l argocd.argoproj.io/secret-type=cluster \
    --context kind-mgmt &>/dev/null || true

register_cluster() {
    local cluster_name=$1
    local env_label=$2
    local context="kind-${cluster_name}"

    # Get the internal Docker bridge IP — this is what in-cluster Argo CD uses
    local cluster_ip
    cluster_ip=$(docker inspect \
        -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
        "${cluster_name}-control-plane")
    local internal_server="https://${cluster_ip}:6443"

    # Get the localhost URL kind put in kubeconfig (used to find the right secret later)
    local original_server
    original_server=$(kubectl config view \
        -o jsonpath="{.clusters[?(@.name=='${context}')].cluster.server}")

    info "Registering '$cluster_name' → $internal_server"

    # Switch to mgmt context so argocd CLI saves the secret in the right cluster
    kubectl config use-context kind-mgmt

    argocd cluster add "$context" \
        --core \
        --upsert \
        --name "$cluster_name" \
        --label "env=$env_label" \
        --label "type=workload" \
        --system-namespace kube-system \
        --insecure \
        -y &>/dev/null

    # Patch the secret Argo CD created to use the internal Docker IP instead of localhost.
    # Without this, Argo CD can't reach the spoke clusters from inside the mgmt container.
    info "Patching cluster secret for internal Docker routing..."

    local secret_name
    secret_name=$(kubectl get secret -n argocd \
        -l argocd.argoproj.io/secret-type=cluster -o json | \
        jq -r ".items[] | select(.data.server | @base64d == \"$original_server\") | .metadata.name")

    [ -z "$secret_name" ] && error "Could not find Argo CD cluster secret for '$cluster_name'. Registration failed."

    kubectl patch secret "$secret_name" -n argocd \
        -p="{\"stringData\": {\"server\": \"$internal_server\"}}" &>/dev/null

    success "Registered '$cluster_name' → $internal_server"
}

register_cluster "dev" "development"
register_cluster "staging" "staging"

# ==============================================================================
# PHASE 5: TRUST SOURCE REPOSITORY
# In production: handled by Argo CD's repo-server with SSH keys or a
# GitHub App credential stored in a secret manager — never a PAT in plaintext.
# ==============================================================================
header "Securing Git Source"
REPO_URL=$(git config --get remote.origin.url)
[ -z "$REPO_URL" ] && error "No git remote found. Are you running this from inside the repo?"
info "Detected repository: $REPO_URL"
argocd repo add "$REPO_URL" --core --upsert &>/dev/null
success "Repository trusted."

# ==============================================================================
# PHASE 6: SEED THE GITOPS ENGINE (THE ONLY MANUAL APPLY)
# We apply exactly ONE file. Argo CD discovers everything else from git.
# This is the "bootstrap paradox" solution — one file to rule them all.
# ==============================================================================
header "Seeding GitOps Engine"

[ -f "bootstrap/parent-app.yaml" ] || error "bootstrap/parent-app.yaml not found. Cannot seed the platform."

info "Applying parent bootstrap application..."
kubectl apply -f bootstrap/parent-app.yaml \
    --context kind-mgmt \
    --server-side \
    --force-conflicts

success "Platform is now self-managing. Argo CD owns everything from here."


# Inject spoke cluster IPs so the Vault config job can register them
header "Injecting Cluster IPs for Vault Configuration"

DEV_IP=$(docker inspect \
    -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "dev-control-plane")
STAGING_IP=$(docker inspect \
    -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "staging-control-plane")

kubectl create secret generic cluster-ips \
    --namespace vault \
    --from-literal=dev-ip="${DEV_IP}" \
    --from-literal=staging-ip="${STAGING_IP}" \
    --dry-run=client -o yaml | \
kubectl apply -f - --context kind-mgmt

success "Cluster IPs injected."

# ==============================================================================
# CREDENTIALS & ACCESS
# In production: the initial admin secret is rotated immediately after
# install and SSO (Okta, GitHub OIDC) is configured. Never share this password.
# ==============================================================================
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

echo -e "\n${BOLD}------------------------------------------------------------${NC}"
echo -e "${GREEN}✔ GitOps Platform Bootstrap Complete${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo -e "  Dashboard URL :  https://localhost:8080"
echo -e "  Username      :  admin"
echo -e "  Password      :  ${BOLD}${ARGOCD_PASSWORD}${NC}"
echo -e ""
echo -e "  ${YELLOW}NOTE: Rotate this password immediately in any real environment.${NC}"
echo -e "  ${YELLOW}      Replace with SSO (GitHub OIDC / Okta) before going to prod.${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}\n"

info "Opening dashboard tunnel (Ctrl+C to disconnect)..."
kubectl port-forward svc/argocd-server -n argocd 8080:443
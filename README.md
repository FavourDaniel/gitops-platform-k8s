






remove handing processes
kill -9 $(lsof -ti :8080)

kill -9 $(lsof -ti :3000)



Do first — these are blockers:

Secrets management — adminPassword: admin in git is the most urgent. Everything else can wait but not this.
App-of-apps / parent bootstrap — you're manually applying files right now which defeats the purpose of GitOps

Do second — these make it genuinely production-grade:

Ingress + Cert-Manager — port-forwarding is a lab pattern, not production. Nothing is real until traffic flows properly
Kyverno policy enforcement — prevents bad deployments from ever reaching the cluster
Alertmanager + PrometheusRules — a dashboard nobody watches isn't monitoring, it's decoration

Do third — these are advanced delivery patterns:

Argo Rollouts — canary/blue-green only makes sense once your networking and observability are solid, otherwise you can't measure whether a canary is healthy



cilium-look into it












prerequisite
argocd cli installed
kind installed
kubectl

setup cluster script - 
cd scripts && chmod +x setup-cluster.sh
./setup-cluster.sh

argocd arch design setup
argocd - Standalone vs. hub-and-spoke
clusters: mgmt- hub, dev and staging- spoke

To ensure your project is "production-grade" and avoid common beginner mistakes, implement these patterns:
The "App-of-Apps" or ApplicationSet Pattern: Do not manually create applications in the Argo CD UI. Instead, create a "Root App" in Git that points to a folder containing all your other Application manifests. This ensures your entire Argo CD configuration is also version-controlled.
Separation of Source Code and Configuration: Never keep your Kubernetes manifests in the same repository as your application source code.
App Repo: Contains your Go/Python/Node code and a Dockerfile.
Config Repo: Contains your Helm charts, Kustomize overlays, and Argo CD manifests. This prevents CI loops where a manifest update triggers a code build.
Secrets Management: This is the most common mistake. Never store plain-text secrets in Git. Use one of the following production-grade tools:
Bitnami Sealed Secrets: Encrypts secrets into a format that is safe to store in Git and can only be decrypted by the cluster.
External Secrets Operator: Pulls secrets from a provider like AWS Secrets Manager, HashiCorp Vault, or Azure Key Vault.
Prune and Self-Heal: In your Application manifests, always enable automated: prune: true and selfHeal: true. This ensures that if someone manually edits a resource in the cluster (the "ClickOps" mistake), Argo CD will automatically revert it to match the "source of truth" in Git.
Namespace Isolation: Ensure Argo CD is running in its own protected namespace and that applications are deployed into restricted namespaces with appropriate ResourceQuotas and NetworkPolicies.
Use Kustomize or Helm to manage environment-specific changes (e.g., more replicas in Production than in Staging).
Implement Sealed Secrets early - it is the easiest way to learn secure GitOps without setting up a full Vault instance.

table
ToolRole in Your ProjectWhy?App-of-AppsThe "Bootstrap" layerIt's the first thing applied to the Hub cluster. It tells Argo CD to watch a specific Git repository and manage its own applications declaratively.ApplicationSetsThe "Factory" layerLives inside the App-of-Apps pattern. It automatically detects your dev, staging, and prod clusters and dynamically generates applications for them.HelmThe "Packaging" layerProvides the base templating for applications. It handles complex logic such as conditional configuration (e.g., adding a load balancer only in production).KustomizeThe "Environment" layerUsed for overlays. It applies environment-specific changes in a non-destructive way (e.g., updating image tags or replica counts per environment).

How it works in the "Hub-and-Spoke" model:
Management Cluster (Argo CD) pulls your Git repo.
It finds the Chart.yaml in your /base folder.
It uses Kustomize to "patch" that Helm chart for different clusters (e.g., adding more memory for Staging).

after running the script
move on to set up the "App-of-AppSets" production pattern.
folder structure
root-appset.yaml - This file is the engine of your entire GitOps platform. It uses a Matrix Generator, which is the most advanced and flexible way to deploy apps at scale. Create this in the bootstrap folder. 
- This resource includes the source repository, path within the repository, destination cluster, namespace, and synchronization policy.

list generator-we switch to this from matrix
there are different ways to write the applicationset file, argocd provides different generators as seen here. We are utilizing the matrix generator because 
now your repo has been added in the generator, push the whole folder to git. check your argocd 

Setup kustomization now

the actual application: https://github.com/podtato-head/podtato-head-app
Run this command to see what Helm named your Podtato-Head service in the dev cluster:
kubectl get svc -n podtato-app --context kind-dev
Look for the main service (usually something like dev-podtato-podtato-head). Copy that name and run:
kubectl port-forward svc/<YOUR-SERVICE-NAME> -n podtato-app 8081:8080 --context kind-dev
Open your browser and go to http://localhost:8081. You should see the Podtato-Head demo app! (Press Ctrl+C in your terminal when you are done looking).
kubectl port-forward svc/dev-podtato-podtato-head-frontend -n podtato-app 8081:8080 --context kind-dev
The port-forward command uses the format LOCAL_PORT:CLUSTER_PORT. Since the cluster service is listening on 8080, we just need to map it to a different available port on your Mac, like 8081.

✅ Observability stack on mgmt (Prometheus + Grafana)
✅ Podtato app deployed to dev and staging spokes

Why this is the "Production" Pivot
By moving to the App-of-Apps pattern, you've achieved Recursive Reconciliation.
Self-Healing Infrastructure: If a junior admin manually deletes the infra-appset, the parent-app will detect the drift and recreate it.
Clean State: Your shell script is now a "launcher" rather than a "manager". Once the parent-app is applied, Argo CD handles the heavy lifting of pulling the infra-appset and root-appset from Git.

Hashicorp vault - runs mgmt cluster only (hub) In a production-grade hub-and-spoke model, you want a Centralized Secret Authority. Running Vault in the mgmt cluster reduces the attack surface and operational overhead of managing three separate Vault instances. The dev and staging clusters will act as "clients" that request secrets from the hub.
2. How should apps authenticate to Vault?
Recommendation: Kubernetes auth Token auth is a security risk in GitOps because you'd have to figure out how to securely deliver the initial token. Kubernetes Auth is the "Gold Standard" for production. It allows Vault to verify a pod's identity by checking its ServiceAccount Token against the Kubernetes API. It is seamless, automated, and requires no manual password entry.
3. What secrets should we manage first?
Recommendation: All of the above To reach a "Zero-Trust" state, nothing sensitive should live in your Git repo.
Grafana admin password: This is currently hardcoded in your values.yaml.

Argo CD secrets: These allow Argo to talk to private repos or external clusters securely.

App secrets: Even simple apps like podtato-app eventually need database creds or API keys.

mgmt cluster
├── Vault (source of truth for all secrets)
├── ESO (syncs secrets for mgmt workloads)
└── Prometheus/Grafana (reads grafana-admin-credentials Secret)

dev cluster
└── ESO (syncs secrets from Vault on mgmt)

staging cluster
└── ESO (syncs secrets from Vault on mgmt)

push only vault folder first and the injection part of the script
run checks:
kubectl get pods -n vault --context kind-mgmt
kubectl logs -n vault job/vault-init-config --context kind-mgmt
kubectl get app mgmt-vault -n argocd --context kind-mgmt -o jsonpath='{.status.operationState}' | jq .

To login to grafana
kubectl exec -n vault vault-0 --context kind-mgmt -- \
  vault kv get secret/grafana
kubectl port-forward svc/prometheus-grafana -n observability 3000:80 --context kind-mgmt

Vault
infrastructure/vault
infrastructure/vault/overlays/mgmt/kustomization.yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - vault-config-job.yaml

helmGlobals:
  chartHome: /tmp

helmCharts:
  - name: vault
    repo: https://helm.releases.hashicorp.com
    version: 0.28.0
    releaseName: vault
    namespace: vault
    valuesInline:
      server:
        dev:
          enabled: true        # dev mode for local - no unsealing needed
          devRootToken: "root" # in prod this is replaced by auto-unseal (AWS KMS)
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 250m
            memory: 256Mi
        readinessProbe:
          exec:
            command:
              - /bin/sh
              - -ec
              - vault status -tls-skip-verify
          initialDelaySeconds: 10
          timeoutSeconds: 10    # increased from 3s
          periodSeconds: 10
          failureThreshold: 3
        livenessProbe:
          exec:
            command:
              - /bin/sh
              - -ec
              - vault status -tls-skip-verify
          initialDelaySeconds: 30
          timeoutSeconds: 10
          periodSeconds: 10
          failureThreshold: 3            
      ui:
        enabled: true          # gives you the Vault web UI
      injector:
        enabled: false         # we use ESO not the sidecar injector
infrastructure/vault/overlays/mgmt/vault-config-job.yaml
# infrastructure/vault/overlays/mgmt/vault-config-job.yaml
#
# Production-grade Vault initialisation job.
#
# Key security properties:
#   1. No hardcoded credentials - passwords generated at runtime with openssl
#   2. No root token in git - annotated clearly as dev-mode only
#   3. Least-privilege RBAC - init SA can only read the cluster-ips secret
#   4. Idempotent - safe to re-run, will not overwrite real credentials
#   5. kind-specific overrides are clearly labeled
#
# NOTE ON VAULT_TOKEN IN DEV vs PROD:
#   kind/dev:  Vault runs in dev mode (storage: inmem, auto-unsealed, root token
#              is the well-known string "root"). Acceptable ONLY because the
#              cluster is ephemeral and not network-accessible.
#   production: Use a scoped bootstrap token created from the initial root token,
#              stored in AWS SSM / GCP Secret Manager, injected at runtime.
#              Revoke the initial root token immediately after first setup.
#              The root token must NEVER appear in git or CI logs in prod.
# ==============================================================================

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-init-sa
  namespace: vault
  annotations:
    argocd.argoproj.io/sync-wave: "1"

---
# Least privilege: only read the cluster-ips secret in the vault namespace.
# No cluster-admin, no wildcards.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: vault-init-role
  namespace: vault
  annotations:
    argocd.argoproj.io/sync-wave: "1"
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["cluster-ips"]
    verbs: ["get"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: vault-init-rolebinding
  namespace: vault
  annotations:
    argocd.argoproj.io/sync-wave: "1"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: vault-init-role
subjects:
  - kind: ServiceAccount
    name: vault-init-sa
    namespace: vault

---
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-init-config
  namespace: vault
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  labels:
    app.kubernetes.io/managed-by: argocd
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      serviceAccountName: vault-init-sa
      containers:
        - name: vault-init
          image: hashicorp/vault:1.17.0
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          env:
            - name: VAULT_ADDR
              value: "http://vault.vault.svc.cluster.local:8200"
            # KIND/DEV ONLY - see NOTE above
            # PRODUCTION: replace with secretKeyRef from your secret manager
            - name: VAULT_TOKEN
              value: "root"
            - name: DEV_CLUSTER_IP
              valueFrom:
                secretKeyRef:
                  name: cluster-ips
                  key: dev-ip
            - name: STAGING_CLUSTER_IP
              valueFrom:
                secretKeyRef:
                  name: cluster-ips
                  key: staging-ip
          command:
            - /bin/sh
            - -c
            - |
              set -e

              # ----------------------------------------------------------------
              # WAIT FOR VAULT
              # ----------------------------------------------------------------
              echo "[1/7] Waiting for Vault to be ready..."
              until vault status > /dev/null 2>&1; do
                echo "  Vault not ready yet, retrying in 3s..."
                sleep 3
              done
              echo "  Vault is ready."

              # ----------------------------------------------------------------
              # SECRETS ENGINE
              # ----------------------------------------------------------------
              echo "[2/7] Enabling KV v2 secrets engine..."
              vault secrets enable -path=secret kv-v2 2>/dev/null \
                || echo "  KV engine already enabled."

              # ----------------------------------------------------------------
              # IDEMPOTENCY GUARD
              #
              # Read current password from Vault.
              # Known seed values that must be replaced:
              #   - empty string (never written)
              #   - "changeme123" (old hardcoded value from previous job versions)
              #   - "n/a" (Vault display value for empty fields)
              #
              # If current password is none of these, real credentials exist
              # and we must not overwrite them.
              # ----------------------------------------------------------------
              echo "[3/7] Checking if real credentials already exist..."
              CURRENT_PASSWORD=$(vault kv get -field=admin-password secret/grafana 2>/dev/null || echo "")

              is_seed_value() {
                case "$1" in
                  ""|"changeme123"|"n/a") return 0 ;;  # is a seed value
                  *) return 1 ;;                        # is a real value
                esac
              }

              if is_seed_value "$CURRENT_PASSWORD"; then
                echo "  Seed or missing credentials detected. Generating real credentials..."
                SKIP_SECRET_GENERATION=false
              else
                echo "  Real credentials already exist. Skipping generation."
                SKIP_SECRET_GENERATION=true
              fi

              # ----------------------------------------------------------------
              # GENERATE AND WRITE SECRETS (first run only)
              #
              # Uses openssl - works on Linux and macOS, present in the Vault
              # container image. Produces a 32-char alphanumeric string with
              # ~190 bits of entropy. No shell-special characters.
              # ----------------------------------------------------------------
              if [ "$SKIP_SECRET_GENERATION" = "false" ]; then
                echo "[4/7] Generating strong random credentials..."

                GRAFANA_PASSWORD=$(openssl rand -base64 32 | tr -d '=/+' | cut -c1-32)
                ARGOCD_PASSWORD=$(openssl rand -base64 32 | tr -d '=/+' | cut -c1-32)

                # Validate - fail loudly if generation produced an empty string
                [ -z "$GRAFANA_PASSWORD" ] && echo "ERROR: Grafana password generation failed" && exit 1
                [ -z "$ARGOCD_PASSWORD" ]  && echo "ERROR: ArgoCD password generation failed"  && exit 1

                echo "  Writing Grafana credentials to Vault..."
                vault kv put secret/grafana \
                  admin-user=admin \
                  admin-password="${GRAFANA_PASSWORD}"

                echo "  Writing ArgoCD credentials to Vault..."
                vault kv put secret/argocd \
                  admin-password="${ARGOCD_PASSWORD}"

                # Print credentials ONCE to pod logs.
                # Retrieve with:
                #   kubectl logs -n vault -l job-name=vault-init-config
                # Logs are ephemeral - not stored in git or K8s etcd.
                # PRODUCTION: pipe directly to AWS SSM / GCP Secret Manager instead.
                echo ""
                echo "================================================================"
                echo "  BOOTSTRAP CREDENTIALS - retrieve once, then store securely  "
                echo "  kubectl logs -n vault -l job-name=vault-init-config          "
                echo "================================================================"
                echo "  Grafana  → admin / ${GRAFANA_PASSWORD}"
                echo "  ArgoCD   → admin / ${ARGOCD_PASSWORD}"
                echo "================================================================"
                echo ""
              else
                echo "[4/7] Skipping secret generation - real credentials exist."
              fi

              # ----------------------------------------------------------------
              # KUBERNETES AUTH - always re-applied for idempotency
              # ----------------------------------------------------------------
              echo "[5/7] Configuring Kubernetes auth methods..."

              vault auth enable -path=kubernetes/mgmt kubernetes 2>/dev/null \
                || echo "  kubernetes/mgmt already enabled."
              vault write auth/kubernetes/mgmt/config \
                kubernetes_host="https://kubernetes.default.svc.cluster.local:443"

              # KIND-SPECIFIC: insecure_tls=true acceptable for ephemeral local clusters only.
              # PRODUCTION: provide the CA bundle from each spoke cluster's kubeconfig.
              vault auth enable -path=kubernetes/dev kubernetes 2>/dev/null \
                || echo "  kubernetes/dev already enabled."
              vault write auth/kubernetes/dev/config \
                kubernetes_host="https://${DEV_CLUSTER_IP}:6443" \
                insecure_tls=true

              vault auth enable -path=kubernetes/staging kubernetes 2>/dev/null \
                || echo "  kubernetes/staging already enabled."
              vault write auth/kubernetes/staging/config \
                kubernetes_host="https://${STAGING_CLUSTER_IP}:6443" \
                insecure_tls=true

              # ----------------------------------------------------------------
              # POLICIES - least privilege, one policy per secret path
              # ----------------------------------------------------------------
              echo "[6/7] Writing Vault policies..."

              vault policy write grafana-policy - <<'POLICY'
              path "secret/data/grafana" {
                capabilities = ["read"]
              }
              POLICY

              vault policy write argocd-policy - <<'POLICY'
              path "secret/data/argocd" {
                capabilities = ["read"]
              }
              POLICY

              vault policy write app-policy - <<'POLICY'
              path "secret/data/apps/*" {
                capabilities = ["read"]
              }
              POLICY

              # ----------------------------------------------------------------
              # KUBERNETES AUTH ROLES
              # TTL=1h: tokens are short-lived and auto-rotated by ESO
              # ----------------------------------------------------------------
              echo "[7/7] Binding service accounts to policies..."

              vault write auth/kubernetes/mgmt/role/grafana \
                bound_service_account_names=prometheus-grafana \
                bound_service_account_namespaces=observability \
                policies=grafana-policy \
                ttl=1h

              vault write auth/kubernetes/mgmt/role/argocd \
                bound_service_account_names=argocd-server \
                bound_service_account_namespaces=argocd \
                policies=argocd-policy \
                ttl=1h

              vault write auth/kubernetes/dev/role/app \
                bound_service_account_names=default \
                bound_service_account_namespaces=podtato-app \
                policies=app-policy \
                ttl=1h

              vault write auth/kubernetes/staging/role/app \
                bound_service_account_names=default \
                bound_service_account_namespaces=podtato-app \
                policies=app-policy \
                ttl=1h

              echo ""
              echo "Vault configuration complete."
infrastructure/external-secrets/overlays/mgmt/cluster-secret-store.yaml
# Wave 1 within the external-secrets app - applied after the ESO Helm chart
# resources (wave 0 by default) so the CRD exists before we try to create
# a ClusterSecretStore instance.
---
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes/mgmt"
          role: "grafana"
          serviceAccountRef:
            name: prometheus-grafana
            namespace: observability
referenced in `infrastructure/external-secrets/overlays/mgmt/kustomization.yaml`
resources:
  - cluster-secret-store.yaml
Traefik and Cert Manager
Added bootstrap/argocd-httproute.yaml, infrastructure/cert-manager, infrastructure/traefik, infrastructure/observability/overlays/mgmt/grafana-httproute.yaml, infrastructure/vault/overlays/mgmt/vault-httproute.yaml

updated bootstrap/infra-appset.yaml
  generators:
    - list:
        elements:
          - name: ingress
            path: infrastructure/ingress/overlays/mgmt
            namespace: traefik
            wave: "1"

          - name: cert-manager
            path: infrastructure/cert-manager/overlays/mgmt
            namespace: cert-manager
            wave: "2"
infrastructure/observability/overlays/mgmt/kustomization.yaml
resources:
  - grafana-external-secret.yaml
  - grafana-httproute.yaml
infrastructure/vault/overlays/mgmt/kustomization.yaml
resources:
  - vault-config-job.yaml
  - vault-httproute.yaml

git commit -m "feat: add ingress layer (Traefik v3 + Gateway API) and cert-manager
- Add Traefik v3 as ingress controller using Gateway API (HTTPRoute)
- Add cert-manager with self-signed ClusterIssuer
- Add HTTPRoutes for Grafana, Vault, and Argo CD
- Update infra-appset wave ordering: ingress(1) cert-manager(2) vault(3) external-secrets(4) observability(5)
- Remove redundant Replace=false syncOption"
git push origin main
And add this to your `/etc/hosts` on your Mac: 
sudo sh -c 'echo "127.0.0.1 grafana.local vault.local argocd.local" >> /etc/hosts'
Browser → grafana.local:8080 → /etc/hosts resolves to 127.0.0.1 → kubectl port-forward picks it up → Traefik in the cluster → matches HTTPRoute for grafana.local → forwards to prometheus-grafana service → Grafana pod
# GitOps Platform on Kubernetes (Hub-and-Spoke)

A production-style **multi-cluster GitOps platform** built with Kubernetes using a **hub-and-spoke architecture**.

The platform separates the **control plane** from **application environments**, allowing centralized management of deployments, secrets, and observability across multiple clusters.

The management cluster hosts GitOps orchestration and shared platform services, while spoke clusters represent application environments such as **dev** and **staging**.

---

## Architecture

**Management Cluster**
- Argo CD (GitOps control plane)
- HashiCorp Vault (centralized secrets management)
- Prometheus + Grafana (observability)
- Traefik + cert-manager (ingress and TLS)

**Spoke Clusters**
- Dev cluster
- Staging cluster

Application workloads are deployed to spoke clusters while platform services remain centralized in the management cluster.

---

## Key Features

- **GitOps deployments** using Argo CD
- **App-of-Apps / ApplicationSet pattern** for multi-cluster management
- **Centralized secrets management** using Vault + External Secrets Operator
- **Platform observability** using Prometheus and Grafana
- **Secure ingress** with Traefik and cert-manager
- **Environment-specific configuration** using Helm + Kustomize overlays

---

## Tech Stack

- Kubernetes
- Argo CD
- HashiCorp Vault
- External Secrets Operator
- Prometheus
- Grafana
- Traefik
- cert-manager
- Helm
- Kustomize
- kind

---

## Repository Structure
```
gitops-platform-k8s/
.
├── README.md
├── apps
│   └── podtato-app
│       └── overlays
│           ├── development
│           │   └── kustomization.yaml
│           └── staging
│               └── kustomization.yaml
├── bootstrap
│   ├── infra-appset.yaml
│   ├── parent-app.yaml
│   └── root-appset.yaml
├── infrastructure
│   ├── cert-manager
│   │   └── overlays
│   │       └── mgmt
│   │           ├── cluster-issuer.yaml
│   │           └── kustomization.yaml
│   ├── external-secrets
│   │   └── overlays
│   │       ├── dev
│   │       │   ├── cluster-secret-store.yaml
│   │       │   └── kustomization.yaml
│   │       ├── mgmt
│   │       │   ├── cluster-secret-store.yaml
│   │       │   └── kustomization.yaml
│   │       └── staging
│   │           ├── cluster-secret-store.yaml
│   │           └── kustomization.yaml
│   ├── observability
│   │   ├── base
│   │   │   └── kustomization.yaml
│   │   └── overlays
│   │       ├── dev
│   │       ├── mgmt
│   │       │   ├── grafana-external-secret.yaml
│   │       │   ├── grafana-httproute.yaml
│   │       │   ├── kustomization.yaml
│   │       │   └── values.yaml
│   │       └── staging
│   ├── traefik
│   │   └── overlays
│   │       └── mgmt
│   │           ├── argocd-httproute.yaml
│   │           ├── gateway.yaml
│   │           └── kustomization.yaml
│   └── vault
│       └── overlays
│           └── mgmt
│               ├── kustomization.yaml
│               ├── vault-config-job.yaml
│               └── vault-httproute.yaml
└── scripts
    └── setup-cluster.sh
```

---

## Running Locally

### Prerequisites

Install:

- kind
- kubectl
- argocd CLI

### Setup

Clone the repository:

```bash
git clone https://github.com/FavourDaniel/gitops-platform-k8s.git
cd gitops-platform-k8s/scripts
```

Run the setup script:
```bash
chmod +x setup-cluster.sh
./setup-cluster.sh
```
This script creates the management, dev, and staging clusters and bootstraps the GitOps platform.
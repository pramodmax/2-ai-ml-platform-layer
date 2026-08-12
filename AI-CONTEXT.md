# AI-CONTEXT — Machine-readable reference for this repository

**Purpose:** Quick-load context for AI assistants working on this codebase. Covers architecture facts, exact file paths, wave ordering, and known constraints. Read this before making changes.

---

## What this repo does

- Terraform (`bootstrap/`) installs OpenShift GitOps (ArgoCD) and applies a root ArgoCD Application (`ai-ml-root`).
- `ai-ml-root` reads `gitops/applicationset.yaml` and creates one child Application per `gitops/core/*` directory.
- Child Applications auto-sync in ApplicationSet wave order. All secrets flow through HashiCorp Vault — nothing sensitive is in git.
- Target platform: Red Hat OpenShift AI 3.4 on OCP 4.19+.

---

## Key file map

| What you want to change | File |
|-------------------------|------|
| ArgoCD ApplicationSet template | `gitops/applicationset.yaml.tpl` |
| ArgoCD ApplicationSet (rendered, commit this) | `gitops/applicationset.yaml` |
| Root Application template | `gitops/root-application.yaml.tpl` |
| Terraform variables | `bootstrap/variables.tf`, `bootstrap/terraform.tfvars.example` |
| Terraform main logic | `bootstrap/main.tf` |
| Vault StatefulSet + config | `gitops/core/vault/vault-statefulset.yaml`, `gitops/core/vault/vault-config.yaml` |
| Vault init script (PostSync Job) | `gitops/core/vault/vault-init-script.yaml` |
| VSO subscription | `gitops/core/vault-secrets-operator/subscription.yaml` |
| VSO InstallPlan auto-approver | `gitops/core/vault-secrets-operator/installplan-approver-job.yaml` |
| VSO InstallPlan approver RBAC | `gitops/core/vault-secrets-operator/installplan-approver-rbac.yaml` |
| RustFS Deployment | `gitops/core/object-storage/rustfs-deployment.yaml` |
| RustFS VaultStaticSecret (server creds) | `gitops/core/object-storage/rustfs-vaultstatic.yaml` |
| RHOAI VaultStaticSecret (s3-credentials) | `gitops/core/object-storage/rhoai-vaultstatic.yaml` |
| VaultConnection CR | `gitops/core/object-storage/vault-connection.yaml` |
| VaultAuth CR | `gitops/core/object-storage/vault-auth.yaml` |
| RHOAI DSCInitialization | `gitops/core/rhoai/dsc-initialization.yaml` |
| RHOAI DataScienceCluster (toggle components) | `gitops/core/rhoai/data-science-cluster.yaml` |
| Kueue OperatorGroup | `gitops/core/kueue/operatorgroup-kueue.yaml` |
| JobSet OperatorGroup | `gitops/core/kueue/operatorgroup-jobset.yaml` |
| MLflow CR | `gitops/core/mlflow/mlflow.yaml` |
| All namespaces | `gitops/core/namespaces/` |
| GPU support (optional) | `gitops/opt/nfd/`, `gitops/opt/gpu/` |

---

## ApplicationSet wave order

| AppSet wave | Application name | Namespace | Notes |
|-------------|-----------------|-----------|-------|
| `-20` | `namespaces` | cluster-scoped | All namespaces created first |
| `-10` | `vault` | `vault` | Vault StatefulSet; PostSync `vault-init` Job |
| `-5` | `vault-secrets-operator` | `openshift-operators` | VSO operator; VaultConnection + VaultAuth CRs |
| `0` | `object-storage` | `object-storage` | RustFS + VaultStaticSecrets |
| `0` | `cert-manager` | `openshift-cert-manager-operator` | |
| `0` | `kueue` | `openshift-kueue-operator` | Kueue + JobSet operators |
| `0` | `rhoai` | `redhat-ods-operator` | RHOAI 3.4 |
| `0` | `rhsso` | `rhsso` | Red Hat SSO + Keycloak |
| `0` | `monitoring` | `openshift-monitoring` / `grafana` | |
| `0` | `data-science-project` | `data-science-project` | Tenant namespace |

---

## Resource wave order (within each Application)

| Wave | Resources |
|------|-----------|
| `-5` | Namespaces, monitoring ConfigMaps |
| `0` | OperatorGroups; VSO InstallPlan approver ServiceAccount + Role + RoleBinding |
| `1` | Subscriptions (all operators); VSO InstallPlan approver CronJob |
| `4` | VaultConnection, VaultAuth, VaultStaticSecret CRs → Secrets materialised by VSO |
| `5` | RustFS PVC, Service, Route |
| `6` | RustFS Deployment (depends on `rustfs-credentials` Secret from wave 4) |
| `10` | DSCInitialization |
| `15` | DataScienceCluster, Keycloak, Grafana instance |
| `20` | MLflow CR, Data Science Project RoleBindings |

---

## Vault secret paths → K8s Secrets

| Vault KV path | K8s Secret name | Namespace | Who reads it |
|---------------|-----------------|-----------|--------------|
| `secret/object-storage/rustfs` | `rustfs-credentials` | `object-storage` | RustFS Deployment (`RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY`) |
| `secret/object-storage/s3-credentials` | `s3-credentials` | `redhat-ods-applications` | RHOAI AI Pipelines + MLflow |

---

## Known constraints — read before editing

| Area | Constraint |
|------|------------|
| Vault listener | Must be `0.0.0.0:8200`, not `[::]:8200`. OCP sets `net.ipv6.bindv6only=1`; the IPv6 wildcard blocks IPv4 connections. File: `gitops/core/vault/vault-config.yaml` |
| Vault init image | `vault:1.15` has no `curl`. Init script uses `vault` CLI for health checks and `wget --no-check-certificate` for K8s API calls (BusyBox wget, no `--cacert`). File: `gitops/core/vault/vault-init-script.yaml` |
| VSO InstallPlan | `certified-operators` generates `RequiresApproval` InstallPlans even with `installPlanApproval: Automatic`. A CronJob at wave 1 polls every 2 min and patches `spec.approved: true`. File: `gitops/core/vault-secrets-operator/installplan-approver-job.yaml` |
| Wave deadlock (VSO CRs vs Deployment) | VaultStaticSecrets must be wave 4; RustFS Deployment must be wave 6. If the Deployment is at a lower wave than the VaultStaticSecret it starts before `rustfs-credentials` Secret exists and fails `secretKeyRef` lookup. |
| Kueue OperatorGroup | Must have empty `spec` (AllNamespaces). Adding `targetNamespaces` causes `OwnNamespace not supported` error from the operator. File: `gitops/core/kueue/operatorgroup-kueue.yaml` |
| JobSet OperatorGroup | Must have `targetNamespaces: [openshift-jobset-operator]` (OwnNamespace). Empty spec causes `AllNamespaces not supported` error from the operator. File: `gitops/core/kueue/operatorgroup-jobset.yaml` |
| ArgoCD PostSync hook deadlock | PostSync hooks fire only after all resources in the Application are Healthy. If a resource is waiting for something only the hook can provide, it deadlocks. The VSO InstallPlan approver was moved from a PostSync hook to a CronJob at wave 1 to avoid this. |
| `vault-bootstrap-creds` Secret | Must be created manually in the `vault` namespace before the root sync. The vault-init Job reads `RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY` from it. Never commit this Secret to git. |
| KServe + Service Mesh | `dsc-initialization.yaml` sets `serviceMesh.managementState: Managed`. Change to `Unmanaged` if a pre-existing SMCP exists on the cluster. |
| GPU support | Off by default. Set `enable_gpu = true` in `bootstrap/terraform.tfvars` and re-run `terraform apply` to include `gitops/opt/nfd` and `gitops/opt/gpu`. |
| MLflow | Technology Preview in RHOAI 3.4. Not for production model serving. |

---

## Operator channels and sources

| Operator | Package name | Source | Channel |
|----------|-------------|--------|---------|
| OpenShift GitOps | `openshift-gitops-operator` | `redhat-operators` | `latest` |
| cert-manager | `cert-manager` | `redhat-operators` | `stable-v1` |
| Kueue | `kueue-operator` | `redhat-operators` | `stable` |
| JobSet | `jobset-operator` | `redhat-operators` | `stable` |
| OpenShift Pipelines | `openshift-pipelines-operator-rh` | `redhat-operators` | `latest` |
| RHOAI | `rhods-operator` | `redhat-operators` | `stable` |
| Red Hat SSO | `rhsso-operator` | `redhat-operators` | `stable` |
| Vault Secrets Operator | `vault-secrets-operator` | `certified-operators` | `stable` |
| Grafana | `grafana-operator` | `community-operators` | `v5` |
| NFD | `nfd` | `redhat-operators` | `stable` (opt) |
| NVIDIA GPU Operator | `gpu-operator-certified` | `certified-operators` | `v26.3` (opt) |

---

## Bootstrap sequence (what Terraform does)

1. Run `bootstrap/scripts/validate-tfvars.sh` — aborts if required tfvars are missing
2. Run `bootstrap/scripts/check-cluster-prereqs.sh` — aborts if OCP < 4.19, no cluster-admin, OperatorHub not ready
3. Apply OpenShift GitOps operator Subscription + OperatorGroup
4. Wait for ArgoCD CRDs and `openshift-gitops-server` Deployment ready
5. Create ClusterRoleBinding: `openshift-gitops-argocd-application-controller` → `cluster-admin`
6. Render `gitops/applicationset.yaml` from `gitops/applicationset.yaml.tpl` (substitutes `gitops_repo_url`, `enable_gpu`)
7. Render `gitops/root-application.yaml` and apply it (manual sync — nothing deploys until operator clicks Sync)

Post-Terraform manual steps (in order):
1. `git add gitops/applicationset.yaml && git commit && git push`
2. `oc create namespace vault && oc create secret generic vault-bootstrap-creds -n vault ...`
3. ArgoCD UI → sync `ai-ml-root`

---

## Vault init Job behaviour

File: `gitops/core/vault/vault-init-script.yaml`

- Runs as a PostSync hook on the `vault` Application
- Uses `vault status` (vault CLI) to wait for Vault API — not curl
- Uses `wget --no-check-certificate` for K8s API Secret CRUD
- On first run: initialises Vault, stores unseal key + root token in `vault-unseal-keys` Secret in `vault` namespace
- On subsequent runs: reads `vault-unseal-keys`, unseals if sealed, skips init
- Enables KV-v2 engine at `secret/`
- Enables Kubernetes auth method; creates roles `object-storage` and `rhoai`
- Writes `secret/object-storage/rustfs` and `secret/object-storage/s3-credentials` from `vault-bootstrap-creds` Secret values

Retrieve root token after init:
```bash
oc get secret vault-unseal-keys -n vault -o jsonpath='{.data.root-token}' | base64 -d && echo
```

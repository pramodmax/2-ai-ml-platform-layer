#!/usr/bin/env bash
# Displays the public URLs and login credentials for every component deployed
# by the 2-ai-ml-platform-layer GitOps stack. Run this after all Argo CD sync
# waves have completed and all pods are Ready.
#
# Requirements: oc CLI, logged into the cluster with cluster-admin rights.

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}${CYAN}  $1${RESET}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"; }
label()   { echo -e "  ${BOLD}${GREEN}$1${RESET}"; }
value()   { echo -e "    $1"; }
warn()    { echo -e "  ${YELLOW}⚠  $1${RESET}"; }
err()     { echo -e "  ${RED}✗  $1${RESET}"; }
ok()      { echo -e "  ${GREEN}✔  $1${RESET}"; }
divider() { echo -e "  ${CYAN}──────────────────────────────────────────────────────${RESET}"; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
if ! command -v oc &>/dev/null; then
  echo -e "${RED}ERROR: 'oc' not found. Install the OpenShift CLI and re-run.${RESET}" >&2
  exit 1
fi

if ! oc whoami &>/dev/null; then
  echo -e "${RED}ERROR: Not logged into an OpenShift cluster. Run 'oc login ...' first.${RESET}" >&2
  exit 1
fi

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")

# ── Utility functions ─────────────────────────────────────────────────────────

# Print a route URL; emits a warning if the route does not exist yet.
get_route() {
  local ns="$1" name="$2"
  local host
  host=$(oc get route "$name" -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [[ -z "$host" ]]; then
    warn "Route '$name' in namespace '$ns' not found (not yet deployed or still syncing)"
    return
  fi
  local tls
  tls=$(oc get route "$name" -n "$ns" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
  if [[ -n "$tls" ]]; then
    echo "https://${host}"
  else
    echo "http://${host}"
  fi
}

# Decode a single key from a Kubernetes Secret.
get_secret_key() {
  local ns="$1" secret="$2" key="$3"
  local val
  val=$(oc get secret "$secret" -n "$ns" -o jsonpath="{.data['${key}']}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
  if [[ -z "$val" ]]; then
    warn "Secret '$secret' / key '$key' not found in namespace '$ns'"
    echo "<not available>"
  else
    echo "$val"
  fi
}

# First route matching a label selector — useful for operator-generated routes.
get_route_by_label() {
  local ns="$1" selector="$2"
  local host
  host=$(oc get route -n "$ns" -l "$selector" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  if [[ -z "$host" ]]; then
    echo ""
    return
  fi
  local tls
  tls=$(oc get route -n "$ns" -l "$selector" -o jsonpath='{.items[0].spec.tls.termination}' 2>/dev/null || echo "")
  if [[ -n "$tls" ]]; then echo "https://${host}"; else echo "http://${host}"; fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║    AI/ML Platform — Service URLs & Credentials          ║"
echo "  ║    Cluster: $(oc whoami --show-server 2>/dev/null | sed 's|https://||')$(printf '%*s' $((44 - ${#CLUSTER_DOMAIN})) '')║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo -e "  User     : $(oc whoami 2>/dev/null)"

# ═══════════════════════════════════════════════════════════════════════════════
# 1. OCP GitOps — Argo CD
# ═══════════════════════════════════════════════════════════════════════════════
header "1. OCP GitOps (Argo CD)"
echo -e "  Manages the entire platform GitOps deployment via ApplicationSet."
echo -e "  All other components below are synced through this Argo CD instance."
divider

ARGOCD_URL=$(get_route "openshift-gitops" "openshift-gitops-server")
label "Console URL :"
value "${ARGOCD_URL:-<not available>}"

label "Username    :"
value "admin"

label "Password    :"
ARGOCD_PASS=$(get_secret_key "openshift-gitops" "openshift-gitops-cluster" "admin.password")
value "${ARGOCD_PASS}"

echo ""
ok  "Also accessible via OpenShift console → Application Launcher → Cluster Argo CD"

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Cert Manager
# ═══════════════════════════════════════════════════════════════════════════════
header "2. Cert Manager"
echo -e "  Cluster-level TLS certificate controller — no browser UI."
echo -e "  Provides signed certificates for KServe InferenceService routes."
divider

label "Operator Namespace :"
value "openshift-cert-manager-operator"

label "Controller Namespace :"
value "cert-manager"

label "Status check :"
value "oc get pods -n cert-manager"

CSV=$(oc get csv -n openshift-cert-manager-operator \
       -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "<not installed>")
label "Installed CSV :"
value "${CSV}"

warn "No external UI — cert-manager is an in-cluster API only."

# ═══════════════════════════════════════════════════════════════════════════════
# 3. MLflow
# ═══════════════════════════════════════════════════════════════════════════════
header "3. MLflow"
echo -e "  Experiment tracking and model artefact store for RHOAI workloads."
echo -e "  Artefacts are stored in RustFS (S3-compatible) at s3://rhoai-models/mlflow."
divider

# MLflow is fronted by the data-science-gateway route; its path prefix is /mlflow
GW_HOST=$(oc get route data-science-gateway -n redhat-ods-applications \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [[ -n "$GW_HOST" ]]; then
  MLFLOW_URL="https://${GW_HOST}/mlflow"
else
  MLFLOW_URL=""
fi
label "Tracking UI URL :"
value "${MLFLOW_URL:-<not available — data-science-gateway route not yet created>}"

label "Authentication :"
value "RHOAI / OpenShift OAuth (no separate MLflow credentials)"

label "Artefact backend :"
value "s3://rhoai-models/mlflow  →  RustFS at rustfs.object-storage.svc.cluster.local:9000"

label "Status check :"
value "oc get mlflow mlflow -n redhat-ods-applications"

# ═══════════════════════════════════════════════════════════════════════════════
# 4. Grafana
# ═══════════════════════════════════════════════════════════════════════════════
header "4. Grafana"
echo -e "  Metrics dashboards sourced from the cluster Thanos Querier."
echo -e "  Monitors RHOAI workloads, GPU utilisation, and platform health."
divider

GRAFANA_URL=$(get_route "grafana" "grafana-route" 2>/dev/null)
if [[ -z "$GRAFANA_URL" ]]; then
  GRAFANA_URL=$(get_route_by_label "grafana" "app=grafana")
fi
label "Console URL :"
value "${GRAFANA_URL:-<not available>}"

label "Username    :"
GF_USER=$(get_secret_key "grafana" "grafana-admin-credentials" "GF_SECURITY_ADMIN_USER" 2>/dev/null)
value "${GF_USER:-admin}"

label "Password    :"
GF_PASS=$(get_secret_key "grafana" "grafana-admin-credentials" "GF_SECURITY_ADMIN_PASSWORD" 2>/dev/null)
value "${GF_PASS}"

label "Status check :"
value "oc get grafana grafana -n grafana"

# ═══════════════════════════════════════════════════════════════════════════════
# 5. RHSSO (Red Hat Single Sign-On / Keycloak)
# ═══════════════════════════════════════════════════════════════════════════════
header "5. RHSSO (Red Hat SSO / Keycloak)"
echo -e "  Identity provider for OpenShift OAuth and RHOAI workbench authentication."
echo -e "  Manages realms, clients, and OIDC tokens consumed by platform services."
divider

RHSSO_URL=$(get_route "rhsso" "keycloak" 2>/dev/null)
if [[ -z "$RHSSO_URL" ]]; then
  RHSSO_URL=$(get_route_by_label "rhsso" "app=keycloak")
fi
label "Admin Console URL :"
value "${RHSSO_URL:-<not available>}"
if [[ -n "$RHSSO_URL" ]]; then
  value "  → Admin UI: ${RHSSO_URL}/auth/admin"
fi

label "Admin Username :"
SSO_USER=$(get_secret_key "rhsso" "credential-rhsso" "ADMIN_USERNAME")
value "${SSO_USER}"

label "Admin Password :"
SSO_PASS=$(get_secret_key "rhsso" "credential-rhsso" "ADMIN_PASSWORD")
value "${SSO_PASS}"

label "Status check :"
value "oc get keycloak rhsso -n rhsso"

# ═══════════════════════════════════════════════════════════════════════════════
# 6. RustFS (S3-compatible Object Storage)
# ═══════════════════════════════════════════════════════════════════════════════
header "6. RustFS (S3-compatible Object Storage)"
echo -e "  Lightweight S3-compatible store used as the artefact backend for MLflow"
echo -e "  and as the model storage bucket for RHOAI/KServe."
divider

RUSTFS_URL=$(get_route "object-storage" "rustfs")
label "S3 API URL   :"
value "${RUSTFS_URL:-<not available>}"

label "Access Key   :"
RUSTFS_AK=$(get_secret_key "object-storage" "rustfs-credentials" "access-key")
value "${RUSTFS_AK}"

label "Secret Key   :"
RUSTFS_SK=$(get_secret_key "object-storage" "rustfs-credentials" "secret-key")
value "${RUSTFS_SK}"

label "Default Bucket :"
value "rhoai-models"

label "Internal endpoint (in-cluster) :"
value "http://rustfs.object-storage.svc.cluster.local:9000"

label "Status check :"
value "oc get deployment rustfs -n object-storage"

# ═══════════════════════════════════════════════════════════════════════════════
# 7. Vault (HashiCorp Vault)
# ═══════════════════════════════════════════════════════════════════════════════
header "7. Vault (HashiCorp Vault)"
echo -e "  In-cluster secrets engine. Stores RustFS credentials and S3 keys."
echo -e "  Vault Secrets Operator syncs secrets into target namespaces at runtime."
divider

VAULT_URL=$(get_route "vault" "vault")
label "UI / API URL  :"
value "${VAULT_URL:-<not available>}"

label "Auth method   :"
value "Token (root) — for initial admin access"

label "Root Token    :"
VAULT_TOKEN=$(get_secret_key "vault" "vault-unseal-keys" "root-token")
value "${VAULT_TOKEN}"

label "Unseal Key    :"
VAULT_UNSEAL=$(get_secret_key "vault" "vault-unseal-keys" "unseal-key")
value "${VAULT_UNSEAL}"

label "KV mount path :"
value "secret/  (KV-v2)"

label "Status check  :"
value "oc exec -n vault vault-0 -- vault status"

warn "Store the root token and unseal key securely — they are only for emergency"
warn "access. Day-to-day workloads authenticate via Kubernetes auth."

# ═══════════════════════════════════════════════════════════════════════════════
# 8. RHOAI (Red Hat OpenShift AI Dashboard)
# ═══════════════════════════════════════════════════════════════════════════════
header "8. RHOAI (Red Hat OpenShift AI)"
echo -e "  Central dashboard for data scientists: workbenches, pipelines, model"
echo -e "  serving, experiment tracking, and the model registry."
divider

RHOAI_URL=$(get_route "redhat-ods-applications" "rhods-dashboard" 2>/dev/null)
if [[ -z "$RHOAI_URL" ]]; then
  RHOAI_URL=$(get_route_by_label "redhat-ods-applications" "app=rhods-dashboard")
fi
label "Dashboard URL :"
value "${RHOAI_URL:-<not available>}"

label "Authentication :"
value "OpenShift OAuth — log in with your OCP cluster credentials"

label "Operator namespace :"
value "redhat-ods-operator"

label "Applications namespace :"
value "redhat-ods-applications"

label "Status check  :"
value "oc get datasciencecluster default-dsc"

ok  "RHOAI 3.4 — components: Dashboard, Workbenches, KServe, Pipelines (Argo),"
ok  "           MLflow, Model Registry, Ray, Training Operator"

# ═══════════════════════════════════════════════════════════════════════════════
# 9. Model Registry
# ═══════════════════════════════════════════════════════════════════════════════
header "9. Model Registry"
echo -e "  Central store for versioned model metadata, lineage, and artefact"
echo -e "  references. Managed by RHOAI and accessible from the RHOAI dashboard."
divider

MR_URL=$(get_route_by_label "rhoai-model-registries" "app=model-registry")
if [[ -z "$MR_URL" ]]; then
  MR_URL=$(oc get route -n rhoai-model-registries \
    -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  if [[ -n "$MR_URL" ]]; then
    MR_TLS=$(oc get route -n rhoai-model-registries \
      -o jsonpath='{.items[0].spec.tls.termination}' 2>/dev/null || echo "")
    [[ -n "$MR_TLS" ]] && MR_URL="https://${MR_URL}" || MR_URL="http://${MR_URL}"
  fi
fi

label "API / UI URL :"
if [[ -n "$MR_URL" ]]; then
  value "$MR_URL"
else
  value "Accessible via RHOAI Dashboard → Model Registry"
  value "  (direct route in namespace: rhoai-model-registries)"
fi

label "Registry namespace :"
value "rhoai-model-registries"

label "Authentication :"
value "OpenShift OAuth Bearer token (same as RHOAI)"

label "List routes :"
value "oc get route -n rhoai-model-registries"

label "Status check :"
value "oc get modelregistry -n rhoai-model-registries"

# ═══════════════════════════════════════════════════════════════════════════════
# Summary table
# ═══════════════════════════════════════════════════════════════════════════════
header "Summary — All Service URLs"
echo ""
printf "  %-30s %-10s %s\n" "Service" "Namespace" "URL"
printf "  %-30s %-10s %s\n" "──────────────────────────────" "─────────────────────" "──────────────────────────────────────────"

print_summary() {
  local svc="$1" ns="$2" url_cmd="$3"
  local url
  url=$(eval "$url_cmd" 2>/dev/null || echo "<not available>")
  printf "  %-30s %-20s %s\n" "$svc" "$ns" "${url:-<not available>}"
}

print_summary "OCP GitOps (Argo CD)" "openshift-gitops" \
  "oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='https://{.spec.host}'"
printf "  %-30s %-20s %s\n" "Cert Manager" "cert-manager" "<no external UI — in-cluster controller>"
print_summary "MLflow" "redhat-ods-applications" \
  "GH=\$(oc get route data-science-gateway -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null) && echo \"https://\${GH}/mlflow\""
print_summary "Grafana" "grafana" \
  "oc get route -n grafana -o jsonpath='https://{.items[0].spec.host}'"
print_summary "RHSSO (Keycloak)" "rhsso" \
  "oc get route keycloak -n rhsso -o jsonpath='https://{.spec.host}'"
print_summary "RustFS (Object Storage)" "object-storage" \
  "oc get route rustfs -n object-storage -o jsonpath='https://{.spec.host}'"
print_summary "Vault" "vault" \
  "oc get route vault -n vault -o jsonpath='https://{.spec.host}'"
print_summary "RHOAI Dashboard" "redhat-ods-applications" \
  "oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='https://{.spec.host}' 2>/dev/null || oc get route -n redhat-ods-applications -l app=rhods-dashboard -o jsonpath='https://{.items[0].spec.host}'"
print_summary "Model Registry" "rhoai-model-registries" \
  "oc get route -n rhoai-model-registries -o jsonpath='https://{.items[0].spec.host}' 2>/dev/null || echo '(see RHOAI dashboard)'"

echo ""
echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
echo -e "  Run ${BOLD}oc get route -A${RESET} to list every route across all namespaces."
echo ""

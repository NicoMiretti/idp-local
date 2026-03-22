#!/usr/bin/env bash
# bootstrap.sh
# Script principal de arranque del IDP local.
# Responsabilidad: crear el cluster Kind e instalar ArgoCD via Helm.
# NO despliega aplicaciones de plataforma — eso es responsabilidad de ArgoCD via GitOps.
#
# Uso: ./bootstrap/bootstrap.sh
# Requisitos: kind, kubectl, helm

set -euo pipefail

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

CLUSTER_NAME="idp-local"
ARGOCD_NAMESPACE="argocd"
ARGOCD_CHART_VERSION="7.7.3"   # Fijar versión para reproducibilidad
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Funciones helpers
# ---------------------------------------------------------------------------

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

check_deps() {
  log "Verificando dependencias..."
  for cmd in kind kubectl helm; do
    command -v "$cmd" &>/dev/null || fail "Dependencia no encontrada: $cmd"
  done
  log "Dependencias OK."
}

# ---------------------------------------------------------------------------
# 1. Crear cluster Kind
# ---------------------------------------------------------------------------

create_cluster() {
  log "Verificando si el cluster '${CLUSTER_NAME}' ya existe..."
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log "Cluster '${CLUSTER_NAME}' ya existe, saltando creación."
  else
    log "Creando cluster Kind '${CLUSTER_NAME}'..."
    kind create cluster --config "${SCRIPT_DIR}/kind-config.yaml"
    log "Cluster creado."
  fi
}

# ---------------------------------------------------------------------------
# 2. Instalar ArgoCD via Helm
# ---------------------------------------------------------------------------

install_argocd() {
  log "Agregando repositorio Helm de ArgoCD..."
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update

  log "Instalando ArgoCD en namespace '${ARGOCD_NAMESPACE}'..."
  helm upgrade --install argocd argo/argo-cd \
    --namespace "${ARGOCD_NAMESPACE}" \
    --create-namespace \
    --version "${ARGOCD_CHART_VERSION}" \
    --values "${REPO_ROOT}/gitops/argocd/values.yaml" \
    --wait
  log "ArgoCD instalado."
}

# ---------------------------------------------------------------------------
# 3. Esperar a que ArgoCD esté listo
# ---------------------------------------------------------------------------

wait_for_argocd() {
  log "Esperando a que argocd-server esté disponible..."
  kubectl wait deployment/argocd-server \
    --namespace "${ARGOCD_NAMESPACE}" \
    --for=condition=available \
    --timeout=180s
  log "argocd-server listo."
}

# ---------------------------------------------------------------------------
# 4. Aplicar la App-of-Apps raíz
# Recién aquí ArgoCD toma el control del resto del stack via GitOps.
# ---------------------------------------------------------------------------

apply_root_app() {
  log "Aplicando root-app (App-of-Apps)..."
  kubectl apply -f "${REPO_ROOT}/gitops/apps/root-app.yaml"
  log "root-app aplicada. ArgoCD se encarga del resto."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log "=== Iniciando bootstrap del IDP local ==="
  check_deps
  create_cluster
  install_argocd
  wait_for_argocd
  apply_root_app
  log "=== Bootstrap completado ==="
  log "ArgoCD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"
}

main "$@"

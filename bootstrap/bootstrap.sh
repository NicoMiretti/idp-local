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

REGISTRY_NAME="registry.local"
REGISTRY_PORT="5000"

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
# 1. Crear registry local
# ---------------------------------------------------------------------------

setup_registry() {
  log "Configurando registry local '${REGISTRY_NAME}'..."

  # Crear o reusar el contenedor del registry
  if docker inspect "${REGISTRY_NAME}" &>/dev/null; then
    log "Registry '${REGISTRY_NAME}' ya existe."
  else
    log "Iniciando contenedor registry..."
    docker run -d \
      --name "${REGISTRY_NAME}" \
      --restart=always \
      -p "127.0.0.1:${REGISTRY_PORT}:5000" \
      registry:2
    log "Registry iniciado."
  fi

  # Conectar al network de kind (por si no está conectado aún)
  if ! docker network inspect kind &>/dev/null; then
    log "Network 'kind' no existe todavía; se conectará después de crear el cluster."
    return 0
  fi
  if ! docker network inspect kind --format '{{range .Containers}}{{.Name}} {{end}}' | grep -qw "${REGISTRY_NAME}"; then
    log "Conectando registry al network 'kind'..."
    docker network connect kind "${REGISTRY_NAME}"
    log "Registry conectado a network 'kind'."
  else
    log "Registry ya conectado al network 'kind'."
  fi
}

# ---------------------------------------------------------------------------
# 2. Configurar containerd en el nodo Kind para el registry inseguro
# ---------------------------------------------------------------------------

configure_node_registry() {
  log "Configurando containerd en el nodo Kind para registry local..."

  local NODE="${CLUSTER_NAME}-control-plane"
  local REGISTRY_IP
  # Preferir la IP asignada en el network "kind" para garantizar conectividad
  REGISTRY_IP=$(docker inspect "${REGISTRY_NAME}" \
    --format '{{index .NetworkSettings.Networks "kind" "IPAddress"}}' 2>/dev/null)

  if [ -z "${REGISTRY_IP}" ]; then
    # Fallback: cualquier IP disponible
    REGISTRY_IP=$(docker inspect "${REGISTRY_NAME}" \
      --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | tr -s ' \n' '\n' | head -1)
  fi

  if [ -z "${REGISTRY_IP}" ]; then
    log "WARN: No se pudo obtener la IP del registry. Saltando configuración de /etc/hosts del nodo."
    return 0
  fi

  log "Registry IP en network kind: ${REGISTRY_IP}"

  # Agregar entrada en /etc/hosts del nodo (idempotente)
  docker exec "${NODE}" bash -c \
    "grep -q '${REGISTRY_NAME}' /etc/hosts || echo '${REGISTRY_IP} ${REGISTRY_NAME}' >> /etc/hosts"

  # Crear hosts.toml para registry.local:5000
  docker exec "${NODE}" mkdir -p "/etc/containerd/certs.d/${REGISTRY_NAME}:${REGISTRY_PORT}"
  docker exec "${NODE}" bash -c "cat > /etc/containerd/certs.d/${REGISTRY_NAME}:${REGISTRY_PORT}/hosts.toml << 'EOF'
server = \"http://${REGISTRY_NAME}:${REGISTRY_PORT}\"

[host.\"http://${REGISTRY_NAME}:${REGISTRY_PORT}\"]
  capabilities = [\"pull\", \"resolve\", \"push\"]
  skip_verify = true
EOF"

  # Crear hosts.toml para registry.local (sin puerto)
  docker exec "${NODE}" mkdir -p "/etc/containerd/certs.d/${REGISTRY_NAME}"
  docker exec "${NODE}" bash -c "cat > /etc/containerd/certs.d/${REGISTRY_NAME}/hosts.toml << 'EOF'
server = \"http://${REGISTRY_NAME}:${REGISTRY_PORT}\"

[host.\"http://${REGISTRY_NAME}:${REGISTRY_PORT}\"]
  capabilities = [\"pull\", \"resolve\", \"push\"]
  skip_verify = true
EOF"

  # Reiniciar containerd para aplicar config
  docker exec "${NODE}" systemctl restart containerd
  log "containerd reiniciado con configuración de registry local."

  # Crear ConfigMap local-registry-hosting en kube-public (estándar KEP-1755)
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "${REGISTRY_NAME}:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
  log "ConfigMap local-registry-hosting aplicado."
}

# ---------------------------------------------------------------------------
# 3. Crear cluster Kind
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
# 4. Instalar ArgoCD via Helm
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
# 5. Esperar a que ArgoCD esté listo
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
# 6. Aplicar la App-of-Apps raíz
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
  setup_registry
  create_cluster
  # Conectar registry al network kind (creado por kind create cluster)
  if ! docker network inspect kind --format '{{range .Containers}}{{.Name}} {{end}}' | grep -qw "${REGISTRY_NAME}"; then
    log "Conectando registry al network 'kind' (post cluster creation)..."
    docker network connect kind "${REGISTRY_NAME}"
  fi
  configure_node_registry
  install_argocd
  wait_for_argocd
  apply_root_app
  log "=== Bootstrap completado ==="
  log "ArgoCD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"
  log "Registry:  docker push 127.0.0.1:${REGISTRY_PORT}/<project>/<app>:latest"
  log "           (en el cluster usa registry.local:${REGISTRY_PORT}/<project>/<app>:latest)"
}

main "$@"

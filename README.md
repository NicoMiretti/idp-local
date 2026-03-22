# IDP Local

Internal Developer Platform local para entorno de tesis, basado en
Kind, ArgoCD, Backstage y Ansible.

---

## Descripción

Este proyecto implementa un Internal Developer Platform (IDP) que corre
completamente en una máquina local usando un cluster Kubernetes efímero
creado con Kind. El objetivo es explorar y validar los patrones de una
plataforma de desarrollo interno (GitOps, portal de desarrolladores,
automatización de infraestructura) en un entorno reproducible y de bajo
costo de recursos.

---

## Arquitectura

```
┌─────────────────────────────────────────────────────┐
│                  Máquina local                      │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │           Cluster Kind (single-node)         │   │
│  │                                              │   │
│  │  ┌─────────┐   App-of-Apps   ┌────────────┐  │   │
│  │  │  ArgoCD │ ─────────────▶  │  Backstage │  │   │
│  │  │         │                 ├────────────┤  │   │
│  │  │  GitOps │ ─────────────▶  │ Monitoring │  │   │
│  │  └─────────┘                 └────────────┘  │   │
│  │       ▲                                      │   │
│  └───────│──────────────────────────────────────┘   │
│          │ sincroniza                               │
│  ┌───────┴──────┐                                   │
│  │  Este repo   │  ← fuente de verdad (GitOps)      │
│  └──────────────┘                                   │
└─────────────────────────────────────────────────────┘
```

### Componentes

| Componente | Rol | Instalación |
|---|---|---|
| **Kind** | Cluster Kubernetes local single-node | `bootstrap.sh` |
| **ArgoCD** | Operador GitOps — sincroniza este repo con el cluster | Helm via `bootstrap.sh` |
| **Backstage** | Portal del desarrollador — catálogo de servicios y scaffolding | ArgoCD (GitOps) |
| **Monitoring** | Stack Prometheus + Grafana — observabilidad del cluster | ArgoCD (GitOps) |
| **Ansible** | Automatización de aprovisionamiento de la máquina host | Manual |

### Patrón App-of-Apps

ArgoCD usa el patrón App-of-Apps:

1. `bootstrap.sh` aplica `gitops/apps/root-app.yaml` — la Application raíz.
2. La root-app apunta a `gitops/apps/templates/`.
3. Cada `.yaml` en `templates/` es una Application de ArgoCD para un componente.
4. ArgoCD descubre y sincroniza todas las Applications automáticamente.

### Patrón Kustomize base/overlays

Cada componente de plataforma sigue el patrón:

```
componente/
├── base/             ← manifiestos comunes, sin diferencias entre ambientes
└── overlays/
    └── dev/          ← patches específicos para Kind dev (ambiente actual)
```

Escalar a nuevos ambientes (staging, prod) = agregar una carpeta en `overlays/`.

---

## Estructura del repositorio

```
idp-local/
├── bootstrap/
│   ├── kind-config.yaml     # Configuración del cluster Kind
│   └── bootstrap.sh         # Script de arranque: Kind + ArgoCD
├── gitops/
│   ├── argocd/
│   │   └── values.yaml      # Values para el Helm chart de ArgoCD
│   ├── apps/
│   │   ├── root-app.yaml    # App-of-Apps raíz
│   │   └── templates/       # Applications individuales (una por componente)
│   └── platform/
│       ├── backstage/       # Manifiestos Kustomize de Backstage
│       │   ├── base/
│       │   └── overlays/dev/
│       └── monitoring/      # Manifiestos Kustomize de Prometheus + Grafana
│           ├── base/
│           └── overlays/dev/
├── ansible/
│   ├── playbooks/           # Playbooks de aprovisionamiento del host
│   └── inventory/           # Inventario de Ansible
├── docs/                    # Documentación adicional
├── .gitignore
└── README.md
```

---

## Prerrequisitos

Herramientas necesarias en la máquina local:

- [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) >= 0.20
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/) >= 1.28
- [`helm`](https://helm.sh/docs/intro/install/) >= 3.12
- [`kustomize`](https://kubectl.docs.kubernetes.io/installation/kustomize/) >= 5.0
- Docker (o compatible: Podman con socket Docker)

---

## Quick Start

```bash
# 1. Clonar el repositorio
git clone https://github.com/NicoMiretti/idp-local.git
cd idp-local

# 2. Dar permisos de ejecución al script
chmod +x bootstrap/bootstrap.sh

# 3. Ejecutar el bootstrap
./bootstrap/bootstrap.sh

# 4. Acceder a la UI de ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443
# → https://localhost:8080
# Usuario: admin
# Password: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
```

---

## Decisiones técnicas

- **Helm solo para ArgoCD**: ArgoCD es infraestructura de bootstrapping,
  instalada una vez por el script. No tiene sentido que ArgoCD se gestione
  a sí mismo via GitOps en este setup.
- **Kustomize para todo lo demás**: consistencia en los manifiestos de
  plataforma, sin depender de Tiller ni de releases de Helm en el cluster.
  Los Helm charts de terceros (Prometheus, etc.) se consumen via el campo
  `helmCharts` de Kustomize.
- **Single-node**: entorno de tesis en máquina local, sin necesidad de
  alta disponibilidad ni workers separados.
- **`syncPolicy: automated`**: ArgoCD sincroniza automáticamente cualquier
  cambio pusheado al repo, eliminando pasos manuales.

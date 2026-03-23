# IDP Local — Documentación Técnica Completa

> Guía de referencia para entender la arquitectura, los conceptos involucrados y cada componente del proyecto, a bajo nivel.

---

## Tabla de contenidos

1. [Visión general](#1-visión-general)
2. [Conceptos fundamentales](#2-conceptos-fundamentales)
   - 2.1 [Kubernetes](#21-kubernetes)
   - 2.2 [Kind](#22-kind)
   - 2.3 [Kustomize](#23-kustomize)
   - 2.4 [Helm](#24-helm)
   - 2.5 [GitOps](#25-gitops)
   - 2.6 [ArgoCD](#26-argocd)
   - 2.7 [Ingress y ingress-nginx](#27-ingress-y-ingress-nginx)
   - 2.8 [Backstage](#28-backstage)
   - 2.9 [Container registry local](#29-container-registry-local)
3. [Arquitectura del proyecto](#3-arquitectura-del-proyecto)
4. [Bootstrap: cómo arranca todo](#4-bootstrap-cómo-arranca-todo)
   - 4.1 [kind-config.yaml](#41-kind-configyaml)
   - 4.2 [bootstrap.sh paso a paso](#42-bootstrapsh-paso-a-paso)
5. [Patrón App-of-Apps en ArgoCD](#5-patrón-app-of-apps-en-argocd)
6. [Patrón base/overlays con Kustomize](#6-patrón-baseoverlays-con-kustomize)
7. [Componentes de plataforma](#7-componentes-de-plataforma)
   - 7.1 [ingress-nginx](#71-ingress-nginx)
   - 7.2 [Ingresses](#72-ingresses)
   - 7.3 [Headlamp](#73-headlamp)
   - 7.4 [Backstage](#74-backstage)
8. [Catálogo de Backstage](#8-catálogo-de-backstage)
9. [Scaffolder: los dos templates](#9-scaffolder-los-dos-templates)
   - 9.1 [nuevo-proyecto-idp](#91-nuevo-proyecto-idp)
   - 9.2 [nueva-app-idp](#92-nueva-app-idp)
   - 9.3 [Skeletons: qué son y cómo funcionan](#93-skeletons-qué-son-y-cómo-funcionan)
10. [Proyectos de usuario: estructura en el cluster](#10-proyectos-de-usuario-estructura-en-el-cluster)
    - 10.1 [ArgoCD Applications por proyecto](#101-argocd-applications-por-proyecto)
    - 10.2 [Manifiestos Kubernetes de un proyecto](#102-manifiestos-kubernetes-de-un-proyecto)
    - 10.3 [Secreto compartido por proyecto](#103-secreto-compartido-por-proyecto)
11. [Registry local: cómo funciona la imagen](#11-registry-local-cómo-funciona-la-imagen)
12. [Flujo completo de extremo a extremo](#12-flujo-completo-de-extremo-a-extremo)
13. [Repositorios involucrados](#13-repositorios-involucrados)
14. [Acceso a los servicios](#14-acceso-a-los-servicios)
15. [Estructura completa del repositorio](#15-estructura-completa-del-repositorio)

---

## 1. Visión general

Este proyecto es un **Internal Developer Platform (IDP)** que corre completamente en una máquina local. El objetivo es que un desarrollador pueda ir a una UI web (Backstage), completar un formulario, y automáticamente:

1. Se cree la infraestructura Kubernetes (namespace, secrets, Application de ArgoCD) vía un Pull Request a GitHub.
2. Se cree el código fuente inicial de la app (Dockerfile + app de ejemplo) vía otro Pull Request a GitHub.
3. Al hacer merge de los PRs, ArgoCD detecta los cambios y despliega todo en el cluster automáticamente.
4. El desarrollador construye la imagen Docker y la pushea al registry local.
5. La app queda corriendo en el cluster y accesible por nombre de dominio.

Todo esto sin escribir un solo YAML a mano y sin ejecutar ningún `kubectl apply` manual.

---

## 2. Conceptos fundamentales

### 2.1 Kubernetes

Kubernetes (K8s) es un sistema de orquestación de contenedores. Su trabajo es:
- Correr contenedores Docker en uno o más nodos (máquinas).
- Reiniciarlos si se caen.
- Enrutar tráfico de red hacia ellos.
- Gestionar configuración y secretos.

**Recursos clave que usa este proyecto:**

| Recurso | Qué hace |
|---|---|
| `Namespace` | Espacio aislado dentro del cluster. Cada proyecto tiene el suyo. |
| `Deployment` | Declara cuántas réplicas de un Pod correr y con qué imagen. |
| `Pod` | La unidad mínima: uno o más contenedores corriendo juntos. |
| `Service` | Expone un conjunto de Pods bajo una IP estable y un nombre DNS interno. |
| `Ingress` | Regla de enrutamiento HTTP: "el tráfico a `mi-app.local` va al Service `mi-app`". |
| `ConfigMap` | Variables de entorno no sensibles para los Pods. |
| `Secret` | Variables de entorno sensibles (contraseñas, tokens). Codificadas en base64 en etcd. |

**Cómo se declaran:** todo en Kubernetes se define como archivos YAML con la estructura:

```yaml
apiVersion: apps/v1        # versión de la API del recurso
kind: Deployment           # tipo de recurso
metadata:
  name: mi-app             # nombre del recurso
  namespace: mi-proyecto   # en qué namespace vive
spec:
  ...                      # la especificación real del recurso
```

Kubernetes es **declarativo**: le decís "quiero este estado", y K8s hace lo necesario para llegar ahí. No le das pasos ("primero creá el pod, luego exponelo"), le das el estado deseado y él converge.

---

### 2.2 Kind

**Kind** = Kubernetes IN Docker. Es una herramienta que crea un cluster Kubernetes real donde cada nodo es un **contenedor Docker** en tu máquina.

```
Tu máquina (WSL/Linux)
└── Docker
    └── contenedor: idp-local-control-plane   ← esto ES el nodo Kubernetes
        └── Kubernetes (kubelet, etcd, API server, containerd)
            └── Pods corriendo adentro
```

Esto significa que:
- El cluster Kubernetes vive dentro de un contenedor Docker.
- Los Pods del cluster corren dentro de ese contenedor (Docker-in-Docker).
- Para que los puertos del cluster sean accesibles desde tu máquina, Kind hace **port mapping**: `containerPort: 80 → hostPort: 80`.

**Por qué Kind y no minikube u otro:**
- Muy liviano, arranca en segundos.
- Ideal para CI y entornos reproducibles.
- Permite configurar el cluster con un YAML (`kind-config.yaml`).

**Containerd:** Kind usa `containerd` (no Docker) como runtime de contenedores dentro del nodo. Containerd es el demonio que realmente descarga y corre las imágenes dentro del cluster. Esto es importante para el registry local: cuando un Pod hace `image: registry.local:5000/...`, es **containerd** (no Docker) quien descarga esa imagen.

---

### 2.3 Kustomize

Kustomize es una herramienta para gestionar manifiestos YAML de Kubernetes sin templates (a diferencia de Helm). Su idea central es la **superposición (overlay)**: tenés una base de manifiestos y le aplicás parches encima para cada ambiente.

**Archivo central: `kustomization.yaml`**

Todo directorio gestionado por Kustomize tiene un `kustomization.yaml` que declara qué archivos incluye:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

Cuando ejecutás `kubectl apply -k .` o ArgoCD sincroniza, Kustomize:
1. Lee el `kustomization.yaml`.
2. Reúne todos los archivos listados en `resources`.
3. Aplica los `patches` si los hay.
4. Produce un único stream de YAML y lo aplica al cluster.

**Campo `helmCharts`:** una extensión de Kustomize que permite incluir un Helm chart como si fuera un recurso más. Kustomize renderiza el chart con los valores dados y lo mezcla con el resto de los recursos. Esto es lo que se usa para instalar ingress-nginx, Headlamp y Backstage sin necesitar `helm install` manual.

---

### 2.4 Helm

Helm es el gestor de paquetes de Kubernetes. Un **chart** de Helm es un paquete de templates YAML con variables. Al instalarlo, le pasás `values.yaml` con los valores y Helm renderiza los templates.

En este proyecto Helm se usa de dos maneras:
1. **Directo:** para instalar ArgoCD en el bootstrap (`helm upgrade --install argocd ...`). ArgoCD se instala antes que haya GitOps, entonces hay que hacerlo manualmente.
2. **Via Kustomize:** para el resto de los charts (ingress-nginx, Headlamp, Backstage) usando el campo `helmCharts` en `kustomization.yaml`. Esto permite que ArgoCD los gestione con Kustomize.

---

### 2.5 GitOps

GitOps es un patrón operacional donde **Git es la única fuente de verdad** del estado del sistema. La idea:

- Todo el estado deseado del cluster (qué Deployments existen, cuántas réplicas, qué imagen usar, etc.) está declarado en archivos YAML en un repositorio Git.
- Un operador (en este caso ArgoCD) observa continuamente ese repositorio.
- Cualquier diferencia entre lo que está en Git y lo que está en el cluster es detectada y corregida automáticamente.
- Para cambiar algo en el cluster, **hacés un commit en Git**. No usás `kubectl` directamente.

**Ventajas:**
- Historial completo de cambios (git log = audit log).
- Rollback = `git revert`.
- Pull Requests como mecanismo de aprobación de cambios.
- Reproducibilidad: podés destruir y recrear el cluster desde cero con el mismo resultado.

---

### 2.6 ArgoCD

ArgoCD es el operador GitOps de este proyecto. Corre dentro del cluster y hace dos cosas:

1. **Observa** un repositorio Git (o un path dentro de él) con una frecuencia configurable.
2. **Sincroniza** el estado del cluster con lo que hay en Git: crea, actualiza o borra recursos Kubernetes según corresponda.

**Recurso central: `Application`**

El objeto principal de ArgoCD es una `Application`. Es un recurso de Kubernetes (CRD) que le dice a ArgoCD:
- Dónde está el Git (`repoURL`, `targetRevision`, `path`).
- En qué cluster/namespace desplegar (`destination`).
- Cómo sincronizar (`syncPolicy`).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mi-app
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/mi-org/mi-repo.git
    targetRevision: HEAD     # rama/tag/commit a observar
    path: gitops/mi-app/overlays/dev   # path dentro del repo
  destination:
    server: https://kubernetes.default.svc  # el cluster local
    namespace: mi-namespace
  syncPolicy:
    automated:
      selfHeal: true   # si alguien edita algo manual, ArgoCD lo revierte
      prune: true      # si se borra un archivo del repo, ArgoCD borra el recurso
```

**`selfHeal`:** si alguien hace `kubectl edit deployment mi-app` y cambia algo, ArgoCD lo detecta y lo revierte al estado del repo. El repo siempre gana.

**`prune`:** si borrás un archivo YAML del repo, ArgoCD borra el recurso correspondiente del cluster. Sin esto, los recursos "huérfanos" quedan para siempre.

**`finalizers: resources-finalizer.argocd.argoproj.io`:** cuando borrás una Application de ArgoCD, este finalizer garantiza que primero borre todos los recursos Kubernetes que esa Application gestionaba, y recién después borra la Application en sí. Sin esto, borrarías la Application pero los Deployments, Services, etc. quedarían en el cluster.

**`ServerSideApply`:** en lugar de que ArgoCD haga `kubectl apply` (client-side), usa Server-Side Apply, que es más robusto para gestión de campos y evita conflictos cuando múltiples actores modifican el mismo recurso.

**UI de ArgoCD:** disponible en `http://argocd.local`. Muestra todas las Applications, su estado de sync (Synced/OutOfSync), su estado de salud (Healthy/Degraded/Progressing), y el árbol de recursos que gestiona cada una.

---

### 2.7 Ingress y ingress-nginx

**Problema:** los Services de Kubernetes son internos al cluster. Para acceder a ellos desde afuera (tu browser) necesitás exponerlos.

**Ingress:** es un recurso de Kubernetes que define reglas de enrutamiento HTTP:
```
tráfico a backstage.local → Service backstage, puerto 7007
tráfico a argocd.local    → Service argocd-server, puerto 80
```

Pero un Ingress por sí solo no hace nada. Necesita un **Ingress Controller**: un proceso que lee esos recursos y configura un proxy (nginx, en este caso) para implementar las reglas.

**ingress-nginx:** es el Ingress Controller oficial basado en nginx. Corre como un Pod en el cluster y:
1. Observa los recursos `Ingress` del cluster.
2. Genera configuración de nginx.
3. Recarga nginx para aplicar los cambios.

**En Kind con `hostNetwork`:** el controller corre con `hostNetwork: true`, lo que significa que el Pod usa directamente la red del nodo (el contenedor de Kind). Esto, combinado con el port mapping de Kind (`hostPort: 80`), hace que el tráfico al puerto 80 de tu máquina llegue directamente al nginx del cluster.

```
Tu browser → localhost:80 → hostPort de Kind → nodo Kind (contenedor)
→ nginx (hostNetwork) → Service de la app → Pod de la app
```

---

### 2.8 Backstage

Backstage es un portal de desarrolladores open-source creado por Spotify. Tiene dos funcionalidades principales usadas en este proyecto:

**Catálogo de servicios:** un inventario de todos los componentes de software de la organización. Cada componente se describe con un `catalog-info.yaml` en su repositorio. Backstage los indexa y los muestra en una UI. Permite ver qué sistemas existen, qué componentes los forman, quién los mantiene, etc.

**Scaffolder:** un sistema de templates para crear nuevo software. Un template define un formulario para el usuario y una serie de pasos automatizados (acciones). Las acciones pueden renderizar archivos, crear Pull Requests en GitHub, registrar entidades en el catálogo, etc.

Backstage corre en el cluster como un Pod y es accesible en `http://backstage.local`.

---

### 2.9 Container registry local

Un **container registry** es un servidor que almacena imágenes Docker. Docker Hub es el registry público por defecto. En este proyecto se corre un registry privado local (`registry:2`, la implementación de referencia de Docker) para que las imágenes de las apps de usuario no necesiten salir a internet.

**El problema de acceso dual:**

| Quién | Cómo accede | Por qué |
|---|---|---|
| Docker en WSL (para push) | `127.0.0.1:5000` | `registry.local` requeriría editar `/etc/hosts` con sudo |
| containerd en el nodo Kind (para pull) | `registry.local:5000` | DNS interno del network Docker de Kind |

La imagen se pushea con `docker push 127.0.0.1:5000/...` pero se referencia en los manifiestos como `registry.local:5000/...`. Ambas apuntan al mismo contenedor porque `registry.local` está en el network Docker `kind` donde está el nodo Kind.

**Por qué containerd necesita configuración especial:** por defecto containerd asume que todos los registries usan HTTPS. Para un registry local HTTP hay que decirle explícitamente que use HTTP para ese host. Esto se hace con archivos `hosts.toml` en `/etc/containerd/certs.d/`.

---

## 3. Arquitectura del proyecto

```
┌─────────────────────────────────────────────────────────────────────┐
│  Tu máquina (WSL / Linux)                                           │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Docker                                                     │   │
│  │                                                             │   │
│  │  ┌──────────────────────┐   ┌───────────────────────────┐  │   │
│  │  │  registry.local:5000 │   │  idp-local-control-plane  │  │   │
│  │  │  (contenedor Docker) │   │  (nodo Kind = contenedor) │  │   │
│  │  │                      │   │                           │  │   │
│  │  │  registry:2          │   │  ┌───────────────────┐    │  │   │
│  │  │  (imágenes de apps)  │◄──┼──│  containerd       │    │  │   │
│  │  └──────────────────────┘   │  │  (runtime K8s)    │    │  │   │
│  │    ▲  network: kind         │  └───────────────────┘    │  │   │
│  │    │                        │                           │  │   │
│  │    │ docker push            │  ┌─────────────────────┐  │  │   │
│  │  127.0.0.1:5000             │  │  Kubernetes          │  │  │   │
│  │                             │  │                     │  │  │   │
│  │                             │  │  namespace: argocd  │  │  │   │
│  │                             │  │  ┌───────────────┐  │  │  │   │
│  │                             │  │  │  ArgoCD       │  │  │  │   │
│  │                             │  │  │  (operador    │  │  │  │   │
│  │                             │  │  │   GitOps)     │  │  │  │   │
│  │                             │  │  └───────┬───────┘  │  │  │   │
│  │                             │  │          │ observa  │  │  │   │
│  │                             │  │          ▼          │  │  │   │
│  │                             │  │  ┌───────────────┐  │  │  │   │
│  │                             │  │  │  root-app     │  │  │  │   │
│  │                             │  │  │  (Application)│  │  │  │   │
│  │                             │  │  └───────┬───────┘  │  │  │   │
│  │                             │  │          │ gestiona │  │  │   │
│  │                             │  │          ▼          │  │  │   │
│  │                             │  │  gitops/apps/       │  │  │   │
│  │                             │  │  templates/         │  │  │   │
│  │                             │  │  ├─ backstage-app   │  │  │   │
│  │                             │  │  ├─ headlamp-app    │  │  │   │
│  │                             │  │  ├─ ingress-nginx   │  │  │   │
│  │                             │  │  ├─ ingresses       │  │  │   │
│  │                             │  │  ├─ test-proyecto   │  │  │   │
│  │                             │  │  └─ ...             │  │  │   │
│  │                             │  │                     │  │  │   │
│  │                             │  │  namespace: backstage│ │  │   │
│  │                             │  │  ┌───────────────┐  │  │  │   │
│  │                             │  │  │  Backstage    │  │  │  │   │
│  │                             │  │  │  Scaffolder   │  │  │  │   │
│  │                             │  │  └───────────────┘  │  │  │   │
│  │                             │  │                     │  │  │   │
│  │                             │  │  namespace: test-proyecto│ │  │
│  │                             │  │  ┌───────────────┐  │  │  │   │
│  │                             │  │  │  mi-primera-  │  │  │  │   │
│  │                             │  │  │  app (Pod)    │  │  │  │   │
│  │                             │  │  └───────────────┘  │  │  │   │
│  │                             │  └─────────────────────┘  │  │   │
│  │                             └───────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  GitHub                                                             │
│  ├─ NicoMiretti/idp-local   ← fuente de verdad GitOps              │
│  └─ NicoMiretti/idp-apps    ← código fuente de las apps de usuario │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. Bootstrap: cómo arranca todo

### 4.1 kind-config.yaml

```yaml
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
name: idp-local

nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
      - containerPort: 443
        hostPort: 443

containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
```

**`extraPortMappings`:** le dice a Kind que mapee el puerto 80 del contenedor-nodo al puerto 80 de tu máquina. Esto es lo que hace que `http://backstage.local` (que va a tu localhost:80) llegue al nginx del cluster.

**`containerdConfigPatches`:** inyecta configuración en el `/etc/containerd/config.toml` del nodo al momento de creación. Le dice a containerd que busque configuración de registry en `/etc/containerd/certs.d/`. Sin esta línea, los archivos `hosts.toml` que configura el bootstrap son ignorados. Al estar en el `kind-config.yaml`, esta configuración es permanente: sobrevive reinicios del nodo.

**Nodo único `control-plane`:** en un cluster real hay nodos `control-plane` (que corren la API de Kubernetes) y nodos `worker` (que corren los Pods de usuario). En este setup de tesis, el único nodo es el control-plane y también corre todos los Pods de usuario. Esto simplifica el setup pero no es apto para producción.

---

### 4.2 bootstrap.sh paso a paso

El script `bootstrap/bootstrap.sh` es el punto de entrada. Se ejecuta una sola vez para levantar el cluster desde cero. Después, ArgoCD toma el control.

**Paso 1: `check_deps`**
Verifica que `kind`, `kubectl` y `helm` estén instalados.

**Paso 2: `setup_registry`**
```bash
docker run -d --name registry.local --restart=always \
  -p "127.0.0.1:5000:5000" registry:2
```
Crea un contenedor Docker corriendo `registry:2` (la implementación de referencia del protocolo de Docker Registry v2). Lo expone en `127.0.0.1:5000` del host. Si ya existe, lo reutiliza (idempotente).

Luego intenta conectar el contenedor al network Docker `kind`. Si el network no existe aún (porque el cluster no fue creado todavía), se omite y se conecta después.

**Paso 3: `create_cluster`**
```bash
kind create cluster --config bootstrap/kind-config.yaml
```
Crea el cluster Kind. Esto:
1. Descarga la imagen del nodo Kind si no está en caché.
2. Arranca el contenedor `idp-local-control-plane`.
3. Inicializa Kubernetes adentro (kubeadm).
4. Configura el `kubeconfig` local para que `kubectl` apunte a este cluster.

El flag `--config` aplica el `kind-config.yaml` (port mappings, containerdConfigPatches).

**Paso 4: conectar registry al network `kind`**
Después de que Kind crea el cluster, también crea el network Docker `kind`. El script conecta el contenedor del registry a ese network. A partir de este momento, el registry es accesible dentro del cluster como `registry.local` (Docker resuelve el nombre del contenedor como hostname dentro del network).

**Paso 5: `configure_node_registry`**
Aunque `containerdConfigPatches` ya configuró el `config_path`, todavía hay que:

1. **Agregar la IP al `/etc/hosts` del nodo:**
   ```bash
   echo "172.18.0.3 registry.local" >> /etc/hosts
   ```
   Docker resuelve los nombres de contenedores via DNS interno, pero solo para IPv6 en algunos casos. Agregar la entrada IPv4 explícita garantiza resolución correcta.

2. **Crear los archivos `hosts.toml`:**
   ```
   /etc/containerd/certs.d/registry.local:5000/hosts.toml
   /etc/containerd/certs.d/registry.local/hosts.toml
   ```
   Cada uno le dice a containerd que para ese registry use HTTP en lugar de HTTPS:
   ```toml
   server = "http://registry.local:5000"
   [host."http://registry.local:5000"]
     capabilities = ["pull", "resolve", "push"]
     skip_verify = true
   ```

3. **Reiniciar containerd** para que tome la nueva configuración.

4. **Aplicar el ConfigMap `local-registry-hosting`** en `kube-public` (estándar KEP-1755 de Kubernetes para anunciar registries locales a las herramientas del cluster).

> ⚠️ Los pasos 1-3 son **efímeros**: si el nodo Kind se reinicia, se pierden. El script está diseñado para ejecutarse de nuevo si eso ocurre. El paso de `kind-config.yaml` (`containerdConfigPatches`) persiste el `config_path` pero no los `hosts.toml` ni el `/etc/hosts`.

**Paso 6: `install_argocd`**
```bash
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 7.7.3 \
  --values gitops/argocd/values.yaml \
  --wait
```
Instala ArgoCD vía Helm. El flag `--wait` bloquea hasta que todos los Deployments de ArgoCD estén Ready. Se usa Helm aquí (y no GitOps) porque ArgoCD es la herramienta que después gestiona todo lo demás: no puede gestionarse a sí mismo en el bootstrap inicial.

El `values.yaml` configura:
- `server.extraArgs: [--insecure]`: ArgoCD sirve HTTP en lugar de HTTPS (el ingress maneja el TLS, o en local simplemente se usa HTTP).
- `kustomize.buildOptions: "--enable-helm"`: habilita el campo `helmCharts` dentro de los `kustomization.yaml` que gestiona ArgoCD.
- Health check personalizado para Ingress: en Kind el campo `.status.loadBalancer.ingress` nunca se llena, lo que hace que ArgoCD considere los Ingress como `Progressing` eternamente. Este override lo marca como `Healthy` apenas los backends existan.
- Recursos reducidos (cpu/memory requests bajos) para no saturar la máquina local.

**Paso 7: `wait_for_argocd`**
```bash
kubectl wait deployment/argocd-server --for=condition=available --timeout=180s
```

**Paso 8: `apply_root_app`**
```bash
kubectl apply -f gitops/apps/root-app.yaml
```
Este es el único `kubectl apply` del flujo normal. Aplica la Application raíz, que le dice a ArgoCD que observe `gitops/apps/templates/`. A partir de aquí, ArgoCD toma el control: detecta todos los archivos `.yaml` en ese directorio y los despliega automáticamente.

---

## 5. Patrón App-of-Apps en ArgoCD

Este es el patrón central de la arquitectura GitOps del proyecto.

**El problema:** queremos que ArgoCD gestione múltiples componentes (Backstage, ingress-nginx, Headlamp, etc.). Si aplicamos cada Application manualmente con `kubectl apply`, estamos fuera del GitOps: si alguien agrega un componente nuevo, tiene que acordarse de aplicarlo.

**La solución: App-of-Apps**

```
root-app (Application)
  └── apunta a: gitops/apps/templates/
      ├── backstage-app.yaml        → Application para Backstage
      ├── headlamp-app.yaml         → Application para Headlamp
      ├── ingress-nginx-app.yaml    → Application para ingress-nginx
      ├── ingresses-app.yaml        → Application para los Ingress
      ├── test-proyecto-app.yaml    → Application para el proyecto test-proyecto
      ├── test-proyecto-mi-primera-app-app.yaml → Application para mi-primera-app
      └── test-proyecto-segunda-app-app.yaml    → Application para segunda-app
```

La `root-app` es una Application que apunta a un directorio que contiene más Applications. ArgoCD las descubre y las crea. Cada Application hija apunta a los manifiestos reales de su componente.

**Agregar un componente nuevo** = crear un archivo `.yaml` en `gitops/apps/templates/` y pushearlo a Git. ArgoCD lo detecta en el próximo ciclo de sync (cada ~3 minutos por defecto) y lo despliega automáticamente. Sin comandos manuales.

---

## 6. Patrón base/overlays con Kustomize

Cada componente de plataforma sigue esta estructura:

```
componente/
├── base/
│   ├── kustomization.yaml   ← lista los recursos base
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ...
└── overlays/
    └── dev/
        └── kustomization.yaml   ← referencia base/ y agrega patches
```

**`base/`:** contiene los manifiestos "puros", sin configuración específica de ambiente. Son los valores por defecto que sirven para cualquier entorno.

**`overlays/dev/`:** contiene un `kustomization.yaml` mínimo que referencia `../../base` y opcionalmente agrega patches. En este proyecto todos los overlays son actualmente triviales (no tienen patches), pero la estructura está lista para agregar diferencias entre ambientes:

```yaml
# overlays/staging/kustomization.yaml (ejemplo hipotético)
resources:
  - ../../base
patches:
  - patch: |-
      - op: replace
        path: /spec/replicas
        value: 3      # en staging corremos 3 réplicas en vez de 1
    target:
      kind: Deployment
```

Las Applications de ArgoCD apuntan siempre al overlay, no al base:
```yaml
path: gitops/platform/backstage/overlays/dev
```

Esto significa que si mañana querés agregar un ambiente `staging`, creás `overlays/staging/`, una nueva Application de ArgoCD que apunte ahí, y el base no se toca.

---

## 7. Componentes de plataforma

### 7.1 ingress-nginx

**Path:** `gitops/platform/ingress-nginx/`  
**ArgoCD Application:** `gitops/apps/templates/ingress-nginx-app.yaml`  
**Namespace:** `ingress-nginx`

Instalado via `helmCharts` en el `kustomization.yaml` base. Configuración clave:

```yaml
controller:
  hostNetwork: true      # usa la red del nodo directamente
  hostPort:
    enabled: true
    ports:
      http: 80
      https: 443
  kind: DaemonSet        # un pod por nodo (hay 1 nodo, entonces 1 pod)
  tolerations:
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Exists"
      effect: "NoSchedule"
  service:
    type: ClusterIP      # no usamos LoadBalancer (no existe en Kind)
  allowSnippetAnnotations: true  # permite configuration-snippet en Ingress
```

**`hostNetwork: true`:** el Pod de nginx usa la red del contenedor-nodo de Kind directamente, no la red de pods de Kubernetes. Esto significa que nginx escucha en los puertos 80/443 del nodo, que a su vez están mapeados al host vía Kind.

**`tolerations`:** el nodo control-plane tiene un "taint" (mancha) que evita que Pods de usuario corran ahí. La toleración le dice a Kubernetes "este Pod puede correr en un nodo con ese taint".

**`DaemonSet`:** un DaemonSet asegura que corra exactamente un Pod por nodo. Como hay un solo nodo, hay un solo Pod de nginx.

---

### 7.2 Ingresses

**Path:** `gitops/platform/ingresses/`  
**ArgoCD Application:** `gitops/apps/templates/ingresses-app.yaml`  
**Namespace:** `argocd` (el Application apunta ahí, pero los Ingress individuales usan el namespace de su servicio)

Contiene los tres Ingress resources de los servicios de plataforma:

```
argocd-ingress.yaml    → argocd.local    → Service argocd-server:80
backstage-ingress.yaml → backstage.local → Service backstage:7007
headlamp-ingress.yaml  → headlamp.local  → Service headlamp:80
```

Están en un componente separado (y no dentro de cada componente) para poder modificar el enrutamiento sin tocar los manifiestos de los servicios.

**Anotaciones importantes:**

`argocd-ingress.yaml`:
```yaml
nginx.ingress.kubernetes.io/ssl-redirect: "false"
nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
```
ArgoCD corre con `--insecure`, entonces nginx no debe intentar hablarle por HTTPS.

`backstage-ingress.yaml`:
```yaml
nginx.ingress.kubernetes.io/configuration-snippet: |
  proxy_hide_header Strict-Transport-Security;
```
Backstage inyecta el header `Strict-Transport-Security` (HSTS) que le dice al browser "en el futuro, solo usá HTTPS para este dominio". En un entorno local HTTP esto rompe el acceso en la siguiente visita. El snippet lo elimina antes de enviarlo al browser.

---

### 7.3 Headlamp

**Path:** `gitops/platform/headlamp/`  
**ArgoCD Application:** `gitops/apps/templates/headlamp-app.yaml`  
**Namespace:** `headlamp`  
**URL:** `http://headlamp.local`

Headlamp es una UI web para visualizar recursos Kubernetes. Es una alternativa moderna al Kubernetes Dashboard oficial.

Instalado via `helmCharts`. Además del chart, incluye `admin-serviceaccount.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: headlamp
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-admin-user
roleRef:
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: admin-user
    namespace: headlamp
```

Esto crea un ServiceAccount con permisos de `cluster-admin` (acceso total al cluster). Para autenticarse en Headlamp se genera un token de este ServiceAccount:
```bash
kubectl create token admin-user -n headlamp --duration=8760h
```

---

### 7.4 Backstage

**Path:** `gitops/platform/backstage/`  
**ArgoCD Application:** `gitops/apps/templates/backstage-app.yaml`  
**Namespace:** `backstage`  
**URL:** `http://backstage.local`

Instalado via el chart oficial `backstage/backstage`. Configuración notable en el `values.yaml` inline:

**Base de datos:** `better-sqlite3` en memoria (`:memory:`). Esto significa que el catálogo se pierde si el Pod se reinicia. Para producción se usaría PostgreSQL. Aquí simplifica el setup enormemente.

**GitHub integration:**
```yaml
integrations:
  github:
    - host: github.com
      token: ${token}
```
El token se inyecta desde el Secret de Kubernetes `github-pat` (namespace `backstage`). Este secret fue creado manualmente con el PAT de GitHub y permite al Scaffolder hacer operaciones en GitHub (crear PRs, leer repositorios, etc.).

**Kubernetes plugin:**
```yaml
kubernetes:
  clusterLocatorMethods:
    - type: config
      clusters:
        - url: https://kubernetes.default.svc
          name: kind-idp-local
          authProvider: serviceAccount
          skipTLSVerify: true
          serviceAccountToken: ${KUBERNETES_SERVICE_ACCOUNT_TOKEN}
```
Permite a Backstage ver los recursos Kubernetes del cluster desde la UI. `kubernetes.default.svc` es el hostname interno del API server de Kubernetes (disponible desde cualquier Pod del cluster).

**RBAC para el Scaffolder** (`scaffolder-rbac.yaml`): el Pod de Backstage necesita permisos para interactuar con Kubernetes (crear namespaces, ver Applications de ArgoCD). Se define un `ClusterRole` con esos permisos y se lo asigna al ServiceAccount `backstage`.

---

## 8. Catálogo de Backstage

El catálogo es la base de datos de software de la organización. Se alimenta de archivos `catalog-info.yaml` en los repositorios.

**Tipos de entidades:**

| Kind | Qué representa |
|---|---|
| `System` | Un producto o proyecto completo (ej: `test-proyecto`) |
| `Component` | Una pieza de software dentro de un sistema (ej: `mi-primera-app`) |
| `Location` | Un puntero a otros `catalog-info.yaml` a indexar |
| `Template` | Un template del Scaffolder |

**Cómo Backstage encuentra las entidades:**

El archivo `catalog-info.yaml` en la raíz del repo `idp-local` es el punto de entrada:

```yaml
# catalog-info.yaml (raíz del repo)
apiVersion: backstage.io/v1alpha1
kind: Location
metadata:
  name: idp-templates
spec:
  targets:
    - ./gitops/platform/backstage/templates/nuevo-proyecto-idp.yaml
    - ./gitops/platform/backstage/templates/nueva-app-idp.yaml
```

Y en `gitops/argocd/values.yaml` se configura dónde está ese punto de entrada:
```yaml
catalog:
  locations:
    - type: url
      target: https://github.com/NicoMiretti/idp-local/blob/main/catalog-info.yaml
```

**Flujo de indexación:**
1. Backstage lee `catalog-info.yaml` de la raíz.
2. Encuentra la `Location` que apunta a los templates.
3. Lee los templates y los registra en el catálogo.
4. Cuando el Scaffolder crea una app y hace `catalog:register`, Backstage indexa el `catalog-info.yaml` de la nueva entidad.

**Relaciones entre entidades:**

```yaml
# catalog-info.yaml de una app
spec:
  type: service
  system: test-proyecto    # ← esta app pertenece al sistema test-proyecto
  owner: user:guest
```

Backstage usa esta relación para mostrar "qué componentes forman este sistema".

---

## 9. Scaffolder: los dos templates

### 9.1 nuevo-proyecto-idp

**Archivo:** `gitops/platform/backstage/templates/nuevo-proyecto-idp.yaml`

Crea un nuevo proyecto en el IDP. Parámetros: `projectName`, `description`.

**Pasos:**

1. **`fetch:template`** — renderiza el skeleton `./skeleton` con los valores del formulario. Genera:
   - `gitops/apps/templates/<projectName>-app.yaml` — la ArgoCD Application del proyecto
   - `gitops/platform/<projectName>/base/namespace.yaml` — el Namespace
   - `gitops/platform/<projectName>/base/secret.yaml` — el Secret compartido del proyecto
   - `gitops/platform/<projectName>/base/kustomization.yaml`
   - `gitops/platform/<projectName>/overlays/dev/kustomization.yaml`
   - `gitops/platform/<projectName>/catalog-info.yaml` — entidad `System` de Backstage

2. **`publish:github:pull-request`** — crea un PR en `idp-local` con los archivos generados.

3. **`catalog:register`** con `optional: true` — intenta registrar el `catalog-info.yaml` en Backstage. Si el PR no fue mergeado aún (el archivo no existe en `main`), lo omite silenciosamente. Después del merge + ~1 minuto de procesamiento, la entidad aparece sola.

**Lo que pasa después del merge:**
- ArgoCD detecta el nuevo archivo en `gitops/apps/templates/` en el próximo ciclo.
- Crea la Application del proyecto.
- La Application despliega el Namespace y el Secret.
- El proyecto aparece en ArgoCD UI y en el catálogo de Backstage.

---

### 9.2 nueva-app-idp

**Archivo:** `gitops/platform/backstage/templates/nueva-app-idp.yaml`

Crea una nueva aplicación dentro de un proyecto existente. Parámetros: `projectName`, `appName`, `description`, `language` (go/python/node), `port`.

**Pasos:**

1. **`fetch:template` (gitops)** — renderiza `./nueva-app-skeleton/gitops` en `./.idp-gitops`:
   - `gitops/apps/templates/<projectName>-<appName>-app.yaml` — ArgoCD Application de la app
   - `gitops/platform/<projectName>/base/apps/<appName>/deployment.yaml`
   - `gitops/platform/<projectName>/base/apps/<appName>/service.yaml`
   - `gitops/platform/<projectName>/base/apps/<appName>/ingress.yaml`
   - `gitops/platform/<projectName>/base/apps/<appName>/configmap.yaml`
   - `gitops/platform/<projectName>/base/apps/<appName>/kustomization.yaml`

2. **`fetch:template` (código)** — renderiza `./nueva-app-skeleton/idp-apps/<language>` en `./.idp-apps-code/<appName>`:
   - `Dockerfile`
   - Código fuente de ejemplo (`main.go`, `main.py`, o `index.js`)
   - `requirements.txt` / `go.mod` / `package.json`
   - `README.md`
   - `catalog-info.yaml` — entidad `Component` de Backstage

3. **`publish:github:pull-request` (gitops)** — PR en `idp-local` con el paso 1. Usa `sourcePath: ./.idp-gitops` para que solo ese subdirectorio vaya al PR.

4. **`publish:github:pull-request` (código)** — PR en `idp-apps` con el paso 2. Usa `sourcePath: ./.idp-apps-code`.

5. **`catalog:register`** — registra el `catalog-info.yaml` del repo `idp-apps`.

**Lo que pasa después del merge:**
- ArgoCD despliega la Application de la app → crea Deployment, Service, Ingress, ConfigMap en el namespace del proyecto.
- El developer hace `docker build` y `docker push 127.0.0.1:5000/<project>/<app>:latest`.
- El Deployment tiene `imagePullPolicy: Always` → el pod baja la imagen del registry local.
- La app queda accesible en `http://<appName>.<projectName>.local`.

---

### 9.3 Skeletons: qué son y cómo funcionan

Un **skeleton** es un directorio de archivos que actúan como templates. El Scaffolder los procesa con `fetch:template`, reemplazando las expresiones `${{ values.xxx }}` con los valores del formulario.

**Sintaxis de templates:** usa Nunjucks (similar a Jinja2):
```
${{ values.projectName }}   ← valor simple
${{ values.port | string }} ← con filtro
```

**Estructura del skeleton de nueva-app:**

```
nueva-app-skeleton/
├── gitops/                    ← archivos que van al PR en idp-local
│   └── gitops/                ← subcarpeta extra (ver nota abajo)
│       ├── apps/templates/
│       │   └── ${{ values.projectName }}-${{ values.appName }}-app.yaml
│       └── platform/${{ values.projectName }}/base/apps/${{ values.appName }}/
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── ingress.yaml
│           ├── configmap.yaml
│           └── kustomization.yaml
└── idp-apps/                  ← archivos que van al PR en idp-apps
    ├── go/
    ├── python/
    └── node/
```

> **Nota sobre el doble `gitops/`:** el paso `publish:github:pull-request` con `sourcePath: ./.idp-gitops` toma ese directorio como raíz del PR. El contenido de `.idp-gitops` se convierte en la raíz del repositorio en el PR. Como el skeleton renderiza en `.idp-gitops`, y dentro del skeleton hay `gitops/gitops/...`, el resultado en el repo es `gitops/apps/templates/...` — que es donde tienen que estar los archivos. El doble `gitops/` es intencional.

**Nombres de directorios con expresiones template:** Kustomize soporta nombres de directorio con `${{ }}`. Por ejemplo, el directorio `${{ values.projectName }}/` se convierte en `test-proyecto/` al renderizar. Esto permite que la estructura de archivos generada ya tenga los nombres correctos.

---

## 10. Proyectos de usuario: estructura en el cluster

### 10.1 ArgoCD Applications por proyecto

Para cada proyecto `<P>` y app `<A>` existen estas Applications en ArgoCD:

| Application | Gestiona | Path en Git |
|---|---|---|
| `<P>` | Namespace + Secret del proyecto | `gitops/platform/<P>/overlays/dev` |
| `<P>-<A>` | Deployment + Service + Ingress + ConfigMap de la app | `gitops/platform/<P>/base/apps/<A>` |

La separación entre la Application del proyecto y las Applications de cada app es intencional:
- El Namespace y el Secret son responsabilidad del proyecto, no de las apps individuales.
- Si la app se elimina, el Namespace y Secret del proyecto no se tocan.
- Evita el `SharedResourceWarning` de ArgoCD (dos Applications reclamando el mismo recurso).

**Label para filtrar en ArgoCD UI:**
```yaml
labels:
  app.kubernetes.io/part-of: test-proyecto
```
Las Applications de apps llevan este label. En la UI de ArgoCD, filtrando por `app.kubernetes.io/part-of=test-proyecto` se ven todas las apps del proyecto.

---

### 10.2 Manifiestos Kubernetes de un proyecto

Estructura real para `test-proyecto`:

```
gitops/platform/test-proyecto/
├── base/
│   ├── kustomization.yaml        ← incluye namespace.yaml y secret.yaml
│   ├── namespace.yaml
│   ├── secret.yaml               ← Secret compartido por todas las apps
│   └── apps/
│       ├── mi-primera-app/
│       │   ├── kustomization.yaml
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   ├── ingress.yaml
│       │   └── configmap.yaml
│       └── segunda-app/
│           └── ...
└── overlays/
    └── dev/
        └── kustomization.yaml    ← solo referencia ../../base
```

**`deployment.yaml` — puntos clave:**
```yaml
spec:
  template:
    spec:
      containers:
        - image: registry.local:5000/test-proyecto/mi-primera-app:latest
          imagePullPolicy: Always
          envFrom:
            - configMapRef:
                name: mi-primera-app-config    # variables no sensibles
            - secretRef:
                name: test-proyecto-secret     # variables sensibles
          readinessProbe:
            httpGet:
              path: /
              port: http
          livenessProbe:
            httpGet:
              path: /
              port: http
```

- **`imagePullPolicy: Always`:** cada vez que el Pod arranca, descarga la imagen del registry. Esto garantiza que si pusheás una nueva versión con el mismo tag `latest`, la próxima vez que el Pod reinicie tendrá la nueva imagen.
- **`envFrom`:** inyecta todas las keys del ConfigMap y el Secret como variables de entorno en el contenedor.
- **`readinessProbe`:** Kubernetes no envía tráfico al Pod hasta que esta probe responda exitosamente. Evita que el tráfico llegue a un Pod que todavía está iniciando.
- **`livenessProbe`:** si esta probe falla repetidamente, Kubernetes reinicia el Pod. Detecta cuando la app está colgada.

**`service.yaml`:**
```yaml
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: mi-primera-app
  ports:
    - port: 80
      targetPort: http
```
`ClusterIP` es el tipo por defecto: solo accesible dentro del cluster, con un IP interno estable. El tráfico externo llega via el Ingress → nginx → Service → Pod.

**`ingress.yaml`:**
```yaml
spec:
  ingressClassName: nginx
  rules:
    - host: mi-primera-app.test-proyecto.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: mi-primera-app
                port:
                  name: http
```
El hostname sigue el patrón `<app>.<proyecto>.local`. Para acceder desde el browser hay que agregar esta entrada al `/etc/hosts` del host.

---

### 10.3 Secreto compartido por proyecto

Cada proyecto tiene un único Secret `<projectName>-secret` gestionado por la Application del **proyecto** (no de cada app). Todas las apps del proyecto lo montan via `secretRef`.

```yaml
# secret.yaml (a nivel proyecto, no a nivel app)
apiVersion: v1
kind: Secret
metadata:
  name: test-proyecto-secret
  namespace: test-proyecto
type: Opaque
stringData:
  PLACEHOLDER: "replace-me"
  # DATABASE_URL: "postgresql://..."
  # API_KEY: "..."
```

**Por qué a nivel proyecto y no por app:** si dos apps tienen el mismo Secret en sus kustomizations, ArgoCD emite un `SharedResourceWarning` porque dos Applications están reclamando el mismo recurso. Al ponerlo en la Application del proyecto, hay un solo dueño claro.

**`stringData` vs `data`:** `stringData` acepta valores en texto plano. Kubernetes los codifica en base64 internamente al guardarlos en etcd. Al leerlos con `kubectl get secret`, verás los valores en base64.

> ⚠️ **Importante:** este Secret en Git es un placeholder con valores de ejemplo. En producción, los valores reales nunca van al repositorio. Se usaría Sealed Secrets (cifrado asimétrico), Vault (gestión centralizada de secretos) u otro mecanismo.

---

## 11. Registry local: cómo funciona la imagen

El ciclo de vida completo de una imagen de app:

```
1. Developer hace cambios en el código (en idp-apps)
2. docker build -t 127.0.0.1:5000/test-proyecto/mi-primera-app:latest .
3. docker push 127.0.0.1:5000/test-proyecto/mi-primera-app:latest
   └── La imagen llega al contenedor registry.local
4. kubectl rollout restart deployment -n test-proyecto mi-primera-app
   (o esperar a que el Pod reinicie por otro motivo)
5. El Pod nuevo arranca
6. containerd (dentro del nodo Kind) resuelve registry.local → 172.18.0.x
7. containerd hace HTTP GET a registry.local:5000/v2/test-proyecto/mi-primera-app/manifests/latest
8. Descarga las capas de la imagen
9. El Pod corre con la nueva imagen
```

**Por qué `127.0.0.1:5000` para push y `registry.local:5000` para pull:**

- `docker push 127.0.0.1:5000/...`: Docker corre en WSL, donde `127.0.0.1` es `localhost`. El puerto 5000 está mapeado al contenedor del registry. Push funciona.
- `docker push registry.local:5000/...`: requeriría que `registry.local` esté en `/etc/hosts` de WSL, lo cual requiere sudo. Se evita usando la IP directa.
- `image: registry.local:5000/...` en el manifiesto: containerd corre dentro del nodo Kind (un contenedor Docker), que está en el network Docker `kind`. En ese network, `registry.local` resuelve via el `/etc/hosts` del nodo (que el bootstrap configura con la IP del contenedor del registry en ese network).

**Verificar el registry:**
```bash
curl http://127.0.0.1:5000/v2/_catalog
# {"repositories":["test-proyecto/mi-primera-app","test-proyecto/segunda-app"]}

curl http://127.0.0.1:5000/v2/test-proyecto/mi-primera-app/tags/list
# {"name":"test-proyecto/mi-primera-app","tags":["latest"]}
```

**Verificar pull desde el nodo Kind:**
```bash
docker exec idp-local-control-plane \
  crictl pull registry.local:5000/test-proyecto/mi-primera-app:latest
```

---

## 12. Flujo completo de extremo a extremo

Este es el flujo que se sigue al crear un proyecto y una app nuevos:

```
1. Developer abre http://backstage.local
2. Scaffolder → "Nuevo Proyecto IDP"
   - Completa: projectName=mi-proyecto, description=...
   - Backstage renderiza los archivos del skeleton
   - Backstage crea PR en idp-local:
       gitops/apps/templates/mi-proyecto-app.yaml
       gitops/platform/mi-proyecto/base/namespace.yaml
       gitops/platform/mi-proyecto/base/secret.yaml
       gitops/platform/mi-proyecto/base/kustomization.yaml
       gitops/platform/mi-proyecto/overlays/dev/kustomization.yaml
       gitops/platform/mi-proyecto/catalog-info.yaml

3. Developer hace merge del PR

4. ArgoCD detecta nuevo archivo en gitops/apps/templates/ (próximo ciclo ~3min)
   - Crea Application "mi-proyecto"
   - mi-proyecto Application sincroniza:
       → crea Namespace "mi-proyecto" en el cluster
       → crea Secret "mi-proyecto-secret"

5. Developer abre Backstage → "Nueva Aplicación en Proyecto IDP"
   - Completa: projectName=mi-proyecto, appName=mi-api, language=go, port=8080
   - Backstage crea PR en idp-local:
       gitops/apps/templates/mi-proyecto-mi-api-app.yaml
       gitops/platform/mi-proyecto/base/apps/mi-api/deployment.yaml
       gitops/platform/mi-proyecto/base/apps/mi-api/service.yaml
       gitops/platform/mi-proyecto/base/apps/mi-api/ingress.yaml
       gitops/platform/mi-proyecto/base/apps/mi-api/configmap.yaml
       gitops/platform/mi-proyecto/base/apps/mi-api/kustomization.yaml
   - Backstage crea PR en idp-apps:
       mi-api/Dockerfile
       mi-api/main.go
       mi-api/go.mod
       mi-api/catalog-info.yaml
       mi-api/README.md

6. Developer hace merge de ambos PRs

7. ArgoCD detecta nuevo archivo en gitops/apps/templates/ 
   - Crea Application "mi-proyecto-mi-api"
   - mi-api Application sincroniza:
       → crea Deployment (imagen: registry.local:5000/mi-proyecto/mi-api:latest)
       → crea Service
       → crea Ingress
       → crea ConfigMap
   - Pod queda en ImagePullBackOff (la imagen no existe todavía)

8. Developer clona idp-apps, construye y pushea la imagen:
   git clone https://github.com/NicoMiretti/idp-apps.git
   cd idp-apps/mi-api
   docker build -t 127.0.0.1:5000/mi-proyecto/mi-api:latest .
   docker push 127.0.0.1:5000/mi-proyecto/mi-api:latest

9. kubectl rollout restart deployment -n mi-proyecto mi-api
   (o esperar al siguiente reinicio del Pod)

10. Pod arranca, descarga imagen de registry.local:5000, queda Running

11. Developer agrega "127.0.0.1 mi-api.mi-proyecto.local" a /etc/hosts
    Accede a http://mi-api.mi-proyecto.local → "Hello from mi-api!"

12. En Backstage catálogo:
    - System "mi-proyecto" (del catalog-info.yaml en idp-local)
    - Component "mi-api" con system=mi-proyecto (del catalog-info.yaml en idp-apps)
```

---

## 13. Repositorios involucrados

### `idp-local` (este repo)

**Propósito:** fuente de verdad GitOps. Todo lo que está aquí define el estado del cluster.

**Quién escribe aquí:**
- El bootstrap script (una vez, manualmente).
- El Scaffolder de Backstage (vía PRs automáticos).
- El equipo de plataforma (modificaciones manuales).

### `idp-apps`

**Propósito:** código fuente de las aplicaciones de usuario.

**Quién escribe aquí:**
- El Scaffolder de Backstage (código inicial vía PR automático).
- Los developers (cambios en el código de sus apps).

**Estructura:**
```
idp-apps/
├── README.md
├── mi-primera-app/
│   ├── Dockerfile
│   ├── main.go (o main.py o index.js)
│   ├── catalog-info.yaml
│   └── README.md
└── segunda-app/
    └── ...
```

Cada app es un subdirectorio independiente. No hay ningún monorepo tooling especial: cada subdirectorio tiene su propio Dockerfile y se construye de forma independiente.

---

## 14. Acceso a los servicios

### `/etc/hosts` requerido

Agregar en la máquina host (Windows: `C:\Windows\System32\drivers\etc\hosts` con admin; Linux/WSL: `/etc/hosts` con sudo):

```
127.0.0.1  argocd.local
127.0.0.1  headlamp.local
127.0.0.1  backstage.local
```

Para cada app desplegada:
```
127.0.0.1  <appName>.<projectName>.local
```

### URLs y credenciales

| Servicio | URL | Cómo autenticarse |
|---|---|---|
| **ArgoCD** | http://argocd.local | usuario: `admin`, password: `kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" \| base64 -d` |
| **Headlamp** | http://headlamp.local | token: `kubectl create token admin-user -n headlamp --duration=8760h` |
| **Backstage** | http://backstage.local | sin auth (modo guest) |

---

## 15. Estructura completa del repositorio

```
idp-local/
│
├── .gitignore                    ← excluye secrets, kubeconfigs, node_modules, etc.
│                                    con excepciones explícitas para skeletons de templates
│
├── README.md                     ← documentación de inicio rápido
│
├── catalog-info.yaml             ← punto de entrada del catálogo de Backstage
│                                    define: System idp-local, Components (argocd, headlamp, backstage)
│                                    y Location que apunta a los templates del Scaffolder
│
├── bootstrap/
│   ├── kind-config.yaml          ← configuración del cluster Kind
│   │                                port mappings 80/443, containerdConfigPatches para registry
│   └── bootstrap.sh              ← script de arranque único
│                                    crea registry, cluster Kind, configura containerd,
│                                    instala ArgoCD (Helm), aplica root-app
│
├── gitops/
│   │
│   ├── argocd/
│   │   └── values.yaml           ← valores para el chart de ArgoCD
│   │                                modo insecure, enable-helm en kustomize,
│   │                                health check custom para Ingress, recursos reducidos
│   │
│   ├── apps/
│   │   ├── root-app.yaml         ← la App-of-Apps raíz
│   │   │                            apunta a gitops/apps/templates/
│   │   └── templates/            ← ArgoCD descubre y crea cada .yaml de este dir
│   │       ├── backstage-app.yaml
│   │       ├── headlamp-app.yaml
│   │       ├── ingress-nginx-app.yaml
│   │       ├── ingresses-app.yaml
│   │       ├── bup-policies-pro-app.yaml          ← ejemplo de proyecto de usuario
│   │       ├── test-proyecto-app.yaml             ← proyecto de prueba
│   │       ├── test-proyecto-mi-primera-app-app.yaml
│   │       └── test-proyecto-segunda-app-app.yaml
│   │
│   └── platform/
│       │
│       ├── backstage/
│       │   ├── base/
│       │   │   ├── kustomization.yaml   ← helmChart backstage/backstage + scaffolder-rbac
│       │   │   └── scaffolder-rbac.yaml ← ClusterRole/RoleBinding para el pod de Backstage
│       │   ├── overlays/dev/
│       │   │   └── kustomization.yaml   ← referencia a base/
│       │   └── templates/               ← templates del Scaffolder (no son Kubernetes YAML)
│       │       ├── nuevo-proyecto-idp.yaml     ← template: crear proyecto
│       │       ├── nueva-app-idp.yaml          ← template: crear app en proyecto
│       │       ├── skeleton/                   ← archivos para nuevo-proyecto-idp
│       │       │   └── gitops/
│       │       │       ├── apps/templates/<P>-app.yaml
│       │       │       └── platform/<P>/
│       │       │           ├── catalog-info.yaml
│       │       │           ├── base/kustomization.yaml
│       │       │           ├── base/namespace.yaml
│       │       │           ├── base/secret.yaml
│       │       │           └── overlays/dev/kustomization.yaml
│       │       └── nueva-app-skeleton/         ← archivos para nueva-app-idp
│       │           ├── gitops/gitops/          ← va al PR de idp-local
│       │           │   ├── apps/templates/<P>-<A>-app.yaml
│       │           │   └── platform/<P>/base/apps/<A>/
│       │           │       ├── deployment.yaml
│       │           │       ├── service.yaml
│       │           │       ├── ingress.yaml
│       │           │       ├── configmap.yaml
│       │           │       └── kustomization.yaml
│       │           └── idp-apps/               ← va al PR de idp-apps
│       │               ├── go/     (Dockerfile, main.go, go.mod, catalog-info.yaml, README.md)
│       │               ├── python/ (Dockerfile, main.py, requirements.txt, catalog-info.yaml)
│       │               └── node/   (Dockerfile, index.js, package.json, catalog-info.yaml)
│       │
│       ├── headlamp/
│       │   ├── base/
│       │   │   ├── kustomization.yaml        ← helmChart headlamp
│       │   │   └── admin-serviceaccount.yaml ← SA cluster-admin para autenticación
│       │   └── overlays/dev/kustomization.yaml
│       │
│       ├── ingress-nginx/
│       │   ├── base/
│       │   │   └── kustomization.yaml  ← helmChart ingress-nginx (hostNetwork, DaemonSet)
│       │   └── overlays/dev/kustomization.yaml
│       │
│       ├── ingresses/
│       │   ├── base/
│       │   │   ├── kustomization.yaml
│       │   │   ├── argocd-ingress.yaml    ← argocd.local
│       │   │   ├── backstage-ingress.yaml ← backstage.local
│       │   │   └── headlamp-ingress.yaml  ← headlamp.local
│       │   └── overlays/dev/kustomization.yaml
│       │
│       ├── test-proyecto/                 ← ejemplo real de proyecto de usuario
│       │   ├── base/
│       │   │   ├── kustomization.yaml     ← incluye namespace.yaml y secret.yaml
│       │   │   ├── namespace.yaml
│       │   │   ├── secret.yaml            ← Secret compartido del proyecto
│       │   │   └── apps/
│       │   │       ├── mi-primera-app/    ← deployment, service, ingress, configmap
│       │   │       └── segunda-app/
│       │   └── overlays/dev/kustomization.yaml
│       │
│       └── bup-policies-pro/              ← ejemplo de proyecto vacío (solo namespace)
│           ├── base/
│           │   ├── kustomization.yaml
│           │   └── namespace.yaml
│           └── overlays/dev/kustomization.yaml
│
└── ansible/                     ← placeholder para automatización del host
    ├── inventory/
    └── playbooks/
```

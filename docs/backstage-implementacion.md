# Backstage en este IDP — Referencia de implementación

> Documento técnico para comparar contra una implementación en OpenShift.
> Describe **exactamente cómo está implementado Backstage en este proyecto**, decisión por decisión.

---

## Tabla de contenidos

1. [Cómo se instala](#1-cómo-se-instala)
2. [Imagen que se usa](#2-imagen-que-se-usa)
3. [Base de datos](#3-base-de-datos)
4. [Configuración (app-config)](#4-configuración-app-config)
5. [Secretos y variables de entorno](#5-secretos-y-variables-de-entorno)
6. [Integración GitHub](#6-integración-github)
7. [Autenticación](#7-autenticación)
8. [Plugin Kubernetes](#8-plugin-kubernetes)
9. [RBAC dentro del cluster](#9-rbac-dentro-del-cluster)
10. [Ingress / acceso externo](#10-ingress--acceso-externo)
11. [Catálogo: cómo se alimenta](#11-catálogo-cómo-se-alimenta)
12. [Scaffolder: los dos templates](#12-scaffolder-los-dos-templates)
13. [Skeletons: cómo funcionan](#13-skeletons-cómo-funcionan)
14. [Diferencias esperadas en OpenShift](#14-diferencias-esperadas-en-openshift)

---

## 1. Cómo se instala

**Método:** Helm chart oficial, consumido desde Kustomize via el campo `helmCharts`.

**Chart:** `backstage/backstage` versión `2.6.3`
**Repo Helm:** `https://backstage.github.io/charts`

```yaml
# gitops/platform/backstage/base/kustomization.yaml
helmCharts:
  - name: backstage
    repo: https://backstage.github.io/charts
    version: "2.6.3"
    releaseName: backstage
    namespace: backstage
    valuesInline:
      ...
```

**No se usa `helm install` directo.** ArgoCD corre `kustomize build --enable-helm` y resuelve el helmChart internamente. El flag `--enable-helm` está seteado en el `values.yaml` de ArgoCD:

```yaml
# gitops/argocd/values.yaml
configs:
  cm:
    kustomize.buildOptions: "--enable-helm"
```

**ArgoCD Application** que gestiona Backstage:
- Archivo: `gitops/apps/templates/backstage-app.yaml`
- Path que sincroniza: `gitops/platform/backstage/overlays/dev`
- Namespace destino: `backstage`

---

## 2. Imagen que se usa

```yaml
backstage:
  image:
    registry: ghcr.io
    repository: backstage/backstage
    tag: latest
    pullPolicy: IfNotPresent
```

**Imagen:** `ghcr.io/backstage/backstage:latest`

Es la imagen demo oficial de Backstage. Incluye todos los plugins de la distribución estándar precompilados. No es una imagen custom construida localmente.

**Consecuencia directa:** no se puede agregar plugins custom sin construir una imagen propia. Para este IDP local con los plugins estándar (Scaffolder, Catálogo, Kubernetes) alcanza.

**Para OpenShift:** si se quieren plugins custom (Tekton, OpenShift Pipelines, etc.) hay que construir una imagen propia con `@backstage/create-app` y agregarle los plugins.

---

## 3. Base de datos

```yaml
backstage:
  appConfig:
    backend:
      database:
        client: better-sqlite3
        connection: ":memory:"

postgresql:
  enabled: false
```

**SQLite en memoria.** El catálogo se pierde cada vez que el Pod se reinicia.

**Por qué:** simplifica el setup local al máximo. No requiere un StatefulSet de Postgres, PVCs, credenciales, etc.

**Para OpenShift:** se necesita PostgreSQL. El chart soporta habilitarlo directamente:
```yaml
postgresql:
  enabled: true
  auth:
    password: "<secreto>"
```
O apuntar a una instancia externa via `connection` string.

---

## 4. Configuración (app-config)

Backstage arranca con **dos archivos de configuración en cascada**:

```yaml
backstage:
  args:
    - "--config"
    - "/app/app-config.yaml"           # config base de la imagen
    - "--config"
    - "/app/app-config-from-configmap.yaml"   # config nuestra (override)
```

El segundo archivo sobreescribe/extiende el primero. Backstage los mergea en orden.

**Por qué dos configs:** el chart por defecto pasa solo `--config /app/app-config-from-configmap.yaml`, saltándose el `app-config.yaml` interno de la imagen. Eso hace que se pierdan defaults importantes (como la URL base compilada). Con `args` explícito cargamos ambos.

**El `app-config-from-configmap.yaml`** es generado por el chart a partir del campo `appConfig` en `valuesInline`. El chart crea un ConfigMap con ese contenido y lo monta en `/app/`.

Valores que se configuran en `appConfig`:

```yaml
app:
  title: IDP Local
  baseUrl: http://backstage.local

backend:
  baseUrl: http://backstage.local
  listen:
    port: 7007
    host: "0.0.0.0"
  cors:
    origin: http://backstage.local
  database:
    client: better-sqlite3
    connection: ":memory:"
  csp:
    upgrade-insecure-requests: false   # evita que el browser fuerce HTTPS en local

auth:
  providers:
    guest:
      dangerouslyAllowOutsideDevelopment: true

integrations:
  github:
    - host: github.com
      token: ${token}           # ← se resuelve desde la variable de entorno

kubernetes:
  ...

catalog:
  ...

organization:
  name: IDP Local
```

**`upgrade-insecure-requests: false`:** sin esto, Backstage inyecta el header CSP que obliga al browser a pedir recursos por HTTPS. En HTTP local rompe la UI.

---

## 5. Secretos y variables de entorno

**Secret de GitHub PAT:**

```yaml
# Creado manualmente, nunca va a Git
# kubectl create secret generic github-pat \
#   --from-literal=token=ghp_... \
#   -n backstage
```

El chart lo inyecta como variables de entorno via:

```yaml
backstage:
  extraEnvVarsSecrets:
    - github-pat
```

Esto hace que todas las keys del Secret `github-pat` estén disponibles como env vars en el pod. La key `token` queda disponible como `$token`, que es lo que referencia `${token}` en el app-config.

**ServiceAccount token (Kubernetes plugin):**

```yaml
serviceAccountToken: ${KUBERNETES_SERVICE_ACCOUNT_TOKEN}
```

`KUBERNETES_SERVICE_ACCOUNT_TOKEN` es inyectado automáticamente por el chart desde el ServiceAccount del pod. No requiere configuración adicional.

---

## 6. Integración GitHub

```yaml
integrations:
  github:
    - host: github.com
      token: ${token}
```

**Qué permite:** el Scaffolder usa este token para:
- Crear branches en repos de GitHub
- Crear Pull Requests
- Leer archivos de repos (para skeletons remotos)

**PAT requerido:** el token necesita scopes `repo` (crear PRs) y `workflow` (opcional, para GitHub Actions si se usan).

**Para OpenShift:** si el OpenShift tiene acceso a internet, la configuración es idéntica. Si está en red privada con GitLab/Bitbucket interno, hay que cambiar `host` e instalar el plugin correspondiente (`@backstage/plugin-scaffolder-backend-module-gitlab`, etc.).

---

## 7. Autenticación

```yaml
auth:
  providers:
    guest:
      dangerouslyAllowOutsideDevelopment: true
```

**Sin autenticación real.** Cualquier persona que acceda a `http://backstage.local` entra como "Guest" con acceso total.

**Por qué:** entorno local de desarrollo, sin usuarios reales.

**Para OpenShift:** se necesita un proveedor de identidad real. Opciones habituales:
- OIDC con Red Hat SSO / Keycloak
- GitHub OAuth (`@backstage/plugin-auth-backend-module-github-provider`)
- LDAP/AD

El campo en app-config:
```yaml
auth:
  environment: production
  providers:
    github:
      production:
        clientId: ${AUTH_GITHUB_CLIENT_ID}
        clientSecret: ${AUTH_GITHUB_CLIENT_SECRET}
```

---

## 8. Plugin Kubernetes

```yaml
kubernetes:
  serviceLocatorMethod:
    type: multiTenant
  clusterLocatorMethods:
    - type: config
      clusters:
        - url: https://kubernetes.default.svc
          name: kind-idp-local
          authProvider: serviceAccount
          skipTLSVerify: true
          serviceAccountToken: ${KUBERNETES_SERVICE_ACCOUNT_TOKEN}
```

**`url: https://kubernetes.default.svc`:** apunta al API server de Kubernetes desde dentro del cluster. Funciona porque Backstage corre como Pod en el mismo cluster.

**`authProvider: serviceAccount`:** usa el ServiceAccount del Pod de Backstage para autenticarse contra la API de Kubernetes. El token se monta automáticamente en el Pod.

**`skipTLSVerify: true`:** el API server de Kind usa un certificado autofirmado. En Kind no hay forma fácil de trustar ese cert desde el pod.

**Para OpenShift:**
- `url` puede ser `https://kubernetes.default.svc` (igual, si Backstage corre en el mismo cluster) o la URL externa del API server.
- `skipTLSVerify: false` y configurar el CA cert del cluster, o usar `caData`.
- `authProvider: serviceAccount` funciona igual en OpenShift.
- Alternativa: usar `authProvider: oidc` o `authProvider: googleServiceAccount` si se tiene un setup más complejo.

---

## 9. RBAC dentro del cluster

El ServiceAccount `backstage` (creado por el chart) necesita permisos para que el Scaffolder pueda interactuar con el cluster.

**Archivo:** `gitops/platform/backstage/base/scaffolder-rbac.yaml`

### Permisos definidos

**ClusterRole `backstage-scaffolder`** + ClusterRoleBinding:
```yaml
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "create"]
```
Permite al Scaffolder crear Namespaces nuevos cuando se ejecuta el template "Nuevo Proyecto".

**Role `backstage-argocd`** (namespace `argocd`) + RoleBinding:
```yaml
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["applications"]
    verbs: ["get", "list", "create", "patch"]
```
Permite al Scaffolder crear/modificar ArgoCD Applications en el namespace `argocd`.

### Cómo se usa en los templates

Los templates del Scaffolder no usan estos permisos directamente vía RBAC en los steps — los steps `publish:github:pull-request` crean PRs en GitHub, no recursos Kubernetes directamente. El RBAC de Kubernetes es para el **plugin Kubernetes** (leer estado del cluster en la UI de Backstage).

**Para OpenShift:** en OpenShift el RBAC funciona igual pero hay objetos adicionales a considerar:
- `SecurityContextConstraints` (SCC): el Pod de Backstage puede requerir el SCC `restricted` o `nonroot`.
- Si se usa OpenShift RBAC adicional, hay que agregar los permisos correspondientes.

---

## 10. Ingress / acceso externo

**Ingress:**
```yaml
# gitops/platform/ingresses/base/backstage-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: backstage
  namespace: backstage
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_hide_header Strict-Transport-Security;
spec:
  ingressClassName: nginx
  rules:
    - host: backstage.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: backstage
                port:
                  name: http
```

**IngressClass:** `nginx` (ingress-nginx, instalado por separado).

**`proxy_hide_header Strict-Transport-Security`:** Backstage inyecta el header HSTS que fuerza al browser a usar HTTPS en futuros requests. En HTTP local eso rompe el acceso. El annotation lo elimina antes de enviarlo al browser.

**Service expuesto por el chart:**
```yaml
service:
  type: ClusterIP
  ports:
    backend: 7007
```
ClusterIP en puerto 7007. El Ingress rutea el tráfico externo (puerto 80) hacia ese Service.

**Para OpenShift:** en lugar de `Ingress`, OpenShift usa `Route`:
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: backstage
  namespace: backstage
spec:
  host: backstage.apps.cluster.example.com
  to:
    kind: Service
    name: backstage
  port:
    targetPort: http
  tls:
    termination: edge
```
O se puede usar Ingress con la IngressClass del ingress-nginx de OpenShift si está instalado. El chart de Backstage tiene soporte para Routes via `route.enabled: true`.

---

## 11. Catálogo: cómo se alimenta

### Punto de entrada

```yaml
# gitops/argocd/values.yaml → appConfig → catalog.locations
catalog:
  locations:
    - type: url
      target: https://github.com/NicoMiretti/idp-local/blob/main/catalog-info.yaml
      rules:
        - allow: [Component, System, Template, Location]
  processingInterval: { minutes: 1 }
```

Backstage arranca y lee ese URL. Ahí encuentra una entidad `Location` que apunta a los templates:

```yaml
# catalog-info.yaml (raíz del repo idp-local)
apiVersion: backstage.io/v1alpha1
kind: Location
metadata:
  name: idp-templates
spec:
  targets:
    - ./gitops/platform/backstage/templates/nuevo-proyecto-idp.yaml
    - ./gitops/platform/backstage/templates/nueva-app-idp.yaml
```

### Tipos de entidades en uso

| Kind | Qué representa | Dónde vive |
|---|---|---|
| `Location` | Puntero a otros catalog-info | Raíz del repo |
| `Template` | Template del Scaffolder | `gitops/platform/backstage/templates/` |
| `System` | Un proyecto completo | `gitops/platform/<project>/catalog-info.yaml` |
| `Component` | Una app dentro de un proyecto | Repo de código (`idp-apps/<app>/catalog-info.yaml`) |

### Regla de tipos permitidos

```yaml
catalog:
  rules:
    - allow: [Component, System, API, Group, User, Resource, Location, Template]
```

Sin esta regla, Backstage rechaza tipos que no estén en la whitelist. En dev se habilitan todos.

---

## 12. Scaffolder: los dos templates

### Template 1: `nuevo-proyecto-idp`

**Archivo:** `gitops/platform/backstage/templates/nuevo-proyecto-idp.yaml`

**Parámetros del formulario:**
- `projectName` — nombre del namespace / proyecto
- `description` — descripción libre

**Steps:**

| Step | Action | Qué hace |
|---|---|---|
| 1 | `fetch:template` | Renderiza el skeleton `./skeleton` con los valores del form |
| 2 | `publish:github:pull-request` | Crea PR en `NicoMiretti/idp-local` con los archivos generados |
| 3 | `catalog:register` (optional) | Registra el `catalog-info.yaml` del nuevo proyecto en Backstage |

**Archivos que genera el skeleton:**

```
gitops/apps/templates/<projectName>-app.yaml          ← ArgoCD Application
gitops/platform/<projectName>/base/namespace.yaml
gitops/platform/<projectName>/base/secret.yaml
gitops/platform/<projectName>/base/kustomization.yaml
gitops/platform/<projectName>/overlays/dev/kustomization.yaml
gitops/platform/<projectName>/catalog-info.yaml        ← entidad System
```

**Flujo post-merge del PR:**
1. ArgoCD detecta el nuevo archivo en `gitops/apps/templates/` (próximo ciclo de sync, ~3 min)
2. Crea la ArgoCD Application del proyecto
3. La Application despliega Namespace + Secret en el cluster
4. El catálogo de Backstage indexa el `catalog-info.yaml` nuevo (próxima corrida del procesador, ~1 min)

---

### Template 2: `nueva-app-idp`

**Archivo:** `gitops/platform/backstage/templates/nueva-app-idp.yaml`

**Parámetros del formulario:**
- `projectName` — proyecto destino (ya existente)
- `appName` — nombre de la app
- `description`
- `language` — `go` / `python` / `node`
- `port` — puerto que expone la app

**Steps:**

| Step | Action | Qué hace |
|---|---|---|
| 1 | `fetch:template` (gitops) | Renderiza skeleton de manifiestos en `./.idp-gitops` |
| 2 | `fetch:template` (código) | Renderiza skeleton de código en `./.idp-apps-code` |
| 3 | `publish:github:pull-request` | PR en `idp-local` con los manifiestos (sourcePath: `.idp-gitops`) |
| 4 | `publish:github:pull-request` | PR en `idp-apps` con el código (sourcePath: `.idp-apps-code`) |
| 5 | `catalog:register` | Registra el Component de la app en Backstage |

**Archivos que genera (gitops PR):**

```
gitops/apps/templates/<project>-<app>-app.yaml        ← ArgoCD Application de la app
gitops/platform/<project>/base/apps/<app>/
  ├── deployment.yaml
  ├── service.yaml
  ├── ingress.yaml
  ├── configmap.yaml
  └── kustomization.yaml
```

**Archivos que genera (código PR):**

```
<appName>/
  ├── Dockerfile
  ├── main.go / main.py / index.js
  ├── go.mod / requirements.txt / package.json
  ├── README.md
  └── catalog-info.yaml    ← entidad Component de Backstage
```

**Flujo post-merge:**
1. ArgoCD despliega Deployment + Service + Ingress + ConfigMap en el namespace
2. El developer hace `docker build` y `docker push 127.0.0.1:5000/<project>/<app>:latest`
3. El pod baja la imagen del registry local (`imagePullPolicy: Always`)
4. La app queda accesible en `http://<app>.<project>.local`

---

## 13. Skeletons: cómo funcionan

Un skeleton es un directorio de archivos con sintaxis **Nunjucks** (`${{ }}`).

### Sintaxis

```
${{ values.projectName }}        ← valor simple
${{ values.port | string }}      ← con filtro de tipo
${{ values.appName | upper }}    ← filtro Nunjucks
```

El Scaffolder reemplaza todas las expresiones con los valores del formulario antes de crear los archivos.

### Dónde están los skeletons

```
gitops/platform/backstage/templates/
├── nuevo-proyecto-idp.yaml       ← template
├── skeleton/                     ← skeleton de nuevo-proyecto-idp
│   ├── gitops/
│   │   ├── apps/templates/
│   │   │   └── ${{ values.projectName }}-app.yaml
│   │   └── platform/${{ values.projectName }}/
│   │       └── base/ ...
│   └── catalog-info.yaml
├── nueva-app-idp.yaml            ← template
└── nueva-app-skeleton/           ← skeleton de nueva-app-idp
    ├── gitops/
    │   └── gitops/               ← doble gitops (ver nota)
    │       └── ...
    └── idp-apps/
        ├── go/
        ├── python/
        └── node/
```

### El doble `gitops/` en nueva-app-skeleton

El step `publish:github:pull-request` con `sourcePath: ./.idp-gitops` usa ese directorio como **raíz del PR**. Es decir, el contenido de `.idp-gitops` se convierte en la raíz del repo en el PR.

El skeleton renderiza en `.idp-gitops`. Dentro del skeleton hay `gitops/gitops/apps/...`. Resultado en el repo: `gitops/apps/...` — que es el path correcto.

El doble `gitops/` es intencional: un nivel se convierte en la raíz, el otro es el directorio real dentro del repo.

---

## 14. Diferencias esperadas en OpenShift

Esta sección resume los cambios esperados al portar esta implementación a OpenShift.

### Instalación

| Aspecto | Kind (este proyecto) | OpenShift |
|---|---|---|
| Método de instalación | Helm chart via Kustomize helmCharts + ArgoCD | Igual, o Helm directo, u Operator |
| Chart | `backstage/backstage` 2.6.3 | Mismo chart o chart de RHDH (Red Hat Developer Hub) |
| Imagen | `ghcr.io/backstage/backstage:latest` | Misma, o imagen RHDH (`registry.redhat.io/rhdh/...`) |

### Networking

| Aspecto | Kind | OpenShift |
|---|---|---|
| Ingress controller | ingress-nginx (instalado manualmente) | Router de OpenShift (HAProxy, ya incluido) |
| Recurso de exposición | `Ingress` con `ingressClassName: nginx` | `Route` o `Ingress` con IngressClass del router OCP |
| TLS | Sin TLS (HTTP puro local) | TLS automático via cert-manager o wildcard cert del cluster |
| HSTS workaround | `proxy_hide_header` en annotation | Probablemente no necesario si se usa HTTPS real |

### Seguridad y RBAC

| Aspecto | Kind | OpenShift |
|---|---|---|
| SCC | No aplica (Kubernetes estándar) | El Pod necesita SCC `restricted` o `nonroot`. Revisar si `runAsNonRoot` está forzado |
| ServiceAccount | `backstage` (creado por el chart) | Igual, pero hay que asignar SCC correcta: `oc adm policy add-scc-to-user nonroot -z backstage -n backstage` |
| RBAC para Scaffolder | ClusterRole para namespaces + Role en argocd | Igual en concepto; en OCP puede requerirse también permisos sobre `projects.project.openshift.io` si se crean Projects en vez de Namespaces |

### Base de datos

| Kind | OpenShift |
|---|---|
| SQLite en memoria | PostgreSQL (StatefulSet, o servicio externo, o CrunchyData Postgres Operator) |

### Autenticación

| Kind | OpenShift |
|---|---|
| Guest sin auth | OIDC con Red Hat SSO / Keycloak, o GitHub OAuth |

### Secrets

| Kind | OpenShift |
|---|---|
| Secret manual con `kubectl create secret` | Igual, o usar Sealed Secrets / Vault / External Secrets Operator (más común en OCP) |

### Registry de imágenes

| Kind | OpenShift |
|---|---|
| Registry HTTP local (`registry.local:5000`) | OpenShift Internal Registry (`image-registry.openshift-image-registry.svc:5000`) o registry externo (Quay, etc.) |
| `imagePullPolicy: Always` sin autenticación | Puede requerir `imagePullSecret` si el registry es externo y privado |

### Consideración sobre Red Hat Developer Hub (RHDH)

Red Hat ofrece **RHDH** como distribución enterprise de Backstage. Viene con:
- Plugins de OpenShift/Tekton/ACM preinstalados
- Soporte oficial de Red Hat
- Operator para OCP (`rhdh-operator`)
- Imagen: `registry.redhat.io/rhdh/rhdh-hub-rhel9`

Si el objetivo es un IDP en producción en OCP, RHDH simplifica bastante el setup. El tradeoff es que la imagen no es la upstream de Backstage y algunos plugins community pueden no estar disponibles.

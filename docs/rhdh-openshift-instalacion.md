# Red Hat Developer Hub en OpenShift — Paso a paso

> Instalación de RHDH (Red Hat Developer Hub) en OCP 4.14+ via Helm + ArgoCD,
> con PostgreSQL en el cluster y autenticación OIDC (Keycloak / RH SSO).
>
> Reemplazar todos los placeholders `<...>` con los valores reales del entorno.

---

## Tabla de contenidos

1. [Prerequisitos](#1-prerequisitos)
2. [Estructura de archivos](#2-estructura-de-archivos)
3. [Secretos (crear manualmente)](#3-secretos-crear-manualmente)
4. [Configurar Keycloak](#4-configurar-keycloak)
5. [Namespace y SCC](#5-namespace-y-scc)
6. [PostgreSQL — kustomization](#6-postgresql--kustomization)
7. [RHDH — kustomization](#7-rhdh--kustomization)
8. [Route de OpenShift](#8-route-de-openshift)
9. [RBAC para el Scaffolder](#9-rbac-para-el-scaffolder)
10. [ArgoCD Applications](#10-argocd-applications)
11. [Verificación](#11-verificación)
12. [Diferencias clave con la instalación local](#12-diferencias-clave-con-la-instalación-local)

---

## 1. Prerequisitos

- OCP 4.14+ con acceso de `cluster-admin`
- ArgoCD (OpenShift GitOps Operator) instalado
- `oc` y `kubectl` configurados apuntando al cluster
- GitHub PAT con scopes `repo` (para el Scaffolder)
- Keycloak o RH SSO accesible desde el cluster (ver sección 4)
- Acceso a `registry.redhat.io` (para bajar la imagen de RHDH) — requiere pull secret de Red Hat

**Verificar pull secret de Red Hat:**
```bash
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d | python3 -m json.tool | grep "registry.redhat.io"
```
Si no está, agregar las credenciales de Red Hat Customer Portal:
```bash
oc create secret docker-registry rh-registry \
  --docker-server=registry.redhat.io \
  --docker-username=<rh-user> \
  --docker-password=<rh-password> \
  -n rhdh
oc secrets link default rh-registry --for=pull -n rhdh
```

---

## 2. Estructura de archivos

Misma convención del IDP local: `base/overlays/dev/` con Kustomize, gestionado por ArgoCD.

```
gitops/platform/rhdh/
├── base/
│   ├── kustomization.yaml          ← PostgreSQL + RHDH via helmCharts
│   ├── namespace.yaml
│   ├── route.yaml
│   └── scaffolder-rbac.yaml
└── overlays/
    └── dev/
        └── kustomization.yaml

gitops/apps/templates/
└── rhdh-app.yaml                   ← ArgoCD Application
```

Los secretos **nunca van a Git**. Se crean manualmente en el cluster (sección 3).

---

## 3. Secretos (crear manualmente)

### 3.1 GitHub PAT

```bash
oc create secret generic github-pat \
  --from-literal=token=<github-pat> \
  -n rhdh
```

### 3.2 PostgreSQL password

```bash
oc create secret generic rhdh-postgres \
  --from-literal=password=<postgres-password> \
  -n rhdh
```

Este mismo secret lo usan tanto el chart de PostgreSQL como el de RHDH.

### 3.3 OIDC client secret (Keycloak)

```bash
oc create secret generic rhdh-oidc \
  --from-literal=clientSecret=<keycloak-client-secret> \
  -n rhdh
```

---

## 4. Configurar Keycloak

Keycloak necesita un Realm y un Client configurado para RHDH antes de arrancar la instalación.

### 4.1 Crear Realm

1. Entrar a la consola de Keycloak como admin.
2. Crear un Realm nuevo: `rhdh` (o usar el existente `master` solo para dev).

### 4.2 Crear Client

En el Realm `rhdh`:

1. **Clients → Create client**
   - Client type: `OpenID Connect`
   - Client ID: `rhdh`

2. **Capability config:**
   - Client authentication: `ON` (confidential client)
   - Authentication flow: `Standard flow` ✓

3. **Login settings:**
   - Valid redirect URIs: `https://rhdh.apps.<cluster-domain>/api/auth/oidc/handler/frame`
   - Web origins: `https://rhdh.apps.<cluster-domain>`

4. **Copiar el Client Secret:**
   - Tab `Credentials` → copiar el valor de `Client secret`
   - Ese valor va al secret `rhdh-oidc` creado en el paso 3.3

### 4.3 Crear usuario de prueba (opcional)

En `Users → Add user`, crear un usuario con contraseña para testear el login.

### 4.4 Datos que se necesitan en el app-config

| Variable | Dónde se encuentra |
|---|---|
| `<keycloak-base-url>` | URL de Keycloak, ej: `https://keycloak.apps.<cluster-domain>` |
| `<keycloak-realm>` | Nombre del Realm, ej: `rhdh` |
| `<keycloak-client-id>` | `rhdh` (el Client ID del paso 4.2) |
| `<keycloak-client-secret>` | Tab Credentials del Client |

---

## 5. Namespace y SCC

### namespace.yaml

```yaml
# gitops/platform/rhdh/base/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: rhdh
  labels:
    app.kubernetes.io/managed-by: argocd
```

### SCC para el ServiceAccount de RHDH

El chart de RHDH crea un ServiceAccount `rhdh-backstage`. En OpenShift hay que asignarle una SCC que permita correr como non-root.

```bash
# Ejecutar una sola vez, después del primer sync de ArgoCD que crea el namespace
oc adm policy add-scc-to-user nonroot \
  -z rhdh-backstage \
  -n rhdh
```

> **Nota:** si ArgoCD gestiona este step, se puede incluir como un `Job` post-sync hook. Para una instalación inicial manual es más simple correrlo a mano después del primer sync.

### SCC para PostgreSQL (Bitnami)

El chart de Bitnami PostgreSQL intenta correr con un UID específico. Necesita la SCC `anyuid`:

```bash
oc adm policy add-scc-to-user anyuid \
  -z rhdh-postgresql \
  -n rhdh
```

---

## 6. PostgreSQL — kustomization

PostgreSQL se instala via `helmCharts` en el mismo `kustomization.yaml` que RHDH, en el mismo namespace.

**Chart:** `bitnami/postgresql`

```yaml
# fragmento del kustomization.yaml — ver sección 7 para el archivo completo
helmCharts:
  - name: postgresql
    repo: https://charts.bitnami.com/bitnami
    version: "16.4.0"
    releaseName: rhdh-postgresql
    namespace: rhdh
    valuesInline:
      auth:
        username: backstage
        database: backstage
        existingSecret: rhdh-postgres      # ← usa el secret creado en paso 3.2
        secretKeys:
          userPasswordKey: password
          adminPasswordKey: password
      primary:
        persistence:
          enabled: true
          size: 5Gi
        podSecurityContext:
          enabled: false                   # OCP maneja el SecurityContext via SCC
        containerSecurityContext:
          enabled: false
```

**`podSecurityContext.enabled: false` y `containerSecurityContext.enabled: false`:**
Bitnami por defecto intenta setear UID/GID específicos. En OpenShift, el SecurityContext lo gestiona la SCC asignada. Si se dejan habilitados, el pod falla con error de SCC. Deshabilitarlos deja que OCP asigne el UID del rango del namespace.

---

## 7. RHDH — kustomization

**Imagen:** `registry.redhat.io/rhdh/rhdh-hub-rhel9:1.4`

> Verificar la última versión en: `oc describe packagemanifest rhdh -n openshift-marketplace` o en [Red Hat Catalog](https://catalog.redhat.com/software/containers/rhdh/rhdh-hub-rhel9).

```yaml
# gitops/platform/rhdh/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: rhdh

resources:
  - namespace.yaml
  - route.yaml
  - scaffolder-rbac.yaml

helmCharts:
  # ── PostgreSQL ──────────────────────────────────────────────────────────────
  - name: postgresql
    repo: https://charts.bitnami.com/bitnami
    version: "16.4.0"
    releaseName: rhdh-postgresql
    namespace: rhdh
    valuesInline:
      auth:
        username: backstage
        database: backstage
        existingSecret: rhdh-postgres
        secretKeys:
          userPasswordKey: password
          adminPasswordKey: password
      primary:
        persistence:
          enabled: true
          size: 5Gi
        podSecurityContext:
          enabled: false
        containerSecurityContext:
          enabled: false

  # ── RHDH ────────────────────────────────────────────────────────────────────
  - name: redhat-developer-hub
    repo: https://redhat-developer.github.io/rhdh-chart
    version: "2.0.0"          # verificar última versión estable
    releaseName: rhdh
    namespace: rhdh
    valuesInline:
      global:
        clusterRouterBase: apps.<cluster-domain>   # ← reemplazar
        # Deshabilitar el Route que crea el chart — lo gestionamos nosotros
        # para tener control total sobre el objeto
        dynamic:
          includes:
            - dynamic-plugins.default.yaml

      upstream:
        backstage:
          image:
            registry: registry.redhat.io
            repository: rhdh/rhdh-hub-rhel9
            tag: "1.4"
            pullPolicy: IfNotPresent

          # Mismo truco que en local: cargar el config base + el nuestro en cascada
          args:
            - "--config"
            - "/app/app-config.yaml"
            - "--config"
            - "/app/app-config-from-configmap.yaml"

          # Inyectar secretos como env vars
          extraEnvVarsSecrets:
            - github-pat
            - rhdh-oidc

          appConfig:
            app:
              title: Developer Hub
              baseUrl: https://rhdh.apps.<cluster-domain>

            backend:
              baseUrl: https://rhdh.apps.<cluster-domain>
              listen:
                port: 7007
                host: "0.0.0.0"
              cors:
                origin: https://rhdh.apps.<cluster-domain>
              database:
                client: pg
                connection:
                  host: rhdh-postgresql
                  port: 5432
                  user: backstage
                  password: ${RHDH_POSTGRES_PASSWORD}   # ← desde secret rhdh-postgres
                  database: backstage
                  ssl: false   # cambiar a true si PostgreSQL tiene TLS habilitado

            auth:
              environment: production
              session:
                secret: ${SESSION_SECRET}   # agregar al secret rhdh-oidc si se quiere persistir
              providers:
                oidc:
                  production:
                    metadataUrl: https://<keycloak-base-url>/realms/<keycloak-realm>/.well-known/openid-configuration
                    clientId: rhdh
                    clientSecret: ${clientSecret}   # ← del secret rhdh-oidc
                    scope: openid profile email
                    signIn:
                      resolvers:
                        - resolver: emailMatchingUserEntityProfileEmail
                signInPage: oidc

            integrations:
              github:
                - host: github.com
                  token: ${token}   # ← del secret github-pat

            kubernetes:
              serviceLocatorMethod:
                type: multiTenant
              clusterLocatorMethods:
                - type: config
                  clusters:
                    - url: https://kubernetes.default.svc
                      name: ocp-cluster
                      authProvider: serviceAccount
                      skipTLSVerify: false
                      caData: ${SA_CA_DATA}   # ver nota abajo
                      serviceAccountToken: ${KUBERNETES_SERVICE_ACCOUNT_TOKEN}

            catalog:
              rules:
                - allow: [Component, System, API, Group, User, Resource, Location, Template]
              locations:
                - type: url
                  target: https://github.com/<owner>/<idp-repo>/blob/main/catalog-info.yaml
                  rules:
                    - allow: [Component, System, Template, Location]
              processingInterval: { minutes: 1 }

            organization:
              name: <org-name>

          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 2Gi

        postgresql:
          enabled: false   # usamos el chart de Bitnami instalado por separado

        service:
          type: ClusterIP
          ports:
            backend: 7007
```

### Nota sobre `caData` del API server de OCP

En OpenShift no se puede usar `skipTLSVerify: true` fácilmente en producción. Para obtener el CA del cluster:

```bash
oc get configmap kube-root-ca.crt -n kube-public \
  -o jsonpath='{.data.ca\.crt}' | base64 | tr -d '\n'
```

Agregar ese valor como `SA_CA_DATA` al secret `rhdh-oidc` o crear un secret dedicado:

```bash
CA_DATA=$(oc get configmap kube-root-ca.crt -n kube-public \
  -o jsonpath='{.data.ca\.crt}' | base64 | tr -d '\n')

oc create secret generic rhdh-k8s \
  --from-literal=SA_CA_DATA="$CA_DATA" \
  -n rhdh

# Agregar al extraEnvVarsSecrets en el values:
# extraEnvVarsSecrets:
#   - github-pat
#   - rhdh-oidc
#   - rhdh-k8s
```

### Nota sobre `RHDH_POSTGRES_PASSWORD`

El secret `rhdh-postgres` tiene la key `password`. El nombre de la env var que se expone es `password` (igual a la key). En el app-config se referencia como `${password}`. Si se prefiere un nombre más explícito, crear el secret con la key `RHDH_POSTGRES_PASSWORD`:

```bash
oc create secret generic rhdh-postgres \
  --from-literal=RHDH_POSTGRES_PASSWORD=<postgres-password> \
  -n rhdh
```

Y en el chart de Bitnami, ajustar `secretKeys.userPasswordKey: RHDH_POSTGRES_PASSWORD`.

---

## 8. Route de OpenShift

En lugar de Ingress + ingress-nginx, OpenShift usa `Route`. TLS edge termination: el router de OCP termina TLS y hace forward HTTP al Service interno.

```yaml
# gitops/platform/rhdh/base/route.yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: rhdh
  namespace: rhdh
  labels:
    app.kubernetes.io/name: rhdh
    app.kubernetes.io/managed-by: argocd
spec:
  host: rhdh.apps.<cluster-domain>   # ← reemplazar
  to:
    kind: Service
    name: rhdh-backstage
    weight: 100
  port:
    targetPort: http-backend
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
```

**`insecureEdgeTerminationPolicy: Redirect`:** redirige HTTP → HTTPS automáticamente.

**`targetPort: http-backend`:** el chart de RHDH expone el Service con ese nombre de puerto. Verificar con:
```bash
oc get svc rhdh-backstage -n rhdh -o jsonpath='{.spec.ports[*].name}'
```

---

## 9. RBAC para el Scaffolder

Idéntico al IDP local. El Scaffolder necesita permisos para crear Namespaces y ArgoCD Applications.

En OpenShift, los Namespaces son `Project` a nivel de recurso de API — pero el grupo `""` con `namespaces` sigue funcionando.

```yaml
# gitops/platform/rhdh/base/scaffolder-rbac.yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rhdh-scaffolder
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "create"]
  # En OCP también se puede necesitar crear Projects
  - apiGroups: ["project.openshift.io"]
    resources: ["projects", "projectrequests"]
    verbs: ["get", "list", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rhdh-scaffolder
subjects:
  - kind: ServiceAccount
    name: rhdh-backstage
    namespace: rhdh
roleRef:
  kind: ClusterRole
  name: rhdh-scaffolder
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: rhdh-argocd
  namespace: argocd
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["applications"]
    verbs: ["get", "list", "create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: rhdh-argocd
  namespace: argocd
subjects:
  - kind: ServiceAccount
    name: rhdh-backstage
    namespace: rhdh
roleRef:
  kind: Role
  name: rhdh-argocd
  apiGroup: rbac.authorization.k8s.io
```

---

## 10. ArgoCD Applications

### Overlay dev

```yaml
# gitops/platform/rhdh/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base
```

### ArgoCD Application

```yaml
# gitops/apps/templates/rhdh-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rhdh
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default

  source:
    repoURL: https://github.com/<owner>/<idp-repo>.git
    targetRevision: HEAD
    path: gitops/platform/rhdh/overlays/dev

  destination:
    server: https://kubernetes.default.svc
    namespace: rhdh

  syncPolicy:
    automated:
      selfHeal: true
      prune: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

Pushearlo a Git es suficiente para que el `root-app` de ArgoCD lo detecte y lo despliegue.

---

## 11. Verificación

### Paso a paso de verificación

**1. Namespace y pods:**
```bash
oc get pods -n rhdh -w
# Esperar:
# rhdh-postgresql-0          1/1  Running
# rhdh-backstage-<hash>      1/1  Running
```

**2. Logs de RHDH si el pod no arranca:**
```bash
oc logs -n rhdh -l app.kubernetes.io/name=backstage --tail=100 -f
```

Errores comunes:
- `connect ECONNREFUSED` → PostgreSQL no está listo todavía, esperar
- `invalid_client` → client secret de Keycloak incorrecto
- `certificate has expired` → el CA del cluster no está cargado correctamente

**3. Route accesible:**
```bash
oc get route rhdh -n rhdh
# Debería mostrar el host: rhdh.apps.<cluster-domain>
curl -sk https://rhdh.apps.<cluster-domain>/healthcheck
# Respuesta: {"status":"ok"}
```

**4. Login con Keycloak:**
- Abrir `https://rhdh.apps.<cluster-domain>` en el browser
- Redirige a Keycloak → ingresar con el usuario creado en el paso 4.3
- Redirige de vuelta a RHDH autenticado

**5. Catálogo:**
```bash
# Verificar que Backstage indexó el catalog-info.yaml
# En la UI: Catalog → buscar los templates
```

**6. Scaffolder:**
- Ir a `Create` en la UI
- Ejecutar un template de prueba
- Verificar que el PR se crea en GitHub

---

## 12. Diferencias clave con la instalación local

| Aspecto | IDP Local (Kind) | OCP + RHDH |
|---|---|---|
| **Imagen** | `ghcr.io/backstage/backstage:latest` | `registry.redhat.io/rhdh/rhdh-hub-rhel9:1.4` |
| **Chart** | `backstage/backstage` | `redhat-developer-hub` |
| **Base de datos** | SQLite en memoria | PostgreSQL (StatefulSet) |
| **Autenticación** | Guest (sin auth) | OIDC via Keycloak/RH SSO |
| **Exposición** | Ingress + ingress-nginx (HTTP) | Route de OCP (HTTPS, TLS edge) |
| **TLS** | Sin TLS | TLS edge en el Router de OCP |
| **SCC** | No aplica | `nonroot` para RHDH, `anyuid` para PostgreSQL |
| **API server URL** | `https://kubernetes.default.svc` | Igual |
| **`skipTLSVerify`** | `true` (cert autofirmado de Kind) | `false` + `caData` del cluster |
| **HSTS workaround** | `proxy_hide_header` en nginx | No necesario (TLS real) |
| **Pull secret** | No necesario (imagen pública) | Requiere credenciales de `registry.redhat.io` |
| **Proyectos OCP** | No aplica | El Scaffolder puede crear `ProjectRequests` además de Namespaces |

# ${{ values.appName }}

${{ values.description }}

**Proyecto:** ${{ values.projectName }}
**Lenguaje:** ${{ values.language }}
**Puerto:** ${{ values.port }}

## Desarrollo local

```bash
# Go
go run .

# Python
python main.py

# Node.js
node index.js
```

## Build y push de imagen

```bash
# Build
docker build -t registry.local/${{ values.projectName }}/${{ values.appName }}:latest .

# Push al registro interno de Kind
docker push registry.local/${{ values.projectName }}/${{ values.appName }}:latest
```

## Acceso

Una vez desplegado en el cluster:

```
http://${{ values.appName }}.${{ values.projectName }}.local
```

Agregar al `/etc/hosts`:
```
127.0.0.1  ${{ values.appName }}.${{ values.projectName }}.local
```

## GitOps

Los manifiestos Kubernetes están en:
```
https://github.com/NicoMiretti/idp-local/tree/main/gitops/platform/${{ values.projectName }}/base/apps/${{ values.appName }}
```

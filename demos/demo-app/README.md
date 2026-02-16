# Demo App

Flask container image used by the [App Gateway + Container Instances](../appgw-container-iac/README.md) demo. Provides a web UI for interacting with Key Vault, Blob Storage, and Queue Storage via managed identity.

## Routes

- `/` — Dashboard with service connectivity status and private endpoint detection
- `/secrets` — Create, view, delete Key Vault secrets
- `/blobs` — Upload, download, delete text blobs
- `/queues` — Send, receive, peek queue messages
- `/health` — Health check (used by App Gateway probe)

## Build and Push

No local Docker needed — `az acr build` runs the build in Azure:

```bash
bash build_image.sh
```

This creates an ACR (if needed) and pushes the image. Use the output values to configure `appgw-container-iac/azuredeploy.bicepparam`.

## Run Locally

```bash
bash run-local.sh
```

Starts the app on `http://localhost:8080` with mocked Azure modules. Services show "Not configured" since there are no real Azure backends.

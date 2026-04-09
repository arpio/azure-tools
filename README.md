# azure-tools
Azure IaC demos for Arpio disaster recovery scenarios.

## Demos

* [Load Balancer + VMs + Azure SQL](demos/lb-server-db-iac/README.md) — 3-tier VM stack with NAT Gateway and blob storage
* [App Gateway + Container Instances](demos/appgw-container-iac/README.md) — Containerized app with Key Vault, Blob, and Queue via private endpoints
* [demo-app](demos/demo-app/) — Shared Flask container image used by the App Gateway demo
* [LAMP Stack + App Gateway + Load Balancer](demos/lamp-app/README.md) — PHP dashboard on Ubuntu VM with Application Gateway (L7) and Load Balancer (L4) for Network Sandbox testing
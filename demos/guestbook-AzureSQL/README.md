# Azure Guestbook

**Fully wired demo environment:** VM + IIS, SQL + Guestbook table, Key Vault + RBAC
Use whatever resource group name you want, along with your own Windows admin password and SQL admin password.

**Networking**
- 1 VNet + 1 subnet
- 1 NSG with RDP + HTTP open
- 1 public IP + 1 NIC

**Compute**
- 1 Windows Server 2022 VM
- Public IP, RDP + HTTP allowed
- IIS installed
- System-assigned managed identity enabled

**Data**
- 1 Azure SQL Server
- 1 database: GuestbookDb
- 1 table: dbo.Guestbook (created and ready for inserts)

**Secrets**
- 1 Key Vault (RBAC mode)
    - Secrets:
        - sql-admin-password
        - vm-admin-password
    - VM identity granted Key Vault Secrets User on that vault

**Connection info**
- URL to hit the VM in a browser
- RDP creds to log in
- SQL connection string to plug into an app
- Key Vault name (needed for Web.config)

## What the script does (deep dive)

Prompts for inputs:
- Resource Group name (default rg-arpio-demo if you just hit Enter)
- Windows VM admin password
- SQL admin password

Creates the basic Azure shell

Creates the Resource Group in eastus2.

Registers the Microsoft.KeyVault provider and waits for it to be ready

Builds the network

Creates a VNet + subnet

Creates a public IP

Creates an NSG and adds rules for RDP (3389) & HTTP (80)

Creates a NIC and attaches subnet + NSG + public IP

Creates Azure SQL

Creates an Azure SQL Server with your SQL admin + password.
Adds firewall rule to allow Azure services.

Creates the GuestbookDb database.

Creates the Windows VM

Deploys a Windows Server 2022 VM (Standard_B2s)

Enables a system-assigned managed identity on the VM

Installs IIS + ASP.NET via a VM extension

Creates and wires up Key Vault

Creates a Key Vault in the same RG/region with RBAC enabled.

Stores two secrets:  sql-admin-password & vm-admin-password (what you've chosen)

Looks up the VM’s managed identity and the Key Vault ID

Assigns the VM the “Key Vault Secrets User” role scoped to that Key Vault

Creates the Guestbook table

Builds a CREATE TABLE script for dbo.Guestbook

Runs a retry loop (up to ~3 minutes) until:

Azure SQL is ready

The Guestbook table is created (if not already there)

## Prints out the goodies
- Public IP + http://<ip> URL for the VM.
RDP connection info (IP, username, password).
- Full SQL connection string.
- Key Vault name.

#!/bin/bash
# Update only the VM resource with new cloud-init configuration
set -e

RESOURCE_GROUP="${RESOURCE_GROUP:-LampApp-rg}"
VM_NAME="${VM_NAME:-LampApp-vm}"

echo "Updating VM cloud-init configuration..."
echo "This will:"
echo "  1. Stop and deallocate the VM"
echo "  2. Update the VM with new cloud-init config"
echo "  3. Start the VM"
echo ""
echo "⚠️  This will cause ~2-3 minutes of downtime"
echo ""

# Stop VM
echo "Stopping VM..."
az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"

# Update VM with new cloud-init
echo "Updating VM configuration..."
az vm update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --set osProfile.linuxConfiguration.disablePasswordAuthentication=true

# Start VM
echo "Starting VM..."
az vm start --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"

echo "✓ VM updated with new cloud-init configuration"

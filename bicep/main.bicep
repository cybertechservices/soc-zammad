// ============================================================================
// Zammad Azure VM Deployment
// ============================================================================
// Deploys a complete Azure VM infrastructure for running Zammad with Docker
// Estimated cost: ~$73/month (Standard_B2ms + 128GB SSD + Static IP)
// ============================================================================

targetScope = 'resourceGroup'

// ============================================================================
// Parameters
// ============================================================================

@description('Location for all resources')
param location string = resourceGroup().location

@description('Base name for all resources')
@minLength(3)
@maxLength(20)
param baseName string = 'soc-itsm'

@description('VM size - B2ms recommended for small/medium deployments')
@allowed([
  'Standard_B2s'    // 2 vCPU, 4GB RAM - ~$30/mo (minimal)
  'Standard_B2ms'   // 2 vCPU, 8GB RAM - ~$60/mo (recommended)
  'Standard_D2s_v3' // 2 vCPU, 8GB RAM - ~$70/mo (general purpose)
  'Standard_D4s_v3' // 4 vCPU, 16GB RAM - ~$140/mo (larger deployments)
])
param vmSize string = 'Standard_B2ms'

@description('Admin username for the VM')
param adminUsername string = 'zammadadmin'

@description('SSH public key for VM access')
@secure()
param sshPublicKey string

@description('Data disk size in GB for Docker volumes')
@minValue(64)
@maxValue(1024)
param dataDiskSizeGB int = 128

@description('Enable auto-shutdown at specified time (UTC)')
param enableAutoShutdown bool = false

@description('Auto-shutdown time in UTC (HH:mm)')
param autoShutdownTime string = '23:00'

@description('Your IP address for SSH access (CIDR notation, e.g., 203.0.113.0/24). Leave empty for any.')
param allowedSshCidr string = ''

@description('Enable Azure Backup for the VM')
param enableBackup bool = false

@description('Tags for all resources')
param tags object = {
  project: 'zammad'
  environment: 'production'
  managedBy: 'bicep'
}

// ============================================================================
// Variables
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id)
var vmName = '${baseName}-vm'
var vnetName = '${baseName}-vnet'
var subnetName = '${baseName}-subnet'
var nsgName = '${baseName}-nsg'
var publicIpName = '${baseName}-pip'
var nicName = '${baseName}-nic'
var dataDiskName = '${baseName}-datadisk'
var osDiskName = '${baseName}-osdisk'

// Cloud-init script to install Docker and configure the VM
var cloudInitScript = '''
#cloud-config
package_update: true
package_upgrade: true

packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - git
  - jq
  - htop
  - unzip

runcmd:
  # Install Docker
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  # Add admin user to docker group
  - usermod -aG docker ${adminUsername}

  # Format and mount data disk
  - |
    if [ -b /dev/disk/azure/scsi1/lun0 ]; then
      mkfs.ext4 -F /dev/disk/azure/scsi1/lun0
      mkdir -p /data
      echo '/dev/disk/azure/scsi1/lun0 /data ext4 defaults,nofail 0 2' >> /etc/fstab
      mount /data
      mkdir -p /data/docker

      # Configure Docker to use data disk
      mkdir -p /etc/docker
      echo '{"data-root": "/data/docker"}' > /etc/docker/daemon.json
      systemctl restart docker
    fi

  # Create deployment directory
  - mkdir -p /opt/zammad
  - chown ${adminUsername}:${adminUsername} /opt/zammad

  # Enable Docker service
  - systemctl enable docker
  - systemctl start docker

final_message: "Zammad VM setup complete after $UPTIME seconds"
'''

// ============================================================================
// Network Security Group
// ============================================================================

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: empty(allowedSshCidr) ? '*' : allowedSshCidr
          destinationAddressPrefix: '*'
          description: 'Allow SSH access'
        }
      }
      {
        name: 'Allow-HTTP'
        properties: {
          priority: 1100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          description: 'Allow HTTP for ACME challenge and redirect to HTTPS'
        }
      }
      {
        name: 'Allow-HTTPS'
        properties: {
          priority: 1200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          description: 'Allow HTTPS for all services (Zammad, Grafana, Prometheus)'
        }
      }
    ]
  }
}

// ============================================================================
// Virtual Network
// ============================================================================

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// ============================================================================
// Public IP Address
// ============================================================================

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${baseName}-${uniqueSuffix}'
    }
  }
}

// ============================================================================
// Network Interface
// ============================================================================

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

// ============================================================================
// Data Disk
// ============================================================================

resource dataDisk 'Microsoft.Compute/disks@2023-10-02' = {
  name: dataDiskName
  location: location
  tags: tags
  sku: {
    name: 'StandardSSD_LRS'
  }
  properties: {
    diskSizeGB: dataDiskSizeGB
    creationData: {
      createOption: 'Empty'
    }
  }
}

// ============================================================================
// Virtual Machine
// ============================================================================

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(replace(cloudInitScript, '${adminUsername}', adminUsername))
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: osDiskName
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        diskSizeGB: 64
      }
      dataDisks: [
        {
          lun: 0
          name: dataDisk.name
          createOption: 'Attach'
          managedDisk: {
            id: dataDisk.id
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ============================================================================
// Auto-Shutdown Schedule (Optional)
// ============================================================================

resource autoShutdownSchedule 'Microsoft.DevTestLab/schedules@2018-09-15' = if (enableAutoShutdown) {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: 'UTC'
    targetResourceId: vm.id
  }
}

// ============================================================================
// Recovery Services Vault for Backup (Optional)
// ============================================================================

resource recoveryVault 'Microsoft.RecoveryServices/vaults@2023-06-01' = if (enableBackup) {
  name: '${baseName}-vault'
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

resource backupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-06-01' = if (enableBackup) {
  parent: recoveryVault
  name: '${baseName}-backup-policy'
  properties: {
    backupManagementType: 'AzureIaasVM'
    instantRpRetentionRangeInDays: 2
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: [
        '2024-01-01T03:00:00Z'
      ]
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          '2024-01-01T03:00:00Z'
        ]
        retentionDuration: {
          count: 7
          durationType: 'Days'
        }
      }
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('VM resource ID')
output vmId string = vm.id

@description('VM name')
output vmName string = vm.name

@description('Public IP address')
output publicIpAddress string = publicIp.properties.ipAddress

@description('Fully qualified domain name')
output fqdn string = publicIp.properties.dnsSettings.fqdn

@description('SSH connection string')
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.ipAddress}'

@description('Zammad URL (configure DOMAIN in .env to match)')
output zammadUrl string = 'https://${publicIp.properties.dnsSettings.fqdn}'

@description('Grafana URL (configure GRAFANA_DOMAIN in .env)')
output grafanaUrl string = 'https://grafana.${publicIp.properties.dnsSettings.fqdn}'

@description('Prometheus URL (configure PROMETHEUS_DOMAIN in .env)')
output prometheusUrl string = 'https://prometheus.${publicIp.properties.dnsSettings.fqdn}'

@description('Traefik Dashboard URL')
output traefikUrl string = 'https://traefik.${publicIp.properties.dnsSettings.fqdn}'

@description('Admin username')
output adminUsername string = adminUsername

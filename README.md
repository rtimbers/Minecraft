# High Availability Minecraft Server on Azure

This repository contains scripts to deploy a highly available Minecraft server infrastructure on Microsoft Azure. The architecture is designed to provide resilience, scalability, and performance for Minecraft game servers.

## Architecture Overview

The deployment creates a fault-tolerant Minecraft server environment with the following components:

```
                                  +-------------------+
                                  |                   |
                                  |  Azure Traffic    |
                                  |    Manager        |
                                  |                   |
                                  +--------+----------+
                                           |
                                           v
              +------------------------+---+---+------------------------+
              |                        |       |                        |
              v                        v       v                        v
    +-----------------+      +-----------------+      +-----------------+
    |                 |      |                 |      |                 |
    | Primary Zone 1  |      | Primary Zone 2  |      |   Secondary     |
    | Container       |      | Container       |      |   Region        |
    | Instance        |      | Instance        |      |   Container     |
    |                 |      |                 |      |                 |
    +-----------------+      +-----------------+      +-----------------+
              |                        |                        |
              |                        |                        |
              +------------------------+------------------------+
                                       |
                                       v
                           +-----------------------+
                           |                       |
                           |  Zone-Redundant       |
                           |  Storage (ZRS)        |
                           |                       |
                           +-----------+-----------+
                                       |
                                       v
                           +-----------------------+
                           |                       |
                           |  Recovery Services    |
                           |  Vault (Backups)      |
                           |                       |
                           +-----------------------+
                                       |
                                       v
                           +-----------------------+
                           |                       |
                           |  Log Analytics        |
                           |  Workspace            |
                           |                       |
                           +-----------------------+
                                       |
                                       v
                           +-----------------------+
                           |                       |
                           |  Azure Function       |
                           |  (Auto-scaling)       |
                           |                       |
                           +-----------------------+
```

## Key Features

### High Availability
- Multiple container instances across availability zones
- Secondary region deployment for geo-redundancy
- Traffic Manager for intelligent routing
- Zone-redundant storage for data persistence

### Auto-Scaling
- Dynamic scaling based on player count
- Azure Function that monitors server load every 5 minutes
- Automatically scales up when player load exceeds 80%
- Scales down when player load drops below 20%
- Maintains between 1-5 instances based on demand

### Data Protection
- Automated daily backups with 30-day retention
- Shared storage across all instances

### Enhanced Monitoring and Alerting
- Centralized Log Analytics workspace
- Container Insights integration
- Custom monitoring dashboard in Azure Portal
- Comprehensive alerts for CPU, memory, and availability
- Email and SMS notifications for critical events
- RCON and Query protocols enabled for server telemetry

### Performance Optimization
- Optimized JVM settings for Minecraft
- Sufficient CPU and memory allocation

## Deployment Instructions

1. Ensure you have the Azure PowerShell module installed
2. Connect to your Azure account using `Connect-AzAccount`
3. Run the deployment script: `./create_minecraft_server.ps1`
4. Access your Minecraft server via the Traffic Manager DNS: `minecraft-ha.trafficmanager.net`

## Configuration Options

The script includes several configurable parameters:

- `$resourceGroupName`: Name of the Azure resource group
- `$location`: Primary Azure region
- `$secondaryLocation`: Secondary Azure region for geo-redundancy
- `$storageAccountName`: Name of the storage account
- `$shareName`: Name of the file share

### Auto-Scaling Configuration
- `MAX_INSTANCES`: Maximum number of container instances (default: 5)
- `MIN_INSTANCES`: Minimum number of container instances (default: 1)
- `SCALE_UP_THRESHOLD`: Player load percentage to trigger scale up (default: 80%)
- `SCALE_DOWN_THRESHOLD`: Player load percentage to trigger scale down (default: 20%)
- `SCALE_INTERVAL_MINUTES`: How often to check for scaling (default: 5 minutes)

## Maintenance and Operations

### Backup and Restore
Backups are automatically created daily and retained for 30 days. To restore:

1. Navigate to the Recovery Services vault in the Azure portal
2. Select "Backup Items" → "Azure Storage (Azure Files)"
3. Choose the file share and select "Restore"

### Monitoring
Monitor the health of your Minecraft server through:

1. Azure Portal → Resource Group → Container Instances
2. Azure Portal → Resource Group → Traffic Manager profile
3. Azure Portal → Resource Group → "MinecraftMonitoringDashboard"
4. Log Analytics workspace → Logs → Query container logs

### Auto-Scaling Management
View auto-scaling activity:

1. Azure Portal → Resource Group → Function App → "minecraft-autoscaler"
2. Monitor → Logs to see scaling decisions
3. To adjust scaling parameters, modify the application settings in the Function App

## Implemented Enhancements

The following enhancements have been implemented:
- ✅ Auto-scaling based on player count
- ✅ Comprehensive logging solution
- ✅ Enhanced monitoring with a custom dashboard



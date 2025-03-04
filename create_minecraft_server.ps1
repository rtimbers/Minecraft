# High Availability Minecraft Server Deployment Script
# create a resource group
$resourceGroupName = "contino-minecraft-rg"
$location = "australiaeast"
$secondaryLocation = "australiasoutheast" # Secondary region for geo-redundancy
New-AzResourceGroup -Name $resourceGroupName -Location $location

# Create Log Analytics workspace for centralized logging
function SetupLogging {
    param( [string]$ResourceGroupName,
           [string]$WorkspaceName,
           [string]$Location )
    
    # Check if Log Analytics workspace exists
    $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction SilentlyContinue
    
    if ($workspace -eq $null) {
        # Create Log Analytics workspace
        $workspace = New-AzOperationalInsightsWorkspace `
            -ResourceGroupName $ResourceGroupName `
            -Name $WorkspaceName `
            -Location $Location `
            -Sku PerGB2018
        
        # Enable container insights solution
        New-AzOperationalInsightsWorkspaceSolution `
            -ResourceGroupName $ResourceGroupName `
            -WorkspaceName $WorkspaceName `
            -Type ContainerInsights
    }
    
    return $workspace
}

function SetupStorage {
    param( [string]$StorageResourceGroupName, 
           [string]$StorageAccountName, 
           [string]$ShareName,
           [string]$Location)

    # check if storage account exists
    $storageAccount = Get-AzStorageAccount `
        -ResourceGroupName $StorageResourceGroupName `
        -Name $StorageAccountName `
        -ErrorAction SilentlyContinue

    if ($storageAccount -eq $null) {
        # create the storage account with zone-redundant storage for high availability
        $storageAccount = New-AzStorageAccount `
            -ResourceGroupName $StorageResourceGroupName `
            -Name $StorageAccountName `
            -SkuName Standard_ZRS `  # Zone-redundant storage for HA
            -Location $Location `
            -Kind StorageV2 `
            -EnableHttpsTrafficOnly $true
    }

    # check if the file share already exists
    $share = Get-AzStorageShare `
        -Name $ShareName -Context $storageAccount.Context `
        -ErrorAction SilentlyContinue

    if ($share -eq $null) {
        # create the share
        $share = New-AzStorageShare `
            -Name $ShareName `
            -Context $storageAccount.Context
    }

    # get the credentials
    $storageAccountKeys = Get-AzStorageAccountKey `
        -ResourceGroupName $StorageResourceGroupName `
        -Name $StorageAccountName

    $storageAccountKey = $storageAccountKeys[0].Value
    $storageAccountKeySecureString = ConvertTo-SecureString $storageAccountKey -AsPlainText -Force
    $storageAccountCredentials = New-Object System.Management.Automation.PSCredential ($storageAccountName, $storageAccountKeySecureString)
    
    # Setup backup policy for the file share
    $vault = Get-AzRecoveryServicesVault -ResourceGroupName $StorageResourceGroupName -Name "minecraft-backup-vault" -ErrorAction SilentlyContinue
    if ($vault -eq $null) {
        $vault = New-AzRecoveryServicesVault -ResourceGroupName $StorageResourceGroupName -Name "minecraft-backup-vault" -Location $Location
    }
    
    Set-AzRecoveryServicesVaultContext -Vault $vault
    $policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name "DailyBackupPolicy" -ErrorAction SilentlyContinue
    if ($policy -eq $null) {
        $schPol = Get-AzRecoveryServicesBackupSchedulePolicyObject -WorkloadType "AzureFiles" -PolicyType "Daily"
        $retPol = Get-AzRecoveryServicesBackupRetentionPolicyObject -WorkloadType "AzureFiles"
        $retPol.DailySchedule.DurationCountInDays = 30
        $policy = New-AzRecoveryServicesBackupProtectionPolicy -Name "DailyBackupPolicy" -WorkloadType "AzureFiles" -RetentionPolicy $retPol -SchedulePolicy $schPol
    }
    
    # Enable backup for the file share
    Enable-AzRecoveryServicesBackupProtection -StorageAccountName $StorageAccountName -Name $ShareName -Policy $policy -ErrorAction SilentlyContinue
    
    return $storageAccountCredentials
}

# Setup Traffic Manager for load balancing
function SetupTrafficManager {
    param( [string]$ResourceGroupName,
           [string]$ProfileName,
           [string]$Location,
           [array]$Endpoints )
    
    # Check if Traffic Manager profile exists
    $profile = Get-AzTrafficManagerProfile -ResourceGroupName $ResourceGroupName -Name $ProfileName -ErrorAction SilentlyContinue
    
    if ($profile -eq $null) {
        # Create Traffic Manager profile
        $profile = New-AzTrafficManagerProfile `
            -ResourceGroupName $ResourceGroupName `
            -Name $ProfileName `
            -RelativeDnsName "minecraft-ha" `
            -Ttl 30 `
            -MonitorProtocol TCP `
            -MonitorPort 25565 `
            -MonitorPath "/" `
            -TrafficRoutingMethod Performance
    }
    
    # Add endpoints to Traffic Manager
    foreach ($endpoint in $Endpoints) {
        $existingEndpoint = Get-AzTrafficManagerEndpoint -Name $endpoint.Name -ProfileName $ProfileName -ResourceGroupName $ResourceGroupName -Type ExternalEndpoints -ErrorAction SilentlyContinue
        
        if ($existingEndpoint -eq $null) {
            Add-AzTrafficManagerEndpointConfig `
                -EndpointName $endpoint.Name `
                -TrafficManagerProfile $profile `
                -Type ExternalEndpoints `
                -Target $endpoint.Target `
                -EndpointLocation $endpoint.Location `
                -EndpointStatus Enabled
        }
    }
    
    Set-AzTrafficManagerProfile -TrafficManagerProfile $profile
}

# Setup Azure Monitor for health monitoring with enhanced metrics and logging
function SetupMonitoring {
    param( [string]$ResourceGroupName,
           [string]$Location,
           [array]$ResourceIds,
           [string]$LogAnalyticsWorkspaceId )
    
    # Create action group for alerts
    $actionGroup = Get-AzActionGroup -ResourceGroupName $ResourceGroupName -Name "MinecraftAlerts" -ErrorAction SilentlyContinue
    
    if ($actionGroup -eq $null) {
        $actionGroup = Set-AzActionGroup `
            -ResourceGroupName $ResourceGroupName `
            -Name "MinecraftAlerts" `
            -ShortName "MCAlerts" `
            -Receiver @(
                (New-AzActionGroupReceiver -Name "EmailAdmin" -EmailReceiver -EmailAddress "admin@example.com"),
                (New-AzActionGroupReceiver -Name "SMSAdmin" -SmsReceiver -CountryCode "1" -PhoneNumber "5555555555")
            )
    }
    
    # Create alert rules for each resource with more comprehensive monitoring
    foreach ($resourceId in $ResourceIds) {
        # CPU Alert
        $alertName = "ContainerCPUAlert-" + (Get-Random)
        Add-AzMetricAlertRuleV2 `
            -Name $alertName `
            -ResourceGroupName $ResourceGroupName `
            -WindowSize 00:05:00 `
            -Frequency 00:01:00 `
            -TargetResourceId $resourceId `
            -Condition (New-AzMetricAlertRuleV2Criteria -MetricName "CpuUsage" -TimeAggregation Average -Operator GreaterThan -Threshold 90) `
            -ActionGroup $actionGroup.Id `
            -Severity 2
            
        # Memory Alert
        $alertName = "ContainerMemoryAlert-" + (Get-Random)
        Add-AzMetricAlertRuleV2 `
            -Name $alertName `
            -ResourceGroupName $ResourceGroupName `
            -WindowSize 00:05:00 `
            -Frequency 00:01:00 `
            -TargetResourceId $resourceId `
            -Condition (New-AzMetricAlertRuleV2Criteria -MetricName "MemoryUsage" -TimeAggregation Average -Operator GreaterThan -Threshold 90) `
            -ActionGroup $actionGroup.Id `
            -Severity 2
            
        # Availability Alert
        $alertName = "ContainerAvailabilityAlert-" + (Get-Random)
        Add-AzMetricAlertRuleV2 `
            -Name $alertName `
            -ResourceGroupName $ResourceGroupName `
            -WindowSize 00:05:00 `
            -Frequency 00:01:00 `
            -TargetResourceId $resourceId `
            -Condition (New-AzMetricAlertRuleV2Criteria -MetricName "RestartingContainerCount" -TimeAggregation Total -Operator GreaterThan -Threshold 0) `
            -ActionGroup $actionGroup.Id `
            -Severity 1
    }
    
    # Connect resources to Log Analytics workspace for enhanced logging
    foreach ($resourceId in $ResourceIds) {
        Set-AzDiagnosticSetting `
            -ResourceId $resourceId `
            -WorkspaceId $LogAnalyticsWorkspaceId `
            -Enabled $true `
            -Category @("ContainerInstanceLog", "ContainerEvent") `
            -Name "ContainerDiagnostics"
    }
    
    # Create custom dashboard for monitoring
    $dashboardName = "MinecraftMonitoringDashboard"
    $dashboardJson = @"
{
  "properties": {
    "lenses": {
      "0": {
        "order": 0,
        "parts": {
          "0": {
            "position": {
              "x": 0,
              "y": 0,
              "colSpan": 6,
              "rowSpan": 4
            },
            "metadata": {
              "inputs": [
                {
                  "name": "resourceTypeMode",
                  "value": "workspace"
                },
                {
                  "name": "ComponentId",
                  "value": "$LogAnalyticsWorkspaceId"
                }
              ],
              "type": "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart",
              "settings": {
                "content": {
                  "Query": "ContainerInstanceLog_CL | where TimeGenerated > ago(1h) | order by TimeGenerated desc",
                  "Id": "LogsDashboardPart"
                }
              }
            }
          },
          "1": {
            "position": {
              "x": 6,
              "y": 0,
              "colSpan": 6,
              "rowSpan": 4
            },
            "metadata": {
              "inputs": [
                {
                  "name": "resourceTypeMode",
                  "value": "resource"
                },
                {
                  "name": "ComponentId",
                  "value": "$($ResourceIds[0])"
                }
              ],
              "type": "Extension/Microsoft_Azure_Monitoring/PartType/MetricsChartPart",
              "settings": {
                "content": {
                  "metrics": [
                    {
                      "resourceMetadata": {
                        "id": "$($ResourceIds[0])"
                      },
                      "name": "CpuUsage",
                      "aggregationType": 4,
                      "namespace": "microsoft.containerinstance/containergroups",
                      "metricVisualization": {
                        "displayName": "CPU Usage"
                      }
                    }
                  ],
                  "title": "CPU Usage",
                  "visualization": {
                    "chartType": 2
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
"@
    
    New-AzPortalDashboard `
        -ResourceGroupName $ResourceGroupName `
        -DashboardName $dashboardName `
        -Location $Location `
        -BodyAsJson $dashboardJson
}

# Setup Auto-scaling for Container Instances using Azure Functions
function SetupAutoScaling {
    param( [string]$ResourceGroupName,
           [string]$Location,
           [string]$StorageAccountName,
           [string]$ShareName,
           [PSCredential]$StorageCredentials )
    
    # Create storage account for function app if it doesn't exist
    $functionStorageAccount = Get-AzStorageAccount `
        -ResourceGroupName $ResourceGroupName `
        -Name ($StorageAccountName + "func") `
        -ErrorAction SilentlyContinue
    
    if ($functionStorageAccount -eq $null) {
        $functionStorageAccount = New-AzStorageAccount `
            -ResourceGroupName $ResourceGroupName `
            -Name ($StorageAccountName + "func") `
            -SkuName Standard_LRS `
            -Location $Location `
            -Kind StorageV2
    }
    
    # Create App Service Plan
    $appServicePlan = Get-AzAppServicePlan `
        -ResourceGroupName $ResourceGroupName `
        -Name "minecraft-autoscale-plan" `
        -ErrorAction SilentlyContinue
    
    if ($appServicePlan -eq $null) {
        $appServicePlan = New-AzAppServicePlan `
            -ResourceGroupName $ResourceGroupName `
            -Name "minecraft-autoscale-plan" `
            -Location $Location `
            -Tier Standard `
            -WorkerSize Small
    }
    
    # Create Function App
    $functionApp = Get-AzFunctionApp `
        -ResourceGroupName $ResourceGroupName `
        -Name "minecraft-autoscaler" `
        -ErrorAction SilentlyContinue
    
    if ($functionApp -eq $null) {
        $functionApp = New-AzFunctionApp `
            -ResourceGroupName $ResourceGroupName `
            -Name "minecraft-autoscaler" `
            -Location $Location `
            -StorageAccountName $functionStorageAccount.Name `
            -Runtime PowerShell `
            -RuntimeVersion 7.0 `
            -FunctionsVersion 3 `
            -OSType Windows `
            -AppServicePlan $appServicePlan.Name
        
        # Add application settings
        Update-AzFunctionAppSetting `
            -ResourceGroupName $ResourceGroupName `
            -Name "minecraft-autoscaler" `
            -AppSetting @{
                "RESOURCE_GROUP" = $ResourceGroupName;
                "STORAGE_ACCOUNT" = $StorageAccountName;
                "STORAGE_SHARE" = $ShareName;
                "MAX_INSTANCES" = 5;
                "MIN_INSTANCES" = 1;
                "SCALE_UP_THRESHOLD" = 80;
                "SCALE_DOWN_THRESHOLD" = 20;
                "SCALE_INTERVAL_MINUTES" = 5
            }
    }
    
    # Create timer-triggered function for auto-scaling
    $functionCode = @"
# Auto-scaling function for Minecraft server
# Runs every 5 minutes to check player count and scale accordingly

param(`$Timer)

# Get settings
`$resourceGroup = `$env:RESOURCE_GROUP
`$maxInstances = [int]`$env:MAX_INSTANCES
`$minInstances = [int]`$env:MIN_INSTANCES
`$scaleUpThreshold = [int]`$env:SCALE_UP_THRESHOLD
`$scaleDownThreshold = [int]`$env:SCALE_DOWN_THRESHOLD

# Connect to Azure
Connect-AzAccount -Identity

# Get current container instances
`$containerGroups = Get-AzContainerGroup -ResourceGroupName `$resourceGroup

# Count active instances
`$activeInstances = `$containerGroups | Where-Object { `$_.State -eq 'Running' } | Measure-Object | Select-Object -ExpandProperty Count

# Get player count from Minecraft server logs
function Get-PlayerCount {
    param([string]`$ContainerGroupName)
    
    `$logs = Get-AzContainerInstanceLog -ResourceGroupName `$resourceGroup -ContainerGroupName `$ContainerGroupName -ContainerName (`$ContainerGroupName -replace '-cg', '')
    
    # Parse logs to find player count - this is a simplified example
    if (`$logs -match "There are (\d+) of a max of \d+ players online") {
        return [int]`$Matches[1]
    }
    
    return 0
}

# Get average player count across all instances
`$totalPlayers = 0
`$containerGroups | ForEach-Object {
    `$totalPlayers += Get-PlayerCount -ContainerGroupName `$_.Name
}

`$avgPlayerPercentage = if (`$activeInstances -gt 0) { (`$totalPlayers / (`$activeInstances * 20)) * 100 } else { 0 }

# Scale logic
if (`$avgPlayerPercentage -gt `$scaleUpThreshold -and `$activeInstances -lt `$maxInstances) {
    # Scale up - start a stopped instance
    `$stoppedInstance = `$containerGroups | Where-Object { `$_.State -ne 'Running' } | Select-Object -First 1
    
    if (`$stoppedInstance) {
        Start-AzContainerGroup -ResourceGroupName `$resourceGroup -Name `$stoppedInstance.Name
        Write-Output "Scaling up: Started container group `$(`$stoppedInstance.Name)"
    }
}
elseif (`$avgPlayerPercentage -lt `$scaleDownThreshold -and `$activeInstances -gt `$minInstances) {
    # Scale down - stop an instance with fewest players
    `$instanceToStop = `$null
    `$minPlayers = 999
    
    `$containerGroups | Where-Object { `$_.State -eq 'Running' } | ForEach-Object {
        `$playerCount = Get-PlayerCount -ContainerGroupName `$_.Name
        if (`$playerCount -lt `$minPlayers) {
            `$minPlayers = `$playerCount
            `$instanceToStop = `$_
        }
    }
    
    if (`$instanceToStop -and `$minPlayers -eq 0) {
        Stop-AzContainerGroup -ResourceGroupName `$resourceGroup -Name `$instanceToStop.Name
        Write-Output "Scaling down: Stopped container group `$(`$instanceToStop.Name)"
    }
}

Write-Output "Auto-scaling check completed. Active instances: `$activeInstances, Avg player percentage: `$avgPlayerPercentage%"
"@
    
    # Create function.json for timer trigger
    $functionJson = @"
{
  "bindings": [
    {
      "name": "Timer",
      "type": "timerTrigger",
      "direction": "in",
      "schedule": "0 */5 * * * *"
    }
  ]
}
"@
    
    # Create a zip file with the function code
    $tempFolder = Join-Path $env:TEMP "MinecraftAutoScaler"
    $functionFolder = Join-Path $tempFolder "AutoScaleTimer"
    
    if (Test-Path $tempFolder) {
        Remove-Item $tempFolder -Recurse -Force
    }
    
    New-Item -ItemType Directory -Path $functionFolder -Force | Out-Null
    
    Set-Content -Path (Join-Path $functionFolder "run.ps1") -Value $functionCode
    Set-Content -Path (Join-Path $functionFolder "function.json") -Value $functionJson
    
    $zipFile = Join-Path $env:TEMP "MinecraftAutoScaler.zip"
    if (Test-Path $zipFile) {
        Remove-Item $zipFile -Force
    }
    
    Compress-Archive -Path $tempFolder -DestinationPath $zipFile
    
    # Deploy the function
    Publish-AzWebapp -ResourceGroupName $ResourceGroupName -Name "minecraft-autoscaler" -ArchivePath $zipFile -Force
    
    Write-Host "Auto-scaling function deployed successfully"
}

# Setup main resources
$storageAccountName = "continominecraft837464"
$shareName = "minecraft"

# Setup Log Analytics workspace
$logWorkspace = SetupLogging `
    -ResourceGroupName $resourceGroupName `
    -WorkspaceName "minecraft-logs" `
    -Location $location

$storageAccountCredentials = SetupStorage `
    -StorageResourceGroupName $resourceGroupName `
    -StorageAccountName $storageAccountName `
    -ShareName $shareName `
    -Location $location

# Deploy multiple container instances across availability zones
$containerResourceIds = @()
$trafficManagerEndpoints = @()

# Define zones and regions for high availability
$deploymentZones = @(
    @{ Name = "primary-zone1"; Location = $location; Zone = "1"; DnsPrefix = "minecraft-primary-z1" },
    @{ Name = "primary-zone2"; Location = $location; Zone = "2"; DnsPrefix = "minecraft-primary-z2" },
    @{ Name = "secondary"; Location = $secondaryLocation; Zone = $null; DnsPrefix = "minecraft-secondary" }
)

foreach ($deployment in $deploymentZones) {
    $containerGroupName = "minecraft-" + $deployment.Name + "-cg"
    $containerName = "minecraft-" + $deployment.Name
    $dnsNameLabel = $deployment.DnsPrefix
    
    $volume = New-AzContainerGroupVolumeObject -Name "data" -AzureFileShareName $shareName -AzureFileStorageAccountName $storageAccountCredentials.UserName -AzureFileStorageAccountKey $storageAccountCredentials.Password
    $volumeMount = New-AzContainerInstanceVolumeMountObject -Name "data" -MountPath "/data"
    $port = New-AzContainerInstancePortObject -Port 25565 -Protocol TCP
    
    # Environment variables for the container
    $env1 = New-AzContainerInstanceEnvironmentVariableObject -Name "EULA" -Value "TRUE"
    $env2 = New-AzContainerInstanceEnvironmentVariableObject -Name "OPS" -Value "RichT3802"
    $env3 = New-AzContainerInstanceEnvironmentVariableObject -Name "MEMORY" -Value "2G"
    $env4 = New-AzContainerInstanceEnvironmentVariableObject -Name "JVM_XX_OPTS" -Value "-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1"
    $env5 = New-AzContainerInstanceEnvironmentVariableObject -Name "ENABLE_AUTOPAUSE" -Value "FALSE" # Disable autopause for HA
    # Add environment variable for logging
    $env6 = New-AzContainerInstanceEnvironmentVariableObject -Name "ENABLE_RCON" -Value "true"
    $env7 = New-AzContainerInstanceEnvironmentVariableObject -Name "RCON_PASSWORD" -Value (New-Guid).ToString()
    $env8 = New-AzContainerInstanceEnvironmentVariableObject -Name "ENABLE_QUERY" -Value "true"
    
    $container = New-AzContainerInstanceObject `
        -Name $containerName `
        -Image "itzg/minecraft-server:latest" `
        -VolumeMount $volumeMount `
        -Port @($port) `
        -EnvironmentVariable @($env1, $env2, $env3, $env4, $env5, $env6, $env7, $env8) `
        -Cpu 2 `
        -MemoryInGB 4 `
        -RestartPolicy "Always"
    
    # Add Log Analytics integration
    $containerGroupDiagnostics = New-AzContainerGroupDiagnosticsObject `
        -LogAnalytics `
        -WorkspaceId $logWorkspace.CustomerId `
        -WorkspaceKey (Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $resourceGroupName -Name $logWorkspace.Name).PrimarySharedKey
    
    $containerGroupParams = @{
        ResourceGroupName = $resourceGroupName
        Name = $containerGroupName
        Location = $deployment.Location
        Volume = $volume
        Container = $container
        IpAddressType = "Public"
        OsType = "Linux"
        IPAddressDnsNameLabel = $dnsNameLabel
        RestartPolicy = "Always"
        DiagnosticsObject = $containerGroupDiagnostics
    }
    
    # Add zone parameter if specified
    if ($deployment.Zone -ne $null) {
        $containerGroupParams.Add("Zone", $deployment.Zone)
    }
    
    # Create the container group
    $containerGroup = New-AzContainerGroup @containerGroupParams
    
    # Add to resource IDs for monitoring
    $containerResourceIds += $containerGroup.Id
    
    # Add to Traffic Manager endpoints
    $fqdn = $containerGroup.IpAddress.Fqdn
    $trafficManagerEndpoints += @{
        Name = $deployment.Name
        Target = $fqdn
        Location = $deployment.Location
    }
}

# Setup Traffic Manager
SetupTrafficManager `
    -ResourceGroupName $resourceGroupName `
    -ProfileName "minecraft-tm-profile" `
    -Location $location `
    -Endpoints $trafficManagerEndpoints

# Setup enhanced monitoring
SetupMonitoring `
    -ResourceGroupName $resourceGroupName `
    -Location $location `
    -ResourceIds $containerResourceIds `
    -LogAnalyticsWorkspaceId $logWorkspace.ResourceId

# Setup auto-scaling
SetupAutoScaling `
    -ResourceGroupName $resourceGroupName `
    -Location $location `
    -StorageAccountName $storageAccountName `
    -ShareName $shareName `
    -StorageCredentials $storageAccountCredentials

Write-Host "High Availability Minecraft Server deployment complete!"
Write-Host "Access your Minecraft server via the Traffic Manager DNS: minecraft-ha.trafficmanager.net"
Write-Host "Auto-scaling is enabled and will adjust capacity based on player count"
Write-Host "Enhanced monitoring and logging is available in the Azure Portal"

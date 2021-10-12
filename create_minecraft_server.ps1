
# create a resource group
$resourceGroupName = "contino-minecraft-rg"
$location = "australiaeast"
New-AzResourceGroup -Name $resourceGroupName -Location $location

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
        # create the storage account
        $storageAccount = New-AzStorageAccount `
            -ResourceGroupName $StorageResourceGroupName `
            -Name $StorageAccountName `
            -SkuName Standard_LRS `
            -Location $Location
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
    
    return $storageAccountCredentials
}

$storageAccountName = "continominecraft837464"
$shareName = "minecraft"
$storageAccountCredentials = SetupStorage `
    -StorageResourceGroupName $resourceGroupName `
    -StorageAccountName $storageAccountName `
    -ShareName $shareName `
    -Location $location

$containerGroupName = "minecraft20211012-cg"
$containerName = "minecraft20211012"
$dnsNameLabel = "minecrafttest20211012"
$volume = New-AzContainerGroupVolumeObject -Name "data" -AzureFileShareName $shareName -AzureFileStorageAccountName $storageAccountCredentials.UserName -AzureFileStorageAccountKey $storageAccountCredentials.Password
$volumeMount = New-AzContainerInstanceVolumeMountObject -Name "data" -MountPath "/data"
$port = New-AzContainerInstancePortObject -Port 25565 -Protocol TCP
$env1 = New-AzContainerInstanceEnvironmentVariableObject -Name "EULA" -Value "TRUE"
$env2 = New-AzContainerInstanceEnvironmentVariableObject -Name "OPS" -Value "RichT3802"

$container = New-AzContainerInstanceObject `
    -Name $containerGroupName `
    -Image "itzg/minecraft-server" `
    -VolumeMount $volumeMount `
    -Port @($port) `
    -EnvironmentVariable @($env1, $env2)

New-AzContainerGroup `
    -ResourceGroupName $resourceGroupName `
    -Name $containerGroupName `
    -Location $location `
    -Volume $volume `
    -Container $container `
    -IpAddressType Public `
    -OsType Linux `
    -IPAddressDnsNameLabel $dnsNameLabel
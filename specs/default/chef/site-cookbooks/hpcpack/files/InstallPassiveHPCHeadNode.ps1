<#
    The script to install HPC Pack passive head node
    Author :  Microsoft HPC Pack team
    Version:  1.0
#>
Param
(
    [parameter(Mandatory = $true)]
    [string] $PassiveHeadNode,

    [parameter(Mandatory = $true, ParameterSetName='SSLThumbprint')]
    [string] $SSLThumbprint,

    [parameter(Mandatory = $true, ParameterSetName='PfxFilePath')]
    [string] $PfxFilePath,

    [parameter(Mandatory = $true, ParameterSetName='PfxFilePath')]
    [securestring] $PfxFilePassword,

    [parameter(Mandatory = $true, ParameterSetName='KeyVaultCertificate')]
    [string] $VaultName,

    [parameter(Mandatory = $true, ParameterSetName='KeyVaultCertificate')]
    [string] $VaultCertName,

    [parameter(Mandatory = $false)]
    [string] $SetupFilePath = ""

)
##wait first head node
Write-Host "waiting for installation of first headnode"
$created = $null
while($null -eq $created){
    $remoteKeys = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey("LocalMachine", $PassiveHeadNode)
    $remoteKey = $remoteKeys.opensubkey("SOFTWARE\Microsoft\HPC")
    if($null -ne $remoteKey){
        $created = $remoteKey.getValue("created")
    }
}
Write-Host "installation of first head node has been done"


# Must disable Progress bar
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"
Set-StrictMode -Version latest
Import-Module $PSScriptRoot\InstallUtilities.psm1
$logFolder = "C:\Windows\Temp\HPCSetupLogs"
if(-not (Test-Path $logFolder))
{
    New-Item -Path $logFolder -ItemType Directory -Force
}
$logfileName = "installphn-" + [System.DateTimeOffset]::UtcNow.ToString("yyyyMMdd-HHmmss") + ".txt"
Set-LogFile -Path "$logFolder\$logfileName"

$cmdLine = $PSCommandPath
foreach($boundParam in $PSBoundParameters.GetEnumerator())
{
    if($boundParam.Key -notmatch 'Password' -and $boundParam.Key -notmatch 'Credential') {
        $cmdLine += " -$($boundParam.Key) $($boundParam.Value)"
    }
}
Write-Log $cmdLine

if(-not $SetupFilePath)
{    
    if(Test-Path "C:\HPCPack2019\Setup.exe" -PathType Leaf) 
    {
        $SetupFilePath = "C:\HPCPack2019\Setup.exe"
    }
    elseif (Test-Path "C:\HPCPack2016\Setup.exe" -PathType Leaf) 
    {
        $SetupFilePath = "C:\HPCPack2016\Setup.exe"
    }
    else
    {
        Write-Log "Cannot found HPC Pack setup package" -LogLevel Error
    }
}
elseif (!(Test-Path -Path $SetupFilePath -PathType Leaf)) 
{
    Write-Log "HPC Pack setup package not found: $SetupFilePath" -LogLevel Error
}

### Import the certificate
if($PsCmdlet.ParameterSetName -eq "PfxFilePath")
{
    if (!(Test-Path -Path $PfxFilePath -PathType Leaf)) 
    {
        Write-Log "The PFX certificate file doesn't exist: $PfxFilePath" -LogLevel Error
    }
    try {
        $pfxCert = Import-PfxCertificate -FilePath $PfxFilePath -Password $PfxFilePassword -CertStoreLocation Cert:\LocalMachine\My -Exportable
        $SSLThumbprint = $pfxCert.Thumbprint        
    }
    catch {
        Write-Log "Failed to import PfxFile $PfxFilePath : $_" -LogLevel Error
    }
}
elseif($PsCmdlet.ParameterSetName -eq "KeyVaultCertificate")
{
    Write-Log "Install certificate $VaultCertName from key vault $VaultName"
    try {
        $pfxCert = Install-KeyVaultCertificate -VaultName $VaultName -CertName $VaultCertName -CertStoreLocation Cert:\LocalMachine\My -Exportable
        $SSLThumbprint = $pfxCert.Thumbprint        
    }
    catch {
        Write-Log "Failed to install certificate $VaultCertName from key vault $VaultName : $_" -LogLevel Error
    }
}
else 
{
    $pfxCert = Get-Item Cert:\LocalMachine\My\$SSLThumbprint -ErrorAction SilentlyContinue
    if($null -eq $pfxCert)
    {
        Write-Log "The certificate Cert:\LocalMachine\My\$SSLThumbprint doesn't exist" -LogLevel Error
    }    
}

if($pfxCert.Subject -eq $pfxCert.Issuer)
{
    if(-not (Test-Path Cert:\LocalMachine\Root\$SSLThumbprint))
    {
        Write-Log "Installing self-signed HPC communication certificate to Cert:\LocalMachine\Root\$SSLThumbprint"
        $cerFileName = "$env:Temp\HpcPackComm.cer"
        Export-Certificate -Cert "Cert:\LocalMachine\My\$SSLThumbprint" -FilePath $cerFileName | Out-Null
        Import-Certificate -FilePath $cerFileName -CertStoreLocation Cert:\LocalMachine\Root  | Out-Null
        Remove-Item $cerFileName -Force -ErrorAction SilentlyContinue
    }
}


##判断hpc版本
$hpcVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($SetupFilePath)
if($hpcVersion.FileVersionRaw -lt '5.3')
{
    Write-Log "The HPC Pack version $($hpcVersion.FileVersionRaw) is not supported." -LogLevel Error
}


$setupArgs = "-unattend -Quiet -PassiveHeadNode:$PassiveHeadNode -SSLThumbprint:$SSLThumbprint"



$retry = 0
$maxRetryTimes = 20
$maxRetryInterval = 60
$exitCode = 1
while($true)
{
    Write-Log "Installing HPC Pack Head Node"
    $p = Start-Process -FilePath $SetupFilePath -ArgumentList $setupArgs -PassThru -Wait
    $exitCode = $p.ExitCode
    if($exitCode -eq 0)
    {
        Write-Log "Succeed to Install HPC Pack Head Node"
        break
    }
    if($exitCode -eq 3010)
    {
        $exitCode = 0
        Write-Log "Succeed to Install HPC Pack Head Node, a reboot is required."
        break
    }

    if($retry++ -lt $maxRetryTimes)
    {
        $retryInterval = [System.Math]::Min($maxRetryInterval, $retry * 10)
        Write-Warning "Failed to Install HPC Pack Head Node (errCode=$exitCode), retry after $retryInterval seconds..."            
        Clear-DnsClientCache
        Start-Sleep -Seconds $retryInterval
    }
    else
    {
        if($exitCode -eq 13818)
        {
            Write-Log "Failed to Install HPC Pack Head Node (errCode=$exitCode): the certificate doesn't meet the requirements." -LogLevel Error
        }
        else
        {
            Write-Log "Failed to Install HPC Pack Head Node (errCode=$exitCode)" -LogLevel Error
        }
    }
}
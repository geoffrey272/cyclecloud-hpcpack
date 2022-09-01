$created = $null
$firstHeadNode = "HAHN01"
while($null -eq $created){
    $remoteKeys = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey("LocalMachine", $firstHeadNode)
    $remoteKey = $remoteKeys.opensubkey("SOFTWARE\Microsoft\HPC")
    $created = $remoteKey.getValue("created")
    wirte-host "wait ...."
}
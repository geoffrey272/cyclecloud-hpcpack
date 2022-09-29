include_recipe "hpcpack::_get_secrets"
include_recipe "hpcpack::_common"
include_recipe "hpcpack::_find-hn"
include_recipe "hpcpack::_join-ad-domain" if node['hpcpack']['headNodeAsDC'] == false
include_recipe "hpcpack::_new-ad-domain" if node['hpcpack']['headNodeAsDC']

install_dir = "C:\\Program Files\\Microsoft HPC Pack 2019\\Data\\InstallShare"
bootstrap_dir = node['cyclecloud']['bootstrap']
connectionstring = node['connectionstring']

cookbook_file "#{bootstrap_dir}\\InstallPassiveHPCHeadNode.ps1" do
  source "InstallPassiveHPCHeadNode.ps1"
  action :create
end

powershell_script "Ensure TLS 1.2 for nuget" do
  code <<-EOH
  Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\.NetFramework\\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -Type DWord
  if(Test-Path 'HKLM:\\SOFTWARE\\Wow6432Node\\Microsoft\\.NetFramework\\v4.0.30319')
  {
    Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Wow6432Node\\Microsoft\\.NetFramework\\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -Type DWord
  }
  EOH
  not_if <<-EOH
    $strongCrypo = Get-ItemProperty "HKLM:\\SOFTWARE\\Microsoft\\.NetFramework\\v4.0.30319" -ErrorAction SilentlyContinue | Select -Property SchUseStrongCrypto
    $strongCrypo -and ($strongCrypo.SchUseStrongCrypto -eq 1)
  EOH
end

# Get the nuget binary as well
# first try jetpack download, then resort to web download (nuget is not part of the HPC Pack project release)
jetpack_download "try_fetch_nuget_from_locker" do
  project "hpcpack"
  dest "#{node[:cyclecloud][:home]}/bin/nuget.exe"
  ignore_failure true
  not_if { ::File.exists?("#{node[:cyclecloud][:home]}/bin/nuget.exe") }
end


ruby_block "try_fetch_nuget_from_web" do
  block do
    require 'open-uri'
    download = open('https://aka.ms/nugetclidl')
    IO.copy_stream(download, "#{node[:cyclecloud][:home]}/bin/nuget.exe")
  end
  not_if { ::File.exists?("#{node[:cyclecloud][:home]}/bin/nuget.exe") }
end

powershell_script "Install-NuGet" do
    code <<-EOH
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    EOH
    only_if <<-EOH
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      !(Get-PackageProvider NuGet -ListAvailable)
    EOH
end


powershell_script 'Install-HpcHAHeadNode' do
    code <<-EOH
    $vaultName = "#{node['hpcpack']['keyvault']['vault_name']}"
    $vaultCertName = "#{node['hpcpack']['keyvault']['cert']['cert_name']}"
    if($vaultName -and $vaultCertName) {
      #{bootstrap_dir}\\InstallPassiveHPCHeadNode.ps1 -PassiveHeadNode '#{node['clustername']}'  -VaultName $vaultName -VaultCertName $vaultCertName
    }
    else {
      #{bootstrap_dir}\\InstallPassiveHPCHeadNode.ps1 -PassiveHeadNode '#{node['clustername']}'  -PfxFilePath "#{node['jetpack']['downloads']}\\#{node['hpcpack']['cert']['filename']}" -PfxFilePassword $seccertpasswd
    }
    EOH
    user "#{node['hpcpack']['ad']['domain']}\\#{node['hpcpack']['ad']['admin']['name']}"
    password "#{node['hpcpack']['ad']['admin']['password']}"
    elevated true
    not_if 'Get-Service "HpcManagement"  -ErrorAction SilentlyContinue'
end

powershell_script 'Copy-HpcPackShareDir' do
  code  <<-EOH
  $reminst = "\\\\#{node['hpcpack']['hn']['hostname']}\\REMINST"
  $retry = 0
  While($true) {
    if(Test-Path "$reminst\\LinuxNodeAgent") {
      New-Item "#{install_dir}\\LinuxNodeAgent" -ItemType Directory -Force
      Copy-Item -Path "$reminst\\LinuxNodeAgent\\*" -Destination "#{install_dir}\\LinuxNodeAgent" -Force
      New-Item "#{install_dir}\\amd64" -ItemType Directory -Force
      New-Item "#{install_dir}\\i386" -ItemType Directory -Force
      New-Item "#{install_dir}\\MPI" -ItemType Directory -Force
      New-Item "#{install_dir}\\Setup" -ItemType Directory -Force
      Copy-Item -Path "$reminst\\amd64\\*" -Destination "#{install_dir}\\amd64" -Force
      Copy-Item -Path "$reminst\\i386\\vcredist_x86.exe" -Destination "#{install_dir}\\i386\\" -Force
      Copy-Item -Path "$reminst\\MPI\\*" -Destination "#{install_dir}\\MPI" -Force
      Copy-Item -Path "$reminst\\Setup\\*" -Destination "#{install_dir}\\Setup" -Recurse -Force -Exclude @('*_x86.msi', 'HpcKsp*')
      Copy-Item -Path "$reminst\\Setup.exe" -Destination "#{install_dir}" -Force
      break
    }
    elseif($retry++ -lt 50) {
      start-sleep -seconds 20
    }
    else {
      throw "head node not available"
    }
  }
  EOH
  not_if { ::File.exists?("#{install_dir}/LinuxNodeAgent")}
end

powershell_script 'Share-LinuxNodeAgent' do
  code  <<-EOH
    $ShareName = 'REMINST'
    $Path = "#{install_dir}"
    If (!(Get-WmiObject -Class Win32_Share -Filter "name='$ShareName'"))
    {
        $Shares = [WMICLASS]"WIN32_Share"
        $Shares.Create($Path,$ShareName,0).ReturnValue
    }
  EOH
end


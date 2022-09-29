bootstrap_dir = node['cyclecloud']['bootstrap']

cookbook_file "#{bootstrap_dir}/keyvault_get_secret.py" do
  source "keyvault_get_secret.py"
  action :create
end

# Lookup the AD Admin and Cert creds in KeyVault (if present)
if ! node['hpcpack']['keyvault']['vault_name'].nil?
  Chef::Log.info( "Looking up secrets in vault: #{node['hpcpack']['keyvault']['vault_name']}..." )

  if ! node['hpcpack']['keyvault']['admin']['password_key'].nil?
    admin_pass = HPCPack::Helpers.keyvault_get_secret(node['hpcpack']['keyvault']['vault_name'], node['hpcpack']['keyvault']['admin']['password_key'])
    if admin_pass.to_s.empty?
      raise "Error: AD Admin Password not set in #{node['hpcpack']['keyvault']['vault_name']} with key #{node['hpcpack']['keyvault']['admin']['password_key']}"
    end

    node.default['hpcpack']['ad']['admin']['password'] = admin_pass
    node.override['hpcpack']['ad']['admin']['password'] = admin_pass
  end
end
Chef::Log.info( "Using AD Admin: #{node['hpcpack']['ad']['admin']['name']} ..." )

domain=node['hpcpack']['ad']['domain']
headnodename=node['clustername']
connectionstring=node['connectionstring']
install_file='hpcnodeagent.tar.gz'
mount_dir = '/smbshare'

directory "#{mount_dir}" do
  user "root"
  group "root"
  mode '0777'
  recursive true
end

cookbook_file "#{bootstrap_dir}/setup.py" do
  source "setup.py"
  action :create
end

if ! node['hpcpack']['cert']['filename'].nil?
  jetpack_download node['hpcpack']['cert']['filename'] do
    project "hpcpack"
    not_if { ::File.exists?("#{node['jetpack']['downloads']}/#{node['hpcpack']['cert']['filename']}") }
  end
end

case node[:platform_family]
when 'ubuntu', 'debian'
    execute 'update' do
        command "apt-get update"
    end
end

execute 'add domain' do
    command "echo search #{domain}>>/etc/resolv.conf"
    notifies :run, 'execute[add private nameserver]', :delayed
end
execute 'add private nameserver' do
    command "echo nameserver 10.0.0.4>>/etc/resolv.conf"
    action :nothing
    notifies :run, 'bash[extract_module]', :delayed
end


bash 'extract_module' do
  code <<-EOH
    IFS=','
    read -ra strArr <<<#{connectionstring}
    for node in "${strArr[@]}";
    do
    ping -c 3 $node
    if [ $? -eq 0 ]; then
    mount -t cifs //$node/REMINST/LinuxNodeAgent #{mount_dir} -o vers=2.1,domain=#{domain},username=#{node['hpcpack']['ad']['admin']['name']},password='#{node['hpcpack']['ad']['admin']['password']}',dir_mode=0777,file_mode=0777
    fi
    done
  EOH
  action :nothing
  notifies :run, 'execute[copy file]', :delayed
end

execute 'copy file' do
    command "cp #{mount_dir}/#{install_file} #{bootstrap_dir}/#{install_file}"
    action:nothing
    notifies :run, 'execute[setup by keyvault]', :delayed
    notifies :run, 'execute[setup by pfxfile]', :delayed
end

execute 'setup by pfxfile' do
    command "python3 #{bootstrap_dir}/setup.py -install -connectionstring:#{connectionstring} -certfile:#{node['jetpack']['downloads']}/#{node['hpcpack']['cert']['filename']} -certpasswd:#{node['hpcpack']['cert']['password']}"
    action :nothing
    only_if {node['hpcpack']['cert']['filename']&&node['hpcpack']['cert']['password']}
end

execute 'setup by keyvault' do
    command "python3 #{bootstrap_dir}/setup.py -install -connectionstring:#{connectionstring} -keyvault:#{node['hpcpack']['keyvault']['vault_name']} -certname:#{node['hpcpack']['keyvault']['cert']['cert_name']}"
    action :nothing
    only_if {node['hpcpack']['keyvault']['vault_name'] && node['hpcpack']['keyvault']['cert']['cert_name']}
end









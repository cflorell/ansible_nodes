# Vagrant.configure("2") do |config|
#   config.vm.define 'debian-test'
#   config.vm.box = "debian/bookworm64"
#   config.ssh.insert_key = false
#   config.vm.provision "ansible" do |ansible|
#     ansible.verbose = "vv"
#     ansible.groups = { 
#       "server" => { "server" => ["server-test"] }
#     }
#     ansible.playbook = "local.yml"
#     end
# end

HOST_CONFIG = {
#  'debian-test' => 'debian/bookworm64',
  'ubuntu-test' => 'generic/ubuntu2204',
#  'arch-test' => 'archlinux/archlinux'
}

Vagrant.configure("2") do |config|
  HOST_CONFIG.each do |hostname, basebox|
    config.vm.define hostname do |hname|
      hname.vm.box = basebox
      hname.vm.provider 'libvirt' do |v|
          v.memory = 2048
          v.cpus = 4
        end
      end
    end
  config.ssh.insert_key = false
  config.vm.provision "ansible" do |ansible|
    ansible.galaxy_role_file = 'requirements.yml'
    ansible.verbose = "vv"
    ansible.groups = { "workstation" => ["workstation-test"] }
    ansible.playbook = "playbooks/playbook.yml"
  end
end


HOST_CONFIG = {
  'arch-test' => 'archlinux',
  'fedora-test' => 'fedora44',
  'ubuntu-test' => 'ubuntu2604',
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
    ansible.groups = { "workstation" => ["arch-test", "fedora-test", "ubuntu-test"] }
    ansible.playbook = "playbooks/playbook.yml"
  end
end


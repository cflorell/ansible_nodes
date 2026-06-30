# Ansible Nodes

Ansible configuration for my homelab made up of Proxmox hosts, virtual nodes,
and workstation machines.

This repository is intended to be public. Real inventory, Ansible Vault data,
VPN provider files, and other local infrastructure details are kept outside the
repository and linked in from a private secrets repository.2

The overall structure of project is influenced by numerous other Ansbile homelab projects
scattered across the web.
The project was for a long time private on Github. With the help of LLMs, this project is now
public with sensitive information and secrets stored in a private repository.

## What this project manages

The main playbook configures three broad host types:

- `server` and `nodes`: Proxmox hosts and server VMs/LXCs.
- `kubernetes`: kubeadm-managed control plane and worker VMs.
- `workstation`: desktop or laptop machines.
- `all`: common base system configuration shared across hosts.

`ansible.cfg` uses `inventory/hosts` as the default inventory file. The real
`inventory/hosts` file is private and ignored by Git.

`inventory/proxmox.yml.example` is an example dynamic inventory for Proxmox via
the `community.proxmox.proxmox` inventory plugin. Use it when you want Ansible
to discover Proxmox guests from the Proxmox API instead of maintaining every
host manually.

## Requirements

Install Ansible and the required collections:

```bash
python3 -m pip install --user ansible ansible-lint
ansible-galaxy collection install -r requirements.yml
```

Optional local testing with Vagrant also needs a working Vagrant/libvirt setup:
https://developer.hashicorp.com/vagrant/install?product_intent=vagrant

## Private files

For a new setup, create them from the public examples:

```bash
cp inventory/hosts.example inventory/hosts
cp inventory/proxmox.yml.example inventory/proxmox.yml
cp secrets.vault.example secrets.vault
```

For the private-repo workflow, store the real files in a private repository with
this layout:

```text
secrets/
`-- ansible_nodes/
    |-- secrets.vault
    |-- inventory/
    |   |-- hosts
    |   `-- proxmox.yml
    ..etc..
```

Then link the private files into this checkout:

```bash
scripts/link-private-files.sh --secrets-dir ../private/secrets
scripts/link-private-files.sh --secrets-dir ../private/secrets --check
```

For use across multiple PCs, set a stable environment variable instead:

```bash
export HOMELAB_SECRETS_DIR="$HOME/git_private/homelab-secrets"
scripts/link-private-files.sh --check
```

Use `--adopt` only when the current local files are the source of truth and need
to be copied into the private repository:

```bash
scripts/link-private-files.sh --secrets-dir ../private/secrets --adopt
```

## Running playbooks

Run the full configuration for one host:

```bash
ansible-playbook playbooks/playbook.yml --ask-vault-pass --limit docker
```

Run all server nodes:

```bash
ansible-playbook playbooks/playbook.yml --ask-vault-pass --limit nodes
```

Run only one tagged area:

```bash
ansible-playbook playbooks/playbook.yml --ask-vault-pass --limit torrent --tags node-torrent
ansible-playbook playbooks/playbook.yml --ask-vault-pass --limit docker --tags docker,node-docker
ansible-playbook playbooks/playbook.yml --ask-vault-pass --limit runner --tags runner
ansible-playbook playbooks/playbook.yml --ask-vault-pass --limit kubernetes --tags kubernetes
ansible-playbook playbooks/playbook.yml --ask-vault-pass --limit workstation-test --tags workstation
```

The `runner` role registers a GitLab shell runner. Set `gitlab_runner_url` and
`gitlab_runner_token` in `secrets.vault` before the first runner provision.
The Proxmox host also needs nested virtualization enabled; Terraform configures
the runner VM with host CPU passthrough.

Update Debian and Ubuntu server packages:

```bash
ansible-playbook playbooks/update_servers.yml --ask-become-pass
```

## Useful checks

List matched hosts before running a playbook:

```bash
ansible-inventory --list
ansible all --list-hosts
ansible server --list-hosts
```

Check syntax:

```bash
ansible-playbook playbooks/playbook.yml --syntax-check --ask-vault-pass
ansible-playbook playbooks/update_servers.yml --syntax-check
```

Run Ansible lint:

```bash
ansible-lint
```

## Git hooks

Install the project hooks in this checkout:

```bash
git config core.hooksPath .githooks
```

The hooks are local to your clone. They are versioned in this repository, but
Git will not use them until `core.hooksPath` is configured.

`pre-commit` blocks accidental commits of private files such as real inventories,
Vault files, VPN configs, SSH keys, certificates, and `.env` files.

`pre-push` runs the local sanity checks:

- Shows `git status --short --ignored`.
- Verifies private files are linked from the private secrets repository.

The `pre-push` hook is noninteractive. If `secrets.vault` is encrypted, configure
a local vault password file before pushing:

```bash
export ANSIBLE_VAULT_PASSWORD_FILE="$HOME/.config/ansible/homelab-vault-pass"
```

If your private secrets repository is not at `../private/secrets`, set:

```bash
export HOMELAB_SECRETS_DIR="$HOME/git_private/homelab-secrets"
```

For a one-off bypass:

```bash
SKIP_PRIVATE_LINK_CHECK=1 git push
```

## Vagrant testing

The included `Vagrantfile` can provision a local `workstation-test` host:

```bash
sudo apt install libvirt-dev ruby-libvirt qemu-system libvirt-daemon-system libvirt-clients ebtables dnsmasq-base libxslt-dev libxml2-dev zlib1g-dev ruby-dev libguestfs-tools build-essential
vagrant plugin install vagrant-libvirt
VAGRANT_DISABLE_STRICT_DEPENDENCY_ENFORCEMENT=1 vagrant plugin install vagrant-libvirt
vagrant up
vagrant provision
vagrant destroy
```

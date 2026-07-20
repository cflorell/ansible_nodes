# Ansible Nodes

Ansible configuration for my homelab made up of Proxmox hosts, virtual nodes,
and workstation machines.

This repository is intended to be public. Real inventory, SOPS-encrypted secrets,
VPN provider files, and other local infrastructure details are kept outside the
repository and linked in from a private secrets repository.

The overall structure of the project is influenced by numerous other Ansible
homelab projects scattered across the web. The project was for a long time
private on GitHub; it is now public, with sensitive information and secrets
stored in a separate private repository.

## What this project manages

The main playbook configures three broad host types:

- `server` and `nodes`: Proxmox hosts and server VMs/LXCs.
- `kubernetes`: kubeadm-managed control plane and worker VMs.
- `workstation`: desktop or laptop machines.
- `all`: common base system configuration shared across hosts.

`ansible.cfg` uses `inventory/hosts` as the default inventory file. The real
`inventory/hosts` file is private and ignored by Git.

`inventory/proxmox.yml.example` is an example dynamic inventory for Proxmox via
the `community.proxmox.proxmox` inventory plugin, useful for having Ansible
discover Proxmox guests from the Proxmox API instead of maintaining every
host manually.

## Requirements

Install Ansible and the required collections:

```bash
python3 -m pip install --user ansible -r requirements-lint.txt
ansible-galaxy collection install -r requirements.yml
```

Optional local testing with Vagrant also needs a working Vagrant/libvirt setup:
https://developer.hashicorp.com/vagrant/install?product_intent=vagrant

## Private files

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) using an
[age](https://github.com/FiloSottile/age) key pair rather than Ansible Vault.
`community.sops`'s vars plugin auto-decrypts
`playbooks/group_vars/all/secrets.sops.yaml` in memory at run time (see
`ansible.cfg`'s `vars_plugins_enabled`), so no `--ask-vault-pass` step is
needed. The personal age private key needs to be at
`~/.config/sops/age/keys.txt` (the `workstation` role's `sops` tasks place it
there automatically from the private secrets repo, if present).

For a new setup, create them from the public examples:

```bash
cp inventory/hosts.example inventory/hosts
cp inventory/proxmox.yml.example inventory/proxmox.yml
cp secrets.sops.yaml.example playbooks/group_vars/all/secrets.sops.yaml
```

For the private-repo workflow, store the real files in a private repository with
this layout:

```text
secrets/
`-- ansible_nodes/
    |-- playbooks/
    |   `-- group_vars/
    |       `-- all/
    |           `-- secrets.sops.yaml
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

To edit secrets, use `sops` directly on the linked file (it decrypts to the
configured `$EDITOR`, then re-encrypts on save, the same round trip
`ansible-vault edit` gave before):

```bash
sops playbooks/group_vars/all/secrets.sops.yaml
```

This requires `sops`/`age` installed and the personal age private key at
`~/.config/sops/age/keys.txt`.

## Running playbooks

Run the full configuration for one host:

```bash
ansible-playbook playbooks/playbook.yml --limit docker
```

Run all server nodes:

```bash
ansible-playbook playbooks/playbook.yml --limit nodes
```

Run only one tagged area:

```bash
ansible-playbook playbooks/playbook.yml --limit torrent --tags node-torrent
ansible-playbook playbooks/playbook.yml --limit docker --tags docker,node-docker
ansible-playbook playbooks/playbook.yml --limit runner --tags runner
ansible-playbook playbooks/playbook.yml --limit kubernetes --tags kubernetes
ansible-playbook playbooks/playbook.yml --limit workstation-test --tags workstation
```

### Service registry and monitoring sync

Gatus endpoints, Homepage tiles, the Homelable canvas containers,
whats-up-docker's watcher list and Prometheus' node_exporter targets are all
generated from per-host declarations instead of being maintained by hand
inside each monitoring service's GUI:

- `services:` in `playbooks/host_vars/<host>` — one entry per container in
  that host's compose stack (schema documented in `playbooks/host_vars/docker`).
  Declaring a service there is what puts it on the status page, the dashboard
  and the network map.
- `docker: true` in a host's host_vars puts its docker-socket-proxy on
  whats-up-docker's watch list and gives it a Gatus TCP check.
- `node_exporter: true` installs node_exporter on the host **and** adds it to
  Prometheus' scrape targets.

So adding a new service to an existing node is: add it to the node's
docker-compose template, add a `services:` entry to its host_vars, then deploy
the node with the hub included in the limit:

```bash
ansible-playbook playbooks/playbook.yml --limit media,docker --tags node-media
```

No extra tag is needed: the "Sync monitoring hub" play is tagged `always` and
re-renders gatus/homepage/homelable/whats-up-docker on the `docker` host on
every run that includes it, skipping itself when the server play already did
the work (so full runs don't deploy the hub twice). Ansible cannot reach hosts
outside `--limit`, so if `docker` is left out the run ends with a WARNING that
the hub was not re-rendered. Include `prometheus-grafana` in the limit when
scrape targets changed, i.e. a host gained or lost `node_exporter: true`.
Use `--skip-tags monitoring-sync` to deploy a node without touching the hub.

The `runner` role registers a GitLab shell runner. Set `gitlab_runner_url` and
`gitlab_runner_token` in `secrets.sops.yaml` before the first runner provision.
The Proxmox host also needs nested virtualization enabled; Terraform configures
the runner VM with host CPU passthrough.

Update Debian and Ubuntu server packages:

```bash
ansible-playbook playbooks/update_servers.yml --ask-become-pass
```

## CI (merge request check, manual apply)

Required setup in GitLab (**Settings → CI/CD → Variables**):

- `SOPS_AGE_KEY` — type **Variable**, masked, the private half of an age
  keypair whose public half is a recipient in `private/secrets/.sops.yaml`.
  Do not mark it protected, or MR pipelines will not receive it.

## Useful checks

List matched hosts before running a playbook:

```bash
ansible-inventory --list
ansible all --list-hosts
ansible server --list-hosts
```

Check syntax:

```bash
ansible-playbook playbooks/playbook.yml --syntax-check
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

The hooks are local to each clone. They are versioned in this repository, but
Git will not use them until `core.hooksPath` is configured.

`pre-commit` blocks accidental commits of private files such as real inventories,
SOPS-encrypted secrets, VPN configs, SSH keys, certificates, and `.env` files.

`pre-push` runs the local sanity checks:

- Shows `git status --short --ignored`.
- Verifies private files are linked from the private secrets repository.

The `pre-push` hook is noninteractive and only checks that private files are
linked correctly — it doesn't need to decrypt anything.

If the private secrets repository is not at `../private/secrets`, set:

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

## Molecule testing

Molecule wraps the same arch/fedora/ubuntu Packer boxes used above, but adds a
full test lifecycle per role — `create -> prepare -> converge -> idempotence ->
verify -> destroy` — so it also catches non-idempotent tasks and asserts
post-conditions (things `vagrant up` alone never checked). It uses the
vagrant/libvirt driver (not containers) so systemd/journald/locale/microcode
tasks run with production fidelity.

Scenarios live under `molecule/`:

- `molecule/base/` — applies the `base` role in isolation.
- `molecule/workstation/` — applies the full workstation-host stack
  (`base` + `workstation`), the faithful successor to the old `run_vagrant_*`
  CI jobs.

The scenarios run **without** the private secrets repo: shared non-secret vars
are loaded from `playbooks/group_vars/all/vars.yml`, and the workstation
scenario supplies throwaway stand-ins in `molecule/workstation/vars.yml`
(a dummy `christoffer_password` and a non-existent `homelab_secrets_dir`), so
every secret-dependent task skips via its existing guards.

```bash
python3 -m venv .venv-molecule
.venv-molecule/bin/pip install -r requirements-test.txt
.venv-molecule/bin/ansible-galaxy collection install -r requirements.yml
```

Drive Molecule through `scripts/molecule.sh` rather than calling `molecule`
directly. The wrapper exports `ANSIBLE_LIBRARY` so the vagrant driver's bundled
`vagrant` module resolves — molecule 26 no longer injects it automatically (see
the script header for details). It forwards all arguments to the venv's
`molecule` and honours `MOLECULE_BIN` / `MOLECULE_PYTHON` overrides.

```bash
# Full lifecycle for a scenario (all three distros)
./scripts/molecule.sh test -s base
./scripts/molecule.sh test -s workstation

# Iterating: keep the VMs up between runs
./scripts/molecule.sh converge -s base   # (re-)apply
./scripts/molecule.sh verify   -s base   # run assertions only
./scripts/molecule.sh login    -s base --host ubuntu-test
./scripts/molecule.sh destroy  -s base
```

GitLab CI runs `molecule test` for both scenarios (a `parallel:matrix` over
`MOLECULE_SCENARIO`) on the self-hosted `ansible`/libvirt runner whenever the
`base`/`workstation` roles, `pre_tasks`, or the `molecule/` config change.

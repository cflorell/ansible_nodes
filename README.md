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

- `server` and `nodes`: Proxmox physical hosts and their VM/LXC guests,
  respectively. Both run through the same `docker_host` role (Docker install +
  per-host compose stack deployment), but are tagged distinctly
  `server-<host>` for the physical hosts (`proxmox1`, `proxmox2`, which also
  run their own compose stack directly on the hypervisor), `node-<host>` for
  everything in `nodes` (`docker`, `authentik`, `media`, etc.).
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
[age](https://github.com/FiloSottile/age) key pair.
`community.sops`'s vars plugin auto-decrypts
`playbooks/group_vars/all/secrets.sops.yaml` in memory at run time (see
`ansible.cfg`'s `vars_plugins_enabled`). The personal age private key needs to be at
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

This requires `sops` and `age` installed and the personal age private key at
`~/.config/sops/age/keys.txt`.

## Running playbooks

Run the full configuration for one host:

```bash
ansible-playbook playbooks/playbook.yml --limit docker
```

Run every host in one group, physical Proxmox hosts, or their VM/LXC guests:

```bash
ansible-playbook playbooks/playbook.yml --limit server
ansible-playbook playbooks/playbook.yml --limit nodes
```

Run only one tagged area:

```bash
ansible-playbook playbooks/playbook.yml --limit torrent --tags node-torrent
ansible-playbook playbooks/playbook.yml --limit docker --tags docker,node-docker
ansible-playbook playbooks/playbook.yml --limit proxmox1 --tags server-proxmox1
ansible-playbook playbooks/playbook.yml --limit runner --tags runner
ansible-playbook playbooks/playbook.yml --limit kubernetes --tags kubernetes
ansible-playbook playbooks/playbook.yml --limit vivobook --tags workstation
```

### Service registry and monitoring sync

Gatus endpoints, Homepage tiles, the Homelable canvas containers,
whats-up-docker's watcher list and Prometheus' node_exporter targets are all
generated from per-host declarations instead of being maintained by hand
inside each monitoring service's GUI:

- `services:` in `playbooks/host_vars/<host>`, one entry per container in
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

The "Sync monitoring hub" play is tagged `always` and
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
the runner VM with host CPU passthrough. This runner stays dedicated to CI jobs
that need nested KVM (molecule, the `vagrant_boxes` Packer builds).

The `kubernetes_control` role initializes the kubeadm control plane and
installs cluster addons via `kubectl apply`: the flannel CNI, and
metrics-server (patched to add `--kubelet-insecure-tls`, since kubeadm's
self-signed kubelet certs aren't verifiable the way managed cloud Kubernetes'
are, without it every scrape fails with `x509: certificate signed by unknown
authority`).

The `kubernetes_runner` role (`kubernetes_control` only) installs Helm, applies
a `gitlab-runner` namespace with RBAC scoped to it, and deploys the
`gitlab-runner` Helm chart with the Kubernetes executor for the CI jobs that
don't need nested KVM (everything except molecule and the `vagrant_boxes`
Packer builds, which stay on the `runner` host). Set
`kubernetes_runner_gitlab_token` in `secrets.sops.yaml` before the first
deploy; create it as a group runner under `cf_homelab`, tagged `k8s`
(`kubernetes_runner_tag_list`), so all three CI repos can share it.
`kubernetes_runner_concurrent` and the per-job pod resource requests/limits
default conservatively since proxmox3 (which hosts this cluster) is already
tight on RAM.

```bash
ansible-playbook playbooks/playbook.yml --limit kube-control --tags kubernetes-runner
```

Update Debian and Ubuntu server packages:

```bash
ansible-playbook playbooks/update_servers.yml --ask-become-pass
```

## PKI / TLS certificates

The homelab's TLS standard is **wildcard Let's Encrypt issued over the Porkbun.
There are two paths, both using the same Porkbun API credentials
(`porkbun_api_key` / `porkbun_secret_api_key` in `secrets.sops.yaml`):

1. **Reverse-proxied services** - Caddy on the `docker` host serves
   `*.<porkbun_domain>` and renews it unattended
   (`roles/docker_host/templates/docker/caddy/Caddyfile.j2`). Nothing per-service
   to configure; a new hostname under the wildcard is just a new
   `caddy_reverse_proxies` entry.
2. **Proxmox API (`:8006`)** - each hypervisor gets its own cert via
   **Proxmox-native ACME**, configured by
   `roles/docker_host/tasks/config/proxmox_acme.yml` with variable
   `proxmox_acme_enabled`. The role registers a `default` ACME account,
   configures a Porkbun DNS plugin, sets the node's cert domain to
   `<host>.<porkbun_domain>` (override with `proxmox_acme_domain`), and orders
   the cert once. Proxmox then renews it itself on its `pve-daily-update` timer.
   No cert material is stored as a secret, only the Porkbun creds and
   `proxmox_acme_email` (used only when registering a *new* account).

For Terraform to verify the Proxmox cert (rather than `insecure = true`), the
`<host>.<porkbun_domain>` names must resolve to each host's LAN IP. This is done
with **OPNsense Unbound host overrides** , which also lets the in-cluster CI runner
resolve them. The `insecure = false` flip and FQDN endpoints live in
`terraform_nodes` (`providers.tf` + `terraform.tfvars`).

Certificate health is monitored two ways:

- **Gatus** asserts `[CERTIFICATE_EXPIRATION] > 336h` (14 days) on the Proxmox
  `:8006` endpoints and Caddy, a renewal that silently stops is caught
  before the cert actually expires. Set `cert_expiry: true` on a service registry
  entry to extend this to any other self-terminating HTTPS endpoint.
- **Prometheus** (`CertRenewal` in
  `roles/docker_host/files/prometheus-grafana/alert.rules.yml`) fires the moment
  `pve-daily-update.service` fails,  ~30 days before expiry, earlier than Gatus.

### Enabling ACME on a new Proxmox host

1. Ensure `proxmox_acme_email` is set in `secrets.sops.yaml` (once, shared).
2. In the host's `host_vars`, set `proxmox_acme_enabled: true` (and
   `proxmox_acme_domain` if its LAN name isn't `<inventory_hostname>.<porkbun_domain>`).
3. Add an OPNsense Unbound host override: `<host>.<porkbun_domain>` → its LAN IP.
4. Deploy: `ansible-playbook playbooks/playbook.yml --limit <host>,docker --tags proxmox-acme,proxmox`
5. Verify on the host:
   `openssl x509 -in /etc/pve/local/pveproxy-ssl.pem -noout -issuer -enddate`
   (issuer should be Let's Encrypt).
6. In `terraform_nodes`: set that host's `*_endpoint` to
   `https://<host>.<porkbun_domain>:8006/` and its `providers.tf` block to
   `insecure = false`, then `terraform plan` (expect a no-op).

### Disabling PKI (reverting a Proxmox host to self-signed)

Work from the repos outward, then clean up on the host:

1. **Terraform** - set `insecure = true` on the host's `providers.tf` block, 
   revert its `*_endpoint` in `terraform.tfvars` to the IP. Run
   `terraform plan`/`apply`.
2. **Ansible** - set `proxmox_acme_enabled: false` in the host's `host_vars` so
   future runs stop re-configuring ACME.
3. **On the Proxmox host** - stop ACME and drop back to the built-in self-signed
   cert:

   ```bash
   pvenode config set --delete acmedomain0   # stop ACME managing this node
   pvenode cert delete                        # remove the custom (LE) pveproxy cert;
                                              # pveproxy falls back to self-signed pve-ssl
   systemctl restart pveproxy                 # if not restarted automatically
   ```

4. **Monitoring** - the Gatus `[CERTIFICATE_EXPIRATION]` checks keep working on
   the self-signed cert (long validity), and `CertRenewal` simply never fires
   without ACME.

## CI (merge request check, manual apply)

CI runs on two separate runners. Jobs needing nested KVM (`molecule`, and the
`vagrant_boxes` Packer builds) stay on the `runner` host's shell executor
(`tags: [ansible]`). Everything else, `ansible_lint`, `ansible_check`,
`ansible_apply`, and `terraform_nodes`' `terraform_plan`/`terraform_apply`.
Runs on the `kubernetes_runner`-deployed Kubernetes-executor runner
(`tags: [k8s]`), in ephemeral job pods rather than a persistent VM.

Required setup in GitLab (**Settings → CI/CD → Variables**):

- `SOPS_AGE_KEY` - type **Variable**, masked, the private half of an age
  keypair whose public half is a recipient in `private/secrets/.sops.yaml`.
  Do not mark it protected, or MR pipelines will not receive it.
- `KUBERNETES_RUNNER_SSH_PRIVATE_KEY` - type **Variable**, masked,
  base64-encoded. The private half of
  the keypair `pre_tasks.yml` generates on `kube-control` and
  `base/tasks/users/root.yml` authorizes on every managed host. The identity
  `ansible_check`/`ansible_apply` job pods connect with, since Kubernetes
  executor pods have no persistent identity of their own the way the `runner`
  VM does.

  ```bash
  ansible-playbook playbooks/playbook.yml --limit server,nodes,kubernetes
  ```

  Then fetch and encode the generated key:

  ```bash
  ssh root@kube-control base64 -w0 /etc/kubernetes/gitlab-runner-k8s-ssh/id_ed25519
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
linked correctly.

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
full test lifecycle per role: `create -> prepare -> converge -> idempotence ->
verify -> destroy`, so it also catches non-idempotent tasks and asserts
post-conditions (things `vagrant up` alone never checked). It uses the
vagrant/libvirt driver (not containers) so systemd/journald/locale/microcode
tasks run with production fidelity.

Scenarios live under `molecule/`:

- `molecule/base/` - applies the `base` role in isolation.
- `molecule/workstation/` - applies the full workstation-host stack
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

```bash
# Full lifecycle for a scenario (all three distros at once)
./scripts/molecule.sh test -s base
./scripts/molecule.sh test -s workstation

# One distro at a time
./scripts/molecule.sh test -s base --platform-name arch-test
./scripts/molecule.sh test -s workstation --platform-name ubuntu-test

# Iterating: keep the VMs up between runs
./scripts/molecule.sh converge -s base   # (re-)apply
./scripts/molecule.sh verify   -s base   # run assertions only
./scripts/molecule.sh login    -s base --host ubuntu-test
./scripts/molecule.sh destroy  -s base
```
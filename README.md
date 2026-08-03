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

One cross-cutting group also exists: `atomic`, for image-based (ostree) systems
such as Bazzite. Its members belong to their normal group as well, and are
listed there only so the lifecycle plays in `playbooks/lifecycle/` can skip
what drives a classic package manager, which these hosts do not have.
`post_tasks.yml` drops them at the play level (`hosts: all:!atomic`);
`pre_tasks.yml` keeps them and guards its single package task with
`when: "'atomic' not in group_names"`, because its explicit `setup` is the only
fact gathering in the run that does not depend on `--tags`. Dropping a host
from that play leaves it without facts for every later `always`-tagged task.

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
ansible-playbook playbooks/playbook.yml --limit christoffer-desktop --tags llama-cpp --ask-become-pass
```

The workstation hosts connect as `christoffer` rather than `root` and their
sudoers entry requires a password (`files/users/sudoers_christoffer`), so any
run that escalates on them needs `--ask-become-pass` (`-K`). Runs limited to
the `server`, `nodes` or `kubernetes` groups connect as root and do not.

`christoffer-desktop` is the only host that escalates over SSH, and it also
sets `ansible_pipelining: true` in its host_vars. Without it every `become`
there fails with `Timeout waiting for privilege escalation prompt`: sudo works
fine on the host, but the prompt from the PTY-backed call Ansible makes never
reaches it. Pipelining sends the module and the become password over the open
stdin stream instead, skipping the prompt handshake. It is scoped to that host
rather than set in `ansible.cfg` so the connection behaviour of every other
host stays unchanged; promoting it globally is a safe speedup if wanted, since
no managed host sets `requiretty`.

### Local inference (llm node + llama_cpp role)

Local LLM serving is split across two machines, because the only GPU worth
running a model on sits in a desktop rather than in a hypervisor:

- The `llm` LXC on proxmox1 runs the front ends: Open WebUI for chat, SearXNG
  as its web-search backend, and Hermes Agent as an agent runtime, deployed
  like every other node through `docker_host` (`--tags node-llm`).
- `christoffer-desktop` runs llama.cpp itself, deployed by the `llama_cpp`
  role (`--tags llama-cpp`). It is an image-based Fedora system (Bazzite), so
  the server runs as a podman Quadlet container in
  `/etc/containers/systemd/llama-server.container` rather than as a layered
  package, and uses the Vulkan build of llama.cpp, which needs only the Mesa
  driver already present in the image. Setting `llama_backend: rocm` in
  `playbooks/host_vars/christoffer-desktop` switches to the ROCm build of the
  same release and adds `/dev/kfd`.

The model is declared as `llama_model` (llama-server's `-hf` form) and is
downloaded on first start into `/var/lib/llama.cpp`, so restarts do not
re-fetch it. `llama_context_size` is the knob to watch: on a 16 GB card the
weights and the KV cache have to share the VRAM, and a context too large for
both silently pushes layers back onto the CPU.

Agent use raises that floor sharply. Hermes puts every tool and skill
definition in its system prompt, which overflows a 16k window before the user
types anything, so `christoffer-desktop` runs 32k with a q8_0 KV cache
(`llama_extra_args`) to halve the cache cost. `hermes_context_length` in
`host_vars/llm` must be kept equal to `llama_context_size`, since Hermes
assumes a large default for custom providers instead of reading the server's
real window.

Open WebUI treats the desktop as an optional upstream. When it is powered off,
Open WebUI simply lists no models instead of failing.

Hermes Agent runs as `command: gateway run`. The image's default entrypoint is
its interactive TUI, which exits cleanly the moment it finds stdin is not a
terminal, so without the override the container restarts forever while logging
a successful startup.

It then serves two ports from one container: the OpenAI-compatible API on 8642,
which needs `API_SERVER_ENABLED`, `API_SERVER_KEY` and
`API_SERVER_HOST=0.0.0.0` (without the last it binds loopback inside the
container and the published port reaches nothing), and its web dashboard on
9119, which starts on `HERMES_DASHBOARD=1`. The dashboard refuses any
non-loopback bind until an auth provider is registered, so the
`HERMES_DASHBOARD_BASIC_AUTH_*` credentials are what make it reachable on the
LAN rather than an optional hardening step. The image fixes its data directory
at `/opt/data` via `HERMES_HOME`, so config, memory, skills and the database
are persisted by mounting there rather than at a home directory path.

Hermes Agent shares that one llama.cpp instance rather than loading a model of
its own: `templates/llm/hermes/config.yaml.j2` sets `provider: custom` with the
same base URL, and Open WebUI lists both as OpenAI connections
(`OPENAI_API_BASE_URLS`, semicolon separated and index-matched with
`OPENAI_API_KEYS`). Those are PersistentConfig settings, so an Open WebUI whose
database already exists keeps its stored connections and needs the second one
added through the admin UI instead.

Hermes ships a shell tool. It runs with `TERMINAL_ENV=local`, which confines
commands to the Hermes container: no host docker socket, no host bind mounts
beyond its own data directory, and no `SUDO_PASSWORD`. The upstream alternative
(`TERMINAL_ENV=docker`) isolates each command in a throwaway container but
requires mounting the host docker socket, which is root-equivalent on the LXC
and grants more than it contains.

### GPU and inference metrics

`christoffer-desktop` is scraped by the existing Prometheus, so GPU and
inference history is visible in Grafana from any machine on the LAN rather than
only in a terminal on the desktop itself:

- `node_exporter_atomic` runs node_exporter as a podman Quadlet, since the
  `prometheus.prometheus.node_exporter` role installs a binary and that does
  not belong on an image-based host. It also installs a small script and
  systemd timer that read `/sys/class/drm/card*/device` into a textfile
  collector, giving `amdgpu_busy_percent`, `amdgpu_vram_used_bytes`,
  `amdgpu_vram_total_bytes`, `amdgpu_temperature_celsius` and
  `amdgpu_power_watts`. The card is auto-detected as the one reporting the
  most VRAM, which distinguishes a discrete Radeon from an integrated one;
  `amdgpu_card` pins it explicitly. Nothing here needs ROCm, so it works on a
  Vulkan-only host.
- `--metrics` in `llama_extra_args` exposes llama-server's own counters on its
  existing port, scraped as a separate `llama_cpp` job.
- The `gpu-inference` dashboard is provisioned from
  `templates/prometheus-grafana/grafana/`, so it is rendered by Ansible like
  the rest of the stack. It binds to Prometheus through a `datasource`
  template variable rather than a fixed UID, which leaves the existing
  hand-made datasource untouched instead of provisioning a duplicate. UI edits
  to it are overwritten on the next run.

Both targets belong to a workstation that is powered off much of the time, so
they are down by design and no alert rule watches them. Adding one would page
on every shutdown.

The `llama_cpp` role is a separate play rather than part of the `workstation`
role so that it can run on its own, without triggering the package installs
that role performs.

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

## Authentication / SSO (Authentik)

Authentik on the `authentik` node is the identity provider for WAN-facing
services. Two integration styles are used, chosen per application:

- **Forward auth** - Caddy asks Authentik whether a request is authenticated
  before it reaches the upstream. Suits browser-only applications, especially
  ones with no login of their own.
- **Native OIDC** - the application authenticates against Authentik itself.
  Required for anything with native clients, because a mobile app, TV client
  or share link cannot complete an interactive browser login.

Configuration is split by layer. The deployment (image tag, compose, env vars)
is Ansible, in `roles/docker_host/{tasks/nodes,templates}/authentik`. The
objects (groups, providers, applications, policy bindings) are Terraform, in
`terraform_nodes`' `authentik/` project. Neither manages the other's concerns.

`AUTHENTIK_COOKIE_DOMAIN` is deliberately unset. Scoping the session cookie to
the apex domain makes Authentik unreachable by LAN IP, because a browser
discards a domain-scoped cookie when the request host is a bare address, and
direct IP access is the escape hatch for when Caddy or DNS is broken. Proxy
providers use forward auth in "single" mode, where each protected host carries
its own outpost cookie, so no cookie domain is needed.

### Putting a service behind forward auth

1. Add a proxy provider and application in `terraform_nodes`' `authentik/`
   project, with external host `https://<service>.<porkbun_domain>`, then
   apply.
2. Set `forward_auth: true` on the service's `caddy_reverse_proxies` entry in
   `host_vars/docker`.
3. Ensure the subdomain is in `porkbun_subdomains` so DDNS creates the record.
4. Deploy: `ansible-playbook playbooks/playbook.yml --limit docker --tags node-docker`

Each entry renders as a `handle` block scoped to one hostname. Forward-auth
entries additionally proxy `/outpost.goauthentik.io/*` straight to the outpost,
which is how the login callback returns. The templating task validates the
rendered Caddyfile against the running Caddy container before the compose
deploy recreates anything, so a syntax error stops the play with the sites
still up.

Never set `forward_auth` on the `auth` host itself: it would place Authentik
behind itself, and it is the escape hatch when a binding is misconfigured.

### Internal resolution of the auth hostname

`auth.<porkbun_domain>` must resolve to the Caddy host from inside the LAN, via
an OPNsense Unbound host override, the same mechanism the Proxmox ACME
hostnames use:

```text
auth.<porkbun_domain>  ->  <docker host IP>
```

Point it at the Caddy host, not the Authentik LXC: Caddy terminates TLS with
the wildcard certificate, while Authentik serves plain HTTP on :9000 and a
self-signed certificate on :9443.

Without the override the name resolves to the WAN address everywhere, and any
service that must reach Authentik server-side depends on the router hairpinning
traffic back in. An OIDC client such as Immich fails its discovery request with
a bare "fetch failed" when that does not work. Terraform's authentik project and
the in-cluster CI runner reach Authentik the same way.

Keeping one hostname for both sides matters beyond convenience: an OIDC issuer
is compared as a string, so an internal client configured with a different URL
than the browser uses would be rejected even when both reach the same server.

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
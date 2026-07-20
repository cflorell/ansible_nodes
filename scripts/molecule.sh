#!/usr/bin/env bash
# Wrapper around `molecule` that works around a molecule 26 / molecule-plugins
# incompatibility with the vagrant driver.
#
# molecule-plugins ships the `vagrant` action as a bundled Ansible module, and
# molecule core used to inject that module directory into ANSIBLE_LIBRARY when
# running the driver's create/destroy playbooks. molecule 26 dropped that
# injection (the driver still exposes modules_dir(), but core no longer reads
# it), so `ansible-playbook` fails with "couldn't resolve module/action
# 'vagrant'". We compute the module dir from the installed package and export
# it; molecule's provisioner inherits os.environ, so every step picks it up.
#
# Usage: scripts/molecule.sh test -s base   (any molecule args are forwarded)
# Overrides: MOLECULE_BIN / MOLECULE_PYTHON to point at a specific venv.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHON="${MOLECULE_PYTHON:-$REPO_ROOT/.venv-molecule/bin/python}"
[ -x "$PYTHON" ] || PYTHON="python3"

MOLECULE_BIN="${MOLECULE_BIN:-$REPO_ROOT/.venv-molecule/bin/molecule}"
[ -x "$MOLECULE_BIN" ] || MOLECULE_BIN="molecule"

vagrant_modules="$("$PYTHON" - <<'PY'
import os
import molecule_plugins.vagrant as m
print(os.path.join(os.path.dirname(m.__file__), "modules"))
PY
)"

export ANSIBLE_LIBRARY="${vagrant_modules}${ANSIBLE_LIBRARY:+:$ANSIBLE_LIBRARY}"

# The vagrant driver's create/destroy playbooks run on localhost and import
# python-vagrant, which is installed in this same interpreter. Ansible's
# localhost interpreter discovery would otherwise pick system python (no
# python-vagrant), so pin it. molecule.yml reads MOLECULE_DRIVER_PYTHON for
# localhost's ansible_python_interpreter.
export MOLECULE_DRIVER_PYTHON="$PYTHON"

exec "$MOLECULE_BIN" "$@"

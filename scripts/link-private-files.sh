#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/link-private-files.sh [options]

Options:
  -s, --secrets-dir DIR   Path to the private secrets repo.
                          Defaults to $HOMELAB_SECRETS_DIR, then common local paths.
  -a, --adopt             Copy existing local private files into the private repo if
                          the private copy is missing, then replace local files with symlinks.
  -f, --force             Replace existing local regular files with symlinks, backing
                          the old local file up first.
  -c, --check             Verify all private sources exist and local paths are symlinks.
  -n, --dry-run           Print actions without changing files.
  -h, --help              Show this help.

Private repo layout:
  homelab-secrets/
    ansible_nodes/
      secrets.vault
      inventory/hosts
      inventory/proxmox.yml
      ...

Examples:
  HOMELAB_SECRETS_DIR=~/git_private/homelab-secrets scripts/link-private-files.sh --adopt
  scripts/link-private-files.sh --secrets-dir ~/git_private/homelab-secrets
  scripts/link-private-files.sh --check
USAGE
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
repo_name="$(basename -- "$repo_root")"
legacy_repo_name="${repo_name//_/-}"

secrets_dir="${HOMELAB_SECRETS_DIR:-}"
adopt=false
force=false
check_only=false
dry_run=false

while (($#)); do
  case "$1" in
    -s|--secrets-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --secrets-dir requires a path" >&2; exit 2; }
      secrets_dir="$2"
      shift 2
      ;;
    -a|--adopt)
      adopt=true
      shift
      ;;
    -f|--force)
      force=true
      shift
      ;;
    -c|--check)
      check_only=true
      shift
      ;;
    -n|--dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

choose_default_secrets_dir() {
  local candidate
  for candidate in \
    "$HOME/git/private/secrets" \
    "$repo_root/../private/secrets"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "$HOME/git/private/secrets"
}

if [[ -z "$secrets_dir" ]]; then
  secrets_dir="$(choose_default_secrets_dir)"
fi

canonicalize_dir() {
  local input="$1"
  local parent
  local base

  input="${input/#\~/$HOME}"
  case "$input" in
    /*) ;;
    *) input="$PWD/$input" ;;
  esac

  if [[ -d "$input" ]]; then
    cd -- "$input" && pwd -P
    return 0
  fi

  parent="$(dirname -- "$input")"
  base="$(basename -- "$input")"

  if [[ -d "$parent" ]]; then
    printf '%s/%s\n' "$(cd -- "$parent" && pwd -P)" "$base"
  else
    printf '%s\n' "$input"
  fi
}

secrets_dir="$(canonicalize_dir "$secrets_dir")"

if [[ "$(basename -- "$secrets_dir")" == "$repo_name" || "$(basename -- "$secrets_dir")" == "$legacy_repo_name" ]]; then
  secrets_project_dir="$secrets_dir"
elif [[ -d "$secrets_dir/$repo_name" ]]; then
  secrets_project_dir="$secrets_dir/$repo_name"
elif [[ -d "$secrets_dir/$legacy_repo_name" ]]; then
  secrets_project_dir="$secrets_dir/$legacy_repo_name"
elif [[ -e "$secrets_dir/secrets.vault" || -e "$secrets_dir/inventory/hosts" ]]; then
  secrets_project_dir="$secrets_dir"
else
  secrets_project_dir="$secrets_dir/$repo_name"
fi

private_files=(
  "playbooks/group_vars/all/secrets.sops.yaml"
  "inventory/hosts"
  "inventory/proxmox.yml"
  "playbooks/roles/server/files/torrent/se.protonvpn.udp.ovpn"
)

run() {
  if $dry_run; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

ensure_parent() {
  local path="$1"
  run mkdir -p -- "$(dirname -- "$path")"
}

backup_path() {
  local path="$1"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  printf '%s.private-backup-%s\n' "$path" "$stamp"
}

errors=0

for relpath in "${private_files[@]}"; do
  source_path="$secrets_project_dir/$relpath"
  target_path="$repo_root/$relpath"

  if $check_only; then
    if [[ ! -e "$source_path" ]]; then
      echo "MISSING source: $source_path" >&2
      errors=$((errors + 1))
      continue
    fi

    if [[ ! -L "$target_path" ]]; then
      echo "NOT LINKED target: $target_path" >&2
      errors=$((errors + 1))
      continue
    fi

    linked_to="$(readlink -- "$target_path")"
    if [[ "$linked_to" != "$source_path" ]]; then
      echo "WRONG LINK target: $target_path -> $linked_to" >&2
      echo "           expected: $source_path" >&2
      errors=$((errors + 1))
      continue
    fi

    echo "OK $relpath"
    continue
  fi

  if [[ ! -e "$source_path" ]]; then
    if $adopt && [[ -f "$target_path" && ! -L "$target_path" ]]; then
      echo "Adopting $relpath into private repo"
      ensure_parent "$source_path"
      run cp -p -- "$target_path" "$source_path"
    else
      echo "ERROR: missing private source: $source_path" >&2
      echo "       create it there, or rerun with --adopt if $target_path is the current source of truth" >&2
      errors=$((errors + 1))
      continue
    fi
  fi

  ensure_parent "$target_path"

  if [[ -L "$target_path" ]]; then
    linked_to="$(readlink -- "$target_path")"
    if [[ "$linked_to" == "$source_path" ]]; then
      echo "Already linked $relpath"
      continue
    fi

    echo "Replacing existing symlink $relpath"
    run rm -- "$target_path"
  elif [[ -e "$target_path" ]]; then
    if $adopt || $force; then
      backup="$(backup_path "$target_path")"
      echo "Backing up existing local file: $target_path -> $backup"
      run mv -- "$target_path" "$backup"
    else
      echo "ERROR: target exists and is not a symlink: $target_path" >&2
      echo "       rerun with --adopt or --force after confirming the private copy is correct" >&2
      errors=$((errors + 1))
      continue
    fi
  fi

  echo "Linking $relpath"
  run ln -s -- "$source_path" "$target_path"
done

if ((errors > 0)); then
  echo "Completed with $errors error(s)." >&2
  exit 1
fi

echo "Private file links are ready."

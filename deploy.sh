#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RENURD_DIR="${SCRIPT_DIR}/../renurd"
INSTALL_ONLY=false

case "${1:-}" in
  "") ;;
  --install-only) INSTALL_ONLY=true ;;
  *)
    echo "Usage: $0 [--install-only]" >&2
    exit 2
    ;;
esac

if [[ ! -f "${RENURD_DIR}/flake.nix" ]]; then
  echo "Missing Renurd source at ${RENURD_DIR}" >&2
  exit 1
fi

echo "==> 1. Syncing local source code and Renurd to builder..."
rsync -avz --exclude='.git' "${SCRIPT_DIR}/" nixos@h4x0r.local:~/pinephone-nixos/
rsync -avz \
  --exclude='.git' \
  --exclude='target/' \
  --exclude='result' \
  --exclude='result-*' \
  --exclude='captures/' \
  --exclude='pebble/build/' \
  --exclude='nurd-host.toml' \
  --exclude='nurd-tablets.json' \
  "${RENURD_DIR}/" nixos@h4x0r.local:~/renurd/

echo "==> 2. Building toplevel system derivation on builder..."
ssh nixos@h4x0r.local "cd ~/pinephone-nixos && nix-build --argstr device pine64-pinephonepro --argstr system aarch64-linux -A config.system.build.toplevel --out-link result-toplevel"

echo "==> 3. Copying system closure from builder to PinePhone Pro..."
ssh nixos@h4x0r.local "cd ~/pinephone-nixos && export NIX_SSHOPTS='-o StrictHostKeyChecking=no' && nix-copy-closure --to pine@pinephone-pro.local result-toplevel"

echo "==> 4. Setting system profile and switching configuration on PinePhone Pro..."
STORE_PATH=$(ssh nixos@h4x0r.local "readlink -f ~/pinephone-nixos/result-toplevel")
ssh pine@pinephone-pro.local bash -s -- "$STORE_PATH" "$INSTALL_ONLY" <<'REMOTE'
set -u

store_path=$1
install_only=$2
sudo_run() {
  printf '%s\n' 1234 | sudo -S -p '' "$@"
}

sudo_run nix-env -p /nix/var/nix/profiles/system --set "$store_path"

if [[ $install_only == true ]]; then
  echo "Installed $store_path as the default profile; live switch intentionally skipped"
  exit 0
fi

# Preserve the switch result, then verify the direct Mobile NixOS Phosh service
# and the shell's D-Bus name. A running Phoc alone is insufficient because a
# failed shell startup leaves the loading wheel up. The direct system service
# intentionally does not become logind's foreground ActiveSession.
switch_status=0
sudo_run /nix/var/nix/profiles/system/bin/switch-to-configuration switch || switch_status=$?

export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
for _attempt in $(seq 1 30); do
  if ! systemctl --user list-jobs --no-legend 2>/dev/null \
    | grep -Eq '^[[:space:]]*[0-9]+'; then
    break
  fi
  sleep 1
done

if ! systemctl is-active --quiet phosh.service; then
  sudo_run systemctl reset-failed phosh.service
  sudo_run systemctl start phosh.service
fi

if ! systemctl is-active --quiet phosh.service; then
  systemctl status --no-pager phosh.service || true
  exit 1
fi

healthy_phosh=false
for _attempt in $(seq 1 30); do
  if busctl --user --no-pager status org.gnome.Shell >/dev/null 2>&1; then
    healthy_phosh=true
    break
  fi
  sleep 1
done

if [[ $healthy_phosh != true ]]; then
  loginctl seat-status seat0 || true
  systemctl status --no-pager phosh.service || true
  exit 1
fi

failed_units=$(systemctl --failed --no-legend --plain --no-pager \
  | awk '$1 ~ /\.(service|socket|target|mount|device|scope)$/ { print $1 }')
if [[ -n "${failed_units//[[:space:]]/}" ]]; then
  printf '%s\n' "$failed_units" >&2
  if (( switch_status != 0 )); then
    exit "$switch_status"
  fi
  exit 1
fi

if (( switch_status != 0 )); then
  echo "switch-to-configuration reported status $switch_status; all failed units recovered"
fi
REMOTE

if [[ $INSTALL_ONLY == true ]]; then
  echo "==> Done! System is installed as the default boot target; live switch skipped."
else
  echo "==> Done! System is live and set as default boot target."
fi

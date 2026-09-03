#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RENURD_DIR="${SCRIPT_DIR}/../renurd"

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
ssh pine@pinephone-pro.local bash -s -- "$STORE_PATH" <<'REMOTE'
set -u

store_path=$1
sudo_run() {
  printf '%s\n' 1234 | sudo -S -p '' "$@"
}

sudo_run nix-env -p /nix/var/nix/profiles/system --set "$store_path"

# Preserve the switch result, then verify that greetd created a foreground
# Wayland session. This is also the condition required for logind-mediated
# brightness control; merely seeing a running compositor is insufficient.
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

if ! systemctl is-active --quiet greetd.service; then
  sudo_run systemctl reset-failed greetd.service
  sudo_run systemctl start greetd.service
fi

if ! systemctl is-active --quiet greetd.service; then
  systemctl status --no-pager greetd.service || true
  exit 1
fi

foreground_wayland=false
for _attempt in $(seq 1 30); do
  active_session=$(loginctl show-seat seat0 --property=ActiveSession --value 2>/dev/null || true)
  if [[ -n "$active_session" ]] \
    && [[ $(loginctl show-session "$active_session" --property=Type --value 2>/dev/null || true) == wayland ]]; then
    foreground_wayland=true
    break
  fi
  sleep 1
done

if [[ $foreground_wayland != true ]]; then
  loginctl seat-status seat0 || true
  systemctl status --no-pager greetd.service || true
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

echo "==> Done! System is live and set as default boot target."

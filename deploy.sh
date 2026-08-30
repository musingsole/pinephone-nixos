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
ssh pine@pinephone-pro.local "echo 1234 | sudo -S nix-env -p /nix/var/nix/profiles/system --set $STORE_PATH && echo 1234 | sudo -S /nix/var/nix/profiles/system/bin/switch-to-configuration switch"

echo "==> Done! System is live and set as default boot target."

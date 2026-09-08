#!/usr/bin/env bash
# Copies the addon into a local WoW installation for testing.
# Override the target with WOW_ADDONS=/path/to/Interface/AddOns ./deploy.sh
set -euo pipefail

cd "$(dirname "$0")"
target="${WOW_ADDONS:-/mnt/c/Program Files (x86)/World of Warcraft/_anniversary_/Interface/AddOns}"

if [[ ! -d "$target" ]]; then
	echo "AddOns directory not found: $target" >&2
	exit 1
fi

rm -rf "$target/NodeRadar"
cp -r NodeRadar "$target/NodeRadar"
echo "deployed to $target/NodeRadar"

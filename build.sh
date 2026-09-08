#!/usr/bin/env bash
# Packages the addon folder for a CurseForge upload. The version comes from the .toc,
# so it is never typed twice.
set -euo pipefail

cd "$(dirname "$0")"
version=$(grep -oP '^## Version:\s*\K.+' NodeRadar/NodeRadar.toc | tr -d '\r')
archive="dist/NodeRadar-v${version}.zip"

mkdir -p dist
rm -f "$archive"

# the GPL requires the licence to travel with the code, so it goes inside the
# folder players actually install
cp LICENSE NodeRadar/LICENSE
python3 -m zipfile -c "$archive" NodeRadar
echo "$archive"

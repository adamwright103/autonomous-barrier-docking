#!/usr/bin/env bash
#
# Clone every component repository side by side as independent working repos.
#
# This is the alternative to the submodules in components/. Submodules give you
# pinned commits and one reproducible system state; this gives you four normal
# repositories tracking their own default branches, which is usually what you want
# while actually developing.
#
#   ./scripts/clone-all.sh [target-dir]      default: ./workspace
#
set -euo pipefail

TARGET="${1:-workspace}"

REPOS=(
  "https://github.com/KaelinGraf/Conv-ChArT.git"
  "https://github.com/KaelinGraf/Conv-ChArT-Wireless-Inference.git"
  "https://github.com/adamwright103/p4p_arduino.git"
)

mkdir -p "$TARGET"
cd "$TARGET"

for url in "${REPOS[@]}"; do
  name="$(basename "$url" .git)"
  if [[ -d "$name/.git" ]]; then
    echo "==> $name already present, pulling"
    git -C "$name" pull --ff-only
  else
    echo "==> cloning $name"
    git clone "$url"
  fi
done

echo
echo "Done. Components are in $(pwd):"
ls -1

#!/usr/bin/env bash
# Copy the Bifrost platform dashboard from its source of truth
# (bifrost/deploy/grafana) into this chart. Sibling checkout if there is one,
# GitHub otherwise. Run before a release so the chart ships what bifrost ships.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dst="$here/chart/dashboards/bifrost-platform.json"
src="${BIFROST_REPO:-$here/../bifrost}/deploy/grafana/bifrost-platform.json"
if [[ -f "$src" ]]; then
  cp "$src" "$dst"
else
  curl -fsSL "https://raw.githubusercontent.com/bifrost-compute/bifrost/${BIFROST_REF:-main}/deploy/grafana/bifrost-platform.json" -o "$dst"
fi
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$dst"
echo "synced $(wc -c < "$dst") bytes -> $dst"

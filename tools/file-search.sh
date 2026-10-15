#!/bin/bash

# Open the File Search panel: ask for a query, hand it to the shell plugin.
# Bind this to a key, e.g. in ~/.config/hypr/bindings.lua:
#   o.bind("SUPER + E", "File search",
#     "$HOME/.config/omarchy/plugins/mraghuvaran.file-search/tools/file-search.sh")

set -euo pipefail

PLUGIN_ID="mraghuvaran.file-search"
INDEX_DIR="${GEMMA_SEARCH_INDEX:-$HOME/embedding-space}"

# Close a previous results panel, if any.
omarchy-shell -q shell hide "$PLUGIN_ID" 2>/dev/null || true

query=$(omarchy menu input "Search your files — describe what you're looking for" --width 640) || exit 0
if [[ -z ${query// } ]]; then
  exit 0
fi

payload=$(jq -nc --arg q "$query" --arg idx "$INDEX_DIR" '{query: $q, index: $idx}')
if ! omarchy-shell shell summon "$PLUGIN_ID" "$payload" >/dev/null; then
  omarchy-notification-send "File search" "Could not open the search panel (${PLUGIN_ID})"
  exit 1
fi

#!/bin/bash

# Open the File Search panel. Type your query inside the panel; results
# update live as you type.
# Bind this to a key, e.g. in ~/.config/hypr/bindings.lua:
#   o.bind("SUPER + E", "File search",
#     "$HOME/.config/omarchy/plugins/mraghuvaran.file-search/tools/file-search.sh")

set -euo pipefail

PLUGIN_ID="mraghuvaran.file-search"
INDEX_DIR="${GEMMA_SEARCH_INDEX:-$HOME/embedding-space}"

# Close a previous results panel, if any.
omarchy-shell -q shell hide "$PLUGIN_ID" 2>/dev/null || true

payload=$(jq -nc --arg idx "$INDEX_DIR" '{index: $idx}')
if ! omarchy-shell shell summon "$PLUGIN_ID" "$payload" >/dev/null; then
  omarchy-notification-send "File search" "Could not open the search panel (${PLUGIN_ID})"
  exit 1
fi

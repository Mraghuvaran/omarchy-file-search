#!/bin/bash

# Choose which folders File Search indexes, then build the index.
# The picker saves your selection to <index>/config.json; cancelling keeps
# the previous selection (or indexes the whole home directory on first run).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INDEX_DIR="${GEMMA_SEARCH_INDEX:-$HOME/embedding-space}"

mkdir -p "$INDEX_DIR"

if picked=$(omarchy file select --multiple --directory \
  --title "Choose folders to search — press Cancel to index the whole home directory"); then
  if [[ -n ${picked// } ]]; then
    printf '%s\n' "$picked" | jq -R 'select(length > 0)' | jq -s '{roots: .}' >"$INDEX_DIR/config.json"
    echo "Saved folder selection to $INDEX_DIR/config.json"
  fi
else
  status=$?
  if (( status == 2 )); then
    echo "The file chooser failed to open." >&2
    exit 1
  fi
  # status 1 (nothing picked): keep the existing selection
fi

omarchy-launch-tui bash -c "\"$DIR/build_index.py\" --out \"$INDEX_DIR\"; printf '\nDone — press Enter to close. '; read -r"

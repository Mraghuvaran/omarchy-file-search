# File Search

Semantic search over your own files for Omarchy. Press a key, describe what you're looking for in plain words, and matching text files, images, and videos appear ranked by meaning — with animated results, live image thumbnails, and one-line content previews of every hit.

- **Text**: documents, notes, code, configs — anything text-based
- **Images**: photos, screenshots, wallpapers
- **Videos**: matched by an automatically extracted keyframe
- **100% local**: embeddings are computed by EmbeddingGemma 2 through your own Ollama install; nothing leaves your machine

Everything lives in a single 768-dimensional embedding space, so one query searches all of it. "Sunset over the ocean" can match a photo; "how my monitors are configured" matches your `monitors.lua`.

## Requirements

- Omarchy (Quattro shell) with Ollama running locally
- Python 3 with `numpy`: `omarchy pkg add python-numpy` (or `pip install numpy`)
- `ffmpeg` (already part of Omarchy; used to downscale images and grab video frames)
- Two models from Ollama's library:

```bash
ollama pull embeddinggemma-2:270m   # text and code (required)
ollama pull embeddinggemma-2:740m   # images and video frames (optional, for media)
```

## Setup

1. Install the plugin:

```bash
omarchy plugin add https://github.com/Mraghuvaran/omarchy-file-search --enable
```

2. Choose which folders to index and build the index. The folder picker saves your selection, then builds in a terminal where you can watch progress:

```bash
~/.config/omarchy/plugins/mraghuvaran.file-search/tools/choose-folders.sh
```

Cancel the picker to index your whole home directory instead. The first build embeds one vector per file and takes a few minutes; later runs only process new and edited files. Re-run it whenever you want to refresh.

3. Bind a key to open the search panel, for example in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + E", "File search", "$HOME/.config/omarchy/plugins/mraghuvaran.file-search/tools/file-search.sh")
```

Hyprland reloads the file on save. Optionally you can also add it to the Omarchy menu by adding a row to `~/.config/omarchy/extensions/omarchy-menu.jsonc`.

## Usage

- **Open the panel**: your keybinding (above) or `tools/file-search.sh`
- Type a description of the file you want, not its name — "budget spreadsheet for the kitchen renovation", "screenshot of the theme setup"
- **Arrow keys** navigate, **Enter** opens the file (text files open in your editor, images and videos in your default viewer), **Esc** closes
- Each row shows the file's location and, for text files, a one-line content preview. Image results render a live thumbnail
- Percentages are confidence relative to the best match in this search

From a terminal:

```bash
~/.config/omarchy/plugins/mraghuvaran.file-search/tools/search.py "query words"
search.py "query words" -k 20 --json          # machine readable
search.py "query words" --index ~/my-index    # custom index location
```

## Choosing what gets indexed

- `tools/choose-folders.sh` opens the system folder picker; the selection is saved to `<index>/config.json` and used by every later build
- Cancel the picker to index all of your home directory
- To skip a subfolder, add it to the `exclude` list in `<index>/config.json`:

```json
{
  "roots": ["/home/you/Documents", "/home/you/Work"],
  "exclude": ["/home/you/Work/archive"]
}
```

- Common noise is always skipped: caches, `node_modules`, browser profiles, toolchains, and dot-directories of build systems
- Limits: text files up to 2 MB (first 4,000 characters are embedded), media up to 30 MB
- Audio is not supported yet because Ollama's embedding API accepts only text and images

## Configuration

- `GEMMA_SEARCH_INDEX` environment variable sets the index directory (default `~/embedding-space`)
- `<index>/config.json` holds the folder selection (`roots`) and optional `exclude` paths

## How it works

- Text is embedded with `embeddinggemma-2:270m`; images and video keyframes with `embeddinggemma-2:740m`. Both are the same model — the larger tag just adds the vision encoder — and their text embeddings are identical, so one matrix holds every modality
- Ranking uses mean-centered cosine similarity. Centering is the cure for the anisotropy that otherwise lets generic files outrank real matches; without it, correct answers sit around rank 1000, with it they climb to the top
- The index is incremental: new and edited files are embedded, deleted files are pruned, and everything is stored as a plain `.npy` matrix plus a JSONL manifest in your index directory

## Uninstall

```bash
omarchy plugin remove mraghuvaran.file-search
rm -rf ~/embedding-space                                   # the index, if you want it gone
ollama rm embeddinggemma-2:270m embeddinggemma-2:740m      # the models, if unused elsewhere
```

## Privacy

All embedding and search work happens on your machine. The plugin makes no network requests; the only services involved are your local Ollama daemon and local Python scripts.

## License

MIT — see [LICENSE](LICENSE).

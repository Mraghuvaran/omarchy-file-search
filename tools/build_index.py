#!/usr/bin/env python3
"""Build an embedding space for text, images, and videos in the home directory.

Uses EmbeddingGemma 2 via a local Ollama server:
  - text           -> embeddinggemma-2:270m  (fast text path)
  - images, videos -> embeddinggemma-2:740m  (unified multimodal space)
All embeddings live in the same 768-dim space, so one text query searches
everything.

Produces:
  - embeddings.npy  : float32 matrix (N x 768), L2-normalized
  - files.jsonl     : one record per file: {"path", "kind", "mtime", "chars", "preview"}
Resumable and incremental: re-running embeds only NEW or EDITED files, and
prunes deleted ones from the index. Video files are represented by an
extracted keyframe.
"""

import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error

import numpy as np

HOME = os.path.expanduser("~")
OUT_DIR = os.path.join(HOME, "embedding-space")
MODEL_TEXT = "embeddinggemma-2:270m"
MODEL_MEDIA = "embeddinggemma-2:740m"
OLLAMA = "http://localhost:11434/api/embed"

# Files whose whole content is a lone UUID/hash match everything ~equally and
# pollute search results; they carry no meaning.
UUID_RE = re.compile(r"^[0-9a-fA-F][0-9a-fA-F\s-]{7,}$")

MAX_CHARS = 4000                 # chars of each text file fed to the embedder
MAX_FILE_SIZE = 2 * 1024 * 1024  # ignore text files bigger than 2 MB
MAX_MEDIA_SIZE = 30 * 1024 * 1024
BATCH_TEXT = 32
BATCH_MEDIA = 4                  # base64 payloads are heavy; keep requests small
IMG_MAX_DIM = 768                # downscale before embedding

SKIP_DIRS = {
    ".git", ".cache", "node_modules", "__pycache__", ".venv", "venv",
    "target", "dist", "build", ".ollama", ".npm", ".cargo", ".m2",
    ".gradle", ".terraform", ".tox", ".direnv", "site-packages",
    ".local",  # toolchains (mise) + share live here; user content lives elsewhere
    ".steam", "steamapp", ".mozilla", ".config/google-chrome", "Cache",
    "Cache_Data", "Code Cache", "GPUCache", ".bundle", "vendor",
    # browser extension guts — thousands of identical UI icons
    "chromium", "BraveSoftware", "Extensions", "mozilla",
    # browser telemetry / crash dumps with UUID-only files
    "Crash Reports", "datareporting", "glean",
}

TEXT_EXTS = {
    "txt", "md", "markdown", "rst", "py", "js", "ts", "tsx", "jsx", "mjs",
    "cjs", "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "csv",
    "tsv", "html", "htm", "css", "scss", "c", "h", "cpp", "hpp", "cc",
    "hh", "rs", "go", "java", "rb", "sh", "bash", "zsh", "lua", "sql",
    "xml", "tex", "srt", "vtt", "env", "service", "desktop", "nix",
    "fish", "ps1", "bat", "r", "swift", "kt", "php", "pl", "jl", "hs",
    "el", "clj", "ex", "exs", "erl", "scala", "dart", "vim", "org",
    "log", "diff", "patch", "gsheet", "bibtex", "bib", "lyr", "ly",
}

IMAGE_EXTS = {"jpg", "jpeg", "png", "webp", "gif", "bmp", "avif", "heic", "heif"}
VIDEO_EXTS = {"mp4", "webm", "mov", "mkv", "m4v", "avi"}

# Folders to index (default: the whole home directory) and absolute path
# prefixes to exclude. Overridden by --roots or <out>/config.json.
ROOTS = [HOME]
EXCLUDES = []


def ext_of(path):
    name = os.path.basename(path)
    return name.rsplit(".", 1)[-1].lower() if "." in name else ""


def ollama_models():
    """Names of locally available Ollama models, or None when unreachable."""
    try:
        with urllib.request.urlopen("http://localhost:11434/api/tags", timeout=10) as r:
            data = json.loads(r.read())
        names = set()
        for m in data.get("models", []):
            names.add(str(m.get("name", "")))
            names.add(str(m.get("model", "")))
        return names
    except Exception:
        return None


def embed_texts(texts, retries=3):
    """Embed a list of texts with the text model."""
    body = json.dumps({"model": MODEL_TEXT, "input": texts}).encode()
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                OLLAMA, data=body, headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=600) as r:
                data = json.loads(r.read())
            return data["embeddings"]
        except (urllib.error.URLError, KeyError, TimeoutError, OSError) as e:
            if attempt == retries - 1:
                raise
            time.sleep(2 * (attempt + 1))


def embed_images(b64_list, retries=3):
    """Embed a list of base64 images with the multimodal model."""
    body = json.dumps(
        {"model": MODEL_MEDIA, "input": [{"image": b} for b in b64_list]}
    ).encode()
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                OLLAMA, data=body, headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=600) as r:
                data = json.loads(r.read())
            return data["embeddings"]
        except (urllib.error.URLError, KeyError, TimeoutError, OSError) as e:
            if attempt == retries - 1:
                raise
            time.sleep(2 * (attempt + 1))


def read_text(path):
    """Read up to MAX_CHARS of a file. Returns None if binary-ish/unreadable."""
    try:
        with open(path, "rb") as f:
            raw = f.read(MAX_CHARS * 4)
    except OSError:
        return None
    if b"\x00" in raw:
        return None  # binary
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("utf-8", errors="replace")
    if text.count("\ufffd") > len(text) * 0.05:
        return None  # too binary
    stripped = text.strip()
    if len(stripped) < 200 and UUID_RE.match(stripped):
        return None  # a lone UUID/hash — matches everything, means nothing
    return text[:MAX_CHARS]


def prepare_image(path, ext, tmpdir):
    """Downscale an image, or grab a keyframe of a video, as a temp JPEG.

    Returns (base64_jpeg, kind) or None when the file can't be decoded.
    """
    out = os.path.join(tmpdir, "embed-input.jpg")
    if ext in VIDEO_EXTS:
        kind = "video"
        seeks = ["1", "0"]  # try 1s in, fall back to the very first frame
    else:
        kind = "image"
        seeks = [None]

    for seek in seeks:
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
        if seek is not None:
            cmd += ["-ss", seek]
        cmd += [
            "-i", path,
            "-frames:v", "1",
            "-vf", f"scale='min({IMG_MAX_DIM},iw)':-2",
            "-q:v", "3",
            out,
        ]
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=60)
        except subprocess.TimeoutExpired:
            return None
        if r.returncode == 0 and os.path.exists(out) and os.path.getsize(out) > 0:
            with open(out, "rb") as f:
                b64 = base64.b64encode(f.read()).decode()
            os.unlink(out)
            return b64, kind
        if seek is None:
            break
    return None


def collect_files():
    """Walk the configured roots. Returns (text_files, media_files)."""
    texts, medias = [], []
    seen = set()
    for base in ROOTS:
        base = os.path.abspath(os.path.expanduser(base))
        if not os.path.isdir(base):
            print(f"note: root does not exist, skipping: {base}", file=sys.stderr)
            continue
        for root, dirs, files in os.walk(base, topdown=True):
            dirs[:] = [d for d in dirs
                       if d not in SKIP_DIRS
                       and not excluded(os.path.join(root, d))]
            for name in files:
                p = os.path.join(root, name)
                if p in seen or p.startswith(OUT_DIR) or excluded(p):
                    continue
                seen.add(p)
                e = ext_of(p)
                try:
                    size = os.path.getsize(p)
                except OSError:
                    continue
                if e in TEXT_EXTS and size <= MAX_FILE_SIZE:
                    texts.append(p)
                elif e in IMAGE_EXTS and size <= MAX_MEDIA_SIZE:
                    medias.append(p)
                elif e in VIDEO_EXTS and size <= MAX_MEDIA_SIZE:
                    medias.append(p)
    return texts, medias


def load_state(jsonl_path):
    """Map path -> mtime for everything already indexed (last record wins)."""
    done = {}
    if os.path.exists(jsonl_path):
        with open(jsonl_path) as f:
            for line in f:
                try:
                    rec = json.loads(line)
                    done[rec["path"]] = rec.get("mtime", 0)
                except (json.JSONDecodeError, KeyError):
                    pass
    return done


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    bin_path = os.path.join(OUT_DIR, "embeddings.f32.bin")
    jsonl_path = os.path.join(OUT_DIR, "files.jsonl")

    done = load_state(jsonl_path)
    if done:
        print(f"index holds {len(done)} files", file=sys.stderr)

    def needs_embed(p):
        if p not in done:
            return True
        try:
            return os.path.getmtime(p) > done[p] + 1.0   # edited since indexed
        except OSError:
            return False

    texts, medias = collect_files()
    todo_text = [p for p in texts if needs_embed(p)]
    todo_media = [p for p in medias if needs_embed(p)]

    models = ollama_models()
    if models is None:
        sys.exit("cannot reach Ollama at http://localhost:11434 — is the service running?")
    if MODEL_TEXT not in models:
        sys.exit(f"model {MODEL_TEXT} is not pulled — run: ollama pull {MODEL_TEXT}")
    if todo_media and MODEL_MEDIA not in models:
        print(f"skipping {len(todo_media)} media files: {MODEL_MEDIA} is not pulled "
              f"(run: ollama pull {MODEL_MEDIA})", file=sys.stderr)
        todo_media = []

    new_text = sum(1 for p in todo_text if p not in done)
    new_media = sum(1 for p in todo_media if p not in done)
    roots_desc = ", ".join(ROOTS[:3]) + (f" (+{len(ROOTS) - 3} more)" if len(ROOTS) > 3 else "")
    print(f"indexing: {roots_desc}" + (f"  [{len(EXCLUDES)} excludes]" if EXCLUDES else ""), file=sys.stderr)
    print(f"indexed space: {len(texts)} text / {len(medias)} media candidates", file=sys.stderr)
    print(f"to embed: {len(todo_text)} text ({new_text} new) / "
          f"{len(todo_media)} media ({new_media} new)", file=sys.stderr)

    with open(bin_path, "ab") as bout, open(jsonl_path, "a") as jout:
        if todo_text:
            run_text_batches(todo_text, bout, jout)
        if todo_media:
            run_media_batches(todo_media, bout, jout)

    finalize(bin_path, jsonl_path)


def run_text_batches(todo, bout, jout):
    t0 = time.time()
    count = 0
    for i in range(0, len(todo), BATCH_TEXT):
        batch = todo[i:i + BATCH_TEXT]
        batch_texts, kept = [], []
        for p in batch:
            txt = read_text(p)
            if txt and txt.strip():
                batch_texts.append(txt)
                kept.append(p)
        if not batch_texts:
            continue
        try:
            vecs = embed_texts(batch_texts)
        except Exception as e:
            print(f"text batch failed at {kept[0]}: {e}", file=sys.stderr)
            for p, txt in zip(kept, batch_texts):
                try:
                    v = embed_texts([txt])[0]
                except Exception:
                    continue
                bout.write(np.asarray(v, dtype=np.float32).tobytes())
                jout.write(json.dumps(record(p, "text", txt)) + "\n")
                count += 1
            jout.flush()
            continue
        for p, txt, v in zip(kept, batch_texts, vecs):
            bout.write(np.asarray(v, dtype=np.float32).tobytes())
            jout.write(json.dumps(record(p, "text", txt)) + "\n")
        count += len(kept)
        jout.flush(); bout.flush()
        print(f"text {count}/{len(todo)}  ({count/max(time.time()-t0,1e-9):.1f}/s)",
              file=sys.stderr, flush=True)
    print(f"text done: {count} in {(time.time()-t0)/60:.1f} min", file=sys.stderr)


def run_media_batches(todo, bout, jout):
    t0 = time.time()
    count, skipped = 0, 0
    with tempfile.TemporaryDirectory(prefix="gemma-media-") as tmpdir:
        for i in range(0, len(todo), BATCH_MEDIA):
            batch = todo[i:i + BATCH_MEDIA]
            prepared, kept, kinds = [], [], []
            for p in batch:
                prep = prepare_image(p, ext_of(p), tmpdir)
                if prep is None:
                    skipped += 1
                    continue
                b64, kind = prep
                prepared.append(b64)
                kept.append(p)
                kinds.append(kind)
            if not prepared:
                continue
            try:
                vecs = embed_images(prepared)
            except Exception as e:
                print(f"media batch failed at {kept[0]}: {e}", file=sys.stderr)
                for p, kind, b64 in zip(kept, kinds, prepared):
                    try:
                        v = embed_images([b64])[0]
                    except Exception:
                        skipped += 1
                        continue
                    bout.write(np.asarray(v, dtype=np.float32).tobytes())
                    jout.write(json.dumps(record(p, kind, media_preview(p, kind))) + "\n")
                    count += 1
                jout.flush()
                continue
            for p, kind, v in zip(kept, kinds, vecs):
                bout.write(np.asarray(v, dtype=np.float32).tobytes())
                jout.write(json.dumps(record(p, kind, media_preview(p, kind))) + "\n")
            count += len(kept)
            jout.flush(); bout.flush()
            print(f"media {count}/{len(todo)}  ({count/max(time.time()-t0,1e-9):.2f}/s)",
                  file=sys.stderr, flush=True)
    print(f"media done: {count} in {(time.time()-t0)/60:.1f} min"
          + (f", {skipped} undecodable" if skipped else ""), file=sys.stderr)


def media_preview(path, kind):
    try:
        kb = os.path.getsize(path) // 1024
    except OSError:
        kb = 0
    return f"{kind} ({kb} KB) — {os.path.basename(path)}"


def record(path, kind, text):
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        mtime = 0
    preview = " ".join(text.split())[:200]
    return {"path": path, "kind": kind, "mtime": mtime,
            "chars": len(text), "preview": preview}


def under(path, base):
    """True when path is base itself or lives inside it."""
    base = os.path.abspath(os.path.expanduser(base))
    return path == base or path.startswith(base + os.sep)


def excluded(path):
    """True when path is inside one of the configured exclude prefixes."""
    return any(under(path, e) for e in EXCLUDES)


def in_skipped_dir(path):
    """True when any component of the path is a skipped directory."""
    return any(part in SKIP_DIRS for part in path.split(os.sep))


def load_config(out_dir):
    """Read <out>/config.json (written by tools/choose-folders.sh) if present."""
    cfg_path = os.path.join(out_dir, "config.json")
    if not os.path.exists(cfg_path):
        return {}
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
        return cfg if isinstance(cfg, dict) else {}
    except (json.JSONDecodeError, OSError) as e:
        print(f"note: ignoring unreadable {cfg_path}: {e}", file=sys.stderr)
        return {}


def finalize(bin_path, jsonl_path):
    """Compact into the final index.

    - Keeps the newest record per path (edits supersede older embeddings).
    - Drops records whose file no longer exists under ~ (deleted files).
    - Rewrites embeddings.npy, files.jsonl, and the append log so all three
      stay aligned for the next incremental run.
    """
    if not os.path.exists(bin_path):
        print("nothing indexed", file=sys.stderr)
        return

    total_rows = os.path.getsize(bin_path) // (768 * 4)
    if total_rows == 0:
        print("nothing indexed", file=sys.stderr)
        return

    raw = np.fromfile(bin_path, dtype=np.float32).reshape(total_rows, 768)

    records = []
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                records.append(None)

    # Interrupted runs can leave the log and the raw bin one record apart.
    n = min(len(records), total_rows)
    if len(records) != total_rows:
        print(f"note: log/bin sizes differ ({len(records)} vs {total_rows}); "
              f"aligning to the oldest {n}", file=sys.stderr)
        records = records[:n]

    last = {}
    for i in range(n):
        rec = records[i]
        if rec is None:
            continue
        last[rec["path"]] = i
    keep = sorted(last.values())

    surviving = []
    for i in keep:
        full = records[i]["path"]
        if not os.path.exists(full):
            continue  # deleted file
        if in_skipped_dir(full) or excluded(full):
            continue  # outside the current selection, or a skipped directory
        preview = (records[i].get("preview") or "").strip()
        if len(preview) < 200 and UUID_RE.match(preview):
            continue  # degenerate content: a lone UUID/hash
        surviving.append(i)

    dropped = len(keep) - len(surviving)
    m = raw[:n][surviving]
    norms = np.linalg.norm(m, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    m = m / norms

    np.save(os.path.join(OUT_DIR, "embeddings.npy"), m)

    tmp_jsonl = jsonl_path + ".tmp"
    with open(tmp_jsonl, "w") as f:
        for i in surviving:
            f.write(json.dumps(records[i]) + "\n")
    os.replace(tmp_jsonl, jsonl_path)

    tmp_bin = bin_path + ".tmp"
    with open(tmp_bin, "wb") as b:
        b.write(raw[:n][surviving].tobytes())
    os.replace(tmp_bin, bin_path)

    by_kind = {}
    for i in surviving:
        k = records[i].get("kind", "text")
        by_kind[k] = by_kind.get(k, 0) + 1
    summary = ", ".join(f"{k}: {v}" for k, v in sorted(by_kind.items()))
    print(f"finalized: {len(surviving)} vectors x 768 dims ({summary})"
          + (f" [{dropped} deleted pruned]" if dropped else ""),
          file=sys.stderr)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(
        description="Build an EmbeddingGemma 2 index of the chosen folders.")
    ap.add_argument("--out",
                    default=os.path.join(HOME, "embedding-space"),
                    help="directory where the index is written (default: ~/embedding-space)")
    ap.add_argument("--roots", action="append", default=[],
                    help="folder to index (repeatable). Default: whole home directory, "
                         "or the roots saved in <out>/config.json by tools/choose-folders.sh")
    _args = ap.parse_args()
    OUT_DIR = os.path.abspath(os.path.expanduser(_args.out))
    _cfg = load_config(OUT_DIR)
    ROOTS = _args.roots or _cfg.get("roots") or [HOME]
    EXCLUDES = [str(e) for e in _cfg.get("exclude", [])]
    main()

#!/usr/bin/env python3
"""Semantic search over the home directory's embedding space.

Ranks by mean-centered cosine similarity. Centering removes the model's
"anisotropy" (a generic vector scores ~0.7 against everything, which drowned
out real matches); after centering, correct answers climb from rank ~1000 to
the top of the list. Displayed percentages are relative confidence within the
candidate pool: the best match is 100%.

Usage:
  python3 search.py "query text"            # top 10 results
  python3 search.py "query text" -k 20      # top 20
  python3 search.py "query text" --json     # machine-readable output
"""

import argparse
import json
import os
import sys
import urllib.request

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = "embeddinggemma-2:270m"
OLLAMA = "http://localhost:11434/api/embed"


def embed(text):
    body = json.dumps({"model": MODEL, "input": [text]}).encode()
    req = urllib.request.Request(
        OLLAMA, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return np.asarray(json.loads(r.read())["embeddings"][0], dtype=np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("query")
    ap.add_argument("-k", "--top", type=int, default=10)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--index",
                    default=os.path.join(os.path.expanduser("~"), "embedding-space"),
                    help="index directory containing embeddings.npy and files.jsonl")
    args = ap.parse_args()

    index_dir = os.path.abspath(os.path.expanduser(args.index))
    emb_path = os.path.join(index_dir, "embeddings.npy")
    jsonl_path = os.path.join(index_dir, "files.jsonl")
    if not os.path.exists(emb_path):
        sys.exit(f"no index at {index_dir} — build one first: "
                 f"python3 tools/build_index.py --out {index_dir}")

    m = np.load(emb_path)
    meta = [json.loads(l) for l in open(jsonl_path) if l.strip()]
    if len(meta) != len(m):
        sys.exit(f"index mismatch: {len(m)} vectors vs {len(meta)} records — rebuild")

    # Mean-centering: subtract the corpus mean from both documents and query.
    mu = m.mean(axis=0)
    mc = m - mu
    norms = np.linalg.norm(mc, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    mc /= norms

    q = embed(args.query)
    qn = np.linalg.norm(q)
    if qn == 0:
        sys.exit("empty query embedding")
    q = q / qn
    qc = q - mu
    qc /= max(np.linalg.norm(qc), 1e-9)

    scores = mc @ qc
    order = np.argsort(-scores)[: args.top]

    # Relative confidence: best-in-pool = 100%.
    smin, smax = float(scores.min()), float(scores.max())
    span = max(smax - smin, 1e-9)

    results = []
    for i in order:
        s = float(scores[i])
        pct = round(100.0 * (s - smin) / span)
        results.append({"score": round(s, 4), "pct": pct, **meta[i]})

    if args.json:
        print(json.dumps(results, indent=2))
        return

    for r in results:
        name = os.path.basename(r["path"])
        kind = r.get("kind", "text")
        tag = "" if kind == "text" else f" [{kind}]"
        print(f"{r['pct']:3d}%  {r['path']}{tag}")
        print(f"        {r['preview'][:150]}")
    print(f"\n[{len(meta)} files indexed | centered cosine | model: {MODEL}]")


if __name__ == "__main__":
    main()

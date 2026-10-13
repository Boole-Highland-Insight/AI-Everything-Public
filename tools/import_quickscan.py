#!/usr/bin/env python3
"""Merge imported LLM quickScan fields (blurb_zh / keywords_zh) into library sidecars."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path

REPO: Path
LIBRARY: Path
BRANCH: str
PREFIX = "workspace/mydocs/scanner/"


def sidecar_path(rel: str) -> Path:
    return LIBRARY / "scanner" / f"{rel}.json"


def library_files() -> tuple[dict[str, Path], dict[str, Path]]:
    by_rel: dict[str, Path] = {}
    by_name: dict[str, Path] = {}
    for dirpath, dirnames, filenames in os.walk(LIBRARY):
        dirnames[:] = [d for d in dirnames if d not in {"scanner", ".git"}]
        root = Path(dirpath)
        for name in filenames:
            path = root / name
            if not path.is_file():
                continue
            rel = path.relative_to(LIBRARY).as_posix()
            by_rel[rel] = path
            by_name[name] = path
    return by_rel, by_name


def load_quickscan_records() -> list[tuple[str, dict]]:
    raw = subprocess.check_output(
        ["git", "-C", str(REPO), "ls-tree", "-r", "--name-only", BRANCH],
        text=True,
    )
    records: list[tuple[str, dict]] = []
    for line in raw.splitlines():
        if not line.startswith(PREFIX) or not line.endswith(".json"):
            continue
        if "/descriptions/" in line:
            continue
        blob = subprocess.check_output(
            ["git", "-C", str(REPO), "show", f"{BRANCH}:{line}"],
        )
        try:
            obj = json.loads(blob.decode("utf-8"))
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        search = obj.get("search") if isinstance(obj.get("search"), dict) else {}
        if not search.get("blurb_zh") and not search.get("keywords_zh"):
            continue
        src = ""
        source = obj.get("source")
        if isinstance(source, dict):
            src = str(source.get("workspacePath") or "")
        if not src:
            rel = line[len(PREFIX) :]
            if rel.endswith(".json"):
                rel = rel[: -len(".json")]
            src = rel if rel.startswith("mydocs/") else f"mydocs/{rel}"
        records.append((src, obj))
    return records


def match_library(src: str, by_rel: dict[str, Path], by_name: dict[str, Path]) -> Path | None:
    if src in by_rel:
        return by_rel[src]
    name = Path(src).name
    if name in by_name:
        return by_name[name]
    return None


def main() -> None:
    global REPO, LIBRARY, BRANCH, PREFIX
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True, help="Legacy source Git repository")
    parser.add_argument("--library", type=Path, required=True, help="Destination library; back up scanner/ first")
    parser.add_argument("--ref", default="HEAD", help="Source Git ref")
    parser.add_argument("--prefix", default=PREFIX, help="Source sidecar path prefix")
    args = parser.parse_args()
    REPO, LIBRARY = args.repo.expanduser().resolve(), args.library.expanduser().resolve()
    BRANCH, PREFIX = args.ref, args.prefix
    if not REPO.is_dir() or not LIBRARY.is_dir():
        parser.error("--repo and --library must be existing directories")
    by_rel, by_name = library_files()
    n = 0
    for src, obj in load_quickscan_records():
        path = match_library(src, by_rel, by_name)
        if path is None:
            continue
        rel = path.relative_to(LIBRARY).as_posix()
        dest = sidecar_path(rel)
        if dest.exists():
            record = json.loads(dest.read_text(encoding="utf-8"))
        else:
            dest.parent.mkdir(parents=True, exist_ok=True)
            record = {
                "version": 1,
                "sourceRelative": rel,
                "kind": "other",
                "keyframes": [],
            }
        search = obj.get("search") or {}
        quick = record.get("quickScan") if isinstance(record.get("quickScan"), dict) else {}
        if not quick and isinstance(record.get("summary"), dict):
            quick = dict(record["summary"])
        if not quick and isinstance(record.get("caption"), dict):
            quick = dict(record["caption"])
        quick["blurb_zh"] = search.get("blurb_zh") or ""
        quick["keywords_zh"] = search.get("keywords_zh") or []
        if obj.get("parse") is not None:
            quick["parse"] = obj.get("parse")
        record["quickScan"] = quick
        record.pop("summary", None)
        record.pop("caption", None)
        record.pop("matrixScanner", None)
        dest.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(rel)
        n += 1
    print(f"merged {n} quickScan records")


if __name__ == "__main__":
    main()

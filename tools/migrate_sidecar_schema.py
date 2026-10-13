#!/usr/bin/env python3
"""Rewrite library sidecars: vision/llm/matrixScanner/caption/summary → localScan + quickScan."""

from __future__ import annotations

import argparse
import json
from pathlib import Path



def as_dict(value) -> dict | None:
    return value if isinstance(value, dict) else None


def migrate(obj: dict) -> bool:
    before = json.dumps(obj, sort_keys=True, ensure_ascii=False)

    local = as_dict(obj.get("localScan")) or {}
    old_vision = obj.get("vision")
    if as_dict(old_vision) is not None and "vision" not in local:
        local["vision"] = old_vision
    if local:
        obj["localScan"] = local
    obj.pop("vision", None)
    obj.pop("provider", None)

    quick = (
        as_dict(obj.get("quickScan"))
        or as_dict(obj.get("summary"))
        or as_dict(obj.get("caption"))
        or {}
    )
    ms = as_dict(obj.get("matrixScanner"))
    if ms:
        if "blurb_zh" not in quick and ms.get("blurb_zh"):
            quick["blurb_zh"] = ms.get("blurb_zh") or ""
        if "keywords_zh" not in quick and ms.get("keywords_zh"):
            quick["keywords_zh"] = ms.get("keywords_zh") or []
        if "parse" not in quick and ms.get("parse") is not None:
            quick["parse"] = ms.get("parse")
    llm = obj.get("llm")
    if as_dict(llm) is not None:
        analysis = as_dict(llm.get("analysis"))
        if analysis is not None and "en" not in quick:
            en = dict(analysis)
            if llm.get("model"):
                en.setdefault("model", llm.get("model"))
            quick["en"] = en
    if quick:
        obj["quickScan"] = quick
    obj.pop("summary", None)
    obj.pop("caption", None)
    obj.pop("matrixScanner", None)
    obj.pop("llm", None)

    return json.dumps(obj, sort_keys=True, ensure_ascii=False) != before


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scanner", type=Path, required=True, help="Existing scanner directory; back it up before migration")
    args = parser.parse_args()
    library = args.scanner.expanduser().resolve()
    if not library.is_dir():
        parser.error("--scanner must be an existing directory")
    n = 0
    for path in sorted(library.rglob("*.json")):
        obj = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(obj, dict):
            continue
        if not migrate(obj):
            continue
        path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(path.relative_to(library).as_posix())
        n += 1
    print(f"migrated {n} sidecars")


if __name__ == "__main__":
    main()

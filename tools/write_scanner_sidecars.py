#!/usr/bin/env python3
"""Write scanner/ sidecar JSON mirroring the library tree.

Library:  mydocs/photo/foo.jpg
Scanner:  scanner/mydocs/photo/foo.jpg.json

localScan.vision and imported quickScan live in the same sidecar.
Video covers are not stored; the popup uses Quick Look.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

MATRIX_DATA: Path | None = None

TAG_ZH = {
    "outdoor": ["户外", "室外"],
    "indoor": ["室内"],
    "sky": ["天空"],
    "blue_sky": ["蓝天"],
    "cloudy": ["多云", "阴天"],
    "mountain": ["山", "雪山", "山脉"],
    "hill": ["山丘"],
    "snow": ["雪", "雪山", "积雪"],
    "frozen": ["冰", "冻"],
    "water": ["水"],
    "lake": ["湖", "湖泊"],
    "river": ["河"],
    "water_body": ["水体"],
    "island": ["岛"],
    "bridge": ["桥"],
    "castle": ["城堡"],
    "building": ["建筑"],
    "cityscape": ["城市"],
    "people": ["人", "人物"],
    "crowd": ["人群"],
    "adult": ["成人"],
    "forest": ["森林", "林间"],
    "vegetation": ["植被"],
    "foliage": ["树叶"],
    "plant": ["植物"],
    "grass": ["草"],
    "desert": ["沙漠"],
    "flag": ["旗"],
    "document": ["文档"],
    "printed_page": ["印刷页"],
}

MEDIA_EXT = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".mp4", ".mov", ".m4v"}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_tag(item: str) -> dict:
    m = re.match(r"^(\S+)\s+([0-9.]+)$", item.strip())
    if not m:
        return {"id": item, "confidence": None, "zh": TAG_ZH.get(item, [])}
    ident, conf = m.group(1), float(m.group(2))
    return {"id": ident, "confidence": conf, "zh": TAG_ZH.get(ident, [])}


def searchable_from_vision(ocr: list, tags: list[dict], animals: list, barcodes: list, people: int) -> str:
    parts: list[str] = []
    parts.extend(ocr)
    for t in tags:
        parts.append(t["id"])
        parts.extend(t.get("zh") or [])
    parts.extend(animals)
    parts.extend(barcodes)
    if people:
        parts.append("人")
        parts.append("people")
    return " ".join(dict.fromkeys(p for p in parts if p))


def load_probe(library: Path) -> dict[str, dict]:
    report = library / "vision-probe-report.json"
    if not report.exists():
        return {}
    out = {}
    for row in json.loads(report.read_text(encoding="utf-8")):
        path = Path(row["path"])
        try:
            rel = path.relative_to(library).as_posix()
        except ValueError:
            continue
        out[rel] = row
    return out


def load_matrix_captions() -> dict[str, dict]:
    if MATRIX_DATA is None:
        return {}
    src = MATRIX_DATA / "media-captions.json"
    if not src.exists():
        return {}
    data = json.loads(src.read_text(encoding="utf-8"))
    items = data.get("items") or {}
    return items if isinstance(items, dict) else {}


def sidecar_path(library: Path, rel: str) -> Path:
    return library / "scanner" / f"{rel}.json"


def collect_media(library: Path) -> list[Path]:
    skip = {"scanner", ".git"}
    files = []
    for dirpath, dirnames, filenames in os.walk(library):
        dirnames[:] = [d for d in dirnames if d not in skip and not d.startswith(".")]
        root = Path(dirpath)
        for name in filenames:
            path = root / name
            if path.suffix.lower() in MEDIA_EXT:
                files.append(path)
    return sorted(files)


def build_record(library: Path, path: Path, probe: dict, matrix: dict) -> dict:
    rel = path.relative_to(library).as_posix()
    stat = path.stat()
    kind = "video" if path.suffix.lower() in {".mp4", ".mov", ".m4v"} else "image"
    record = {
        "version": 1,
        "sourceRelative": rel,
        "kind": kind,
        "hash": sha256_file(path),
        "size": stat.st_size,
        "mtime": int(stat.st_mtime),
        "scannedAt": datetime.now(timezone.utc).isoformat(),
        "keyframes": [],
    }
    row = probe.get(rel)
    if row:
        tags = [parse_tag(t) for t in row.get("tags") or []]
        vision = {
            "ocr": row.get("ocr") or [],
            "tags": tags,
            "animals": row.get("animals") or [],
            "peopleCount": row.get("peopleCount") or 0,
            "barcodes": row.get("barcodes") or [],
            "featurePrintDims": row.get("featurePrintDims") or 0,
        }
        vision["searchableText"] = searchable_from_vision(
            vision["ocr"], tags, vision["animals"], vision["barcodes"], vision["peopleCount"]
        )
        record["localScan"] = {"vision": vision}
    cap = matrix.get(rel)
    if isinstance(cap, dict):
        analysis = cap.get("analysis") if isinstance(cap.get("analysis"), dict) else {}
        record["quickScan"] = {"en": analysis}
    return record


def load_file_analyses() -> dict:
    if MATRIX_DATA is None:
        return {}
    src = MATRIX_DATA / "file-analyses.json"
    if not src.exists():
        return {}
    data = json.loads(src.read_text(encoding="utf-8"))
    items = data.get("items") or {}
    return items if isinstance(items, dict) else {}


def write_document_analyses(library: Path) -> int:
    items = load_file_analyses()
    n = 0
    for rel, item in items.items():
        path = library / rel
        if not path.is_file():
            continue
        dest = sidecar_path(library, rel)
        dest.parent.mkdir(parents=True, exist_ok=True)
        one = str(item.get("oneLineSummary") or "")
        detailed = str(item.get("detailedSummary") or "")
        record = {
            "version": 1,
            "sourceRelative": rel,
            "kind": item.get("kind") or "document",
            "hash": item.get("hash") or sha256_file(path),
            "size": path.stat().st_size,
            "mtime": int(path.stat().st_mtime),
            "scannedAt": datetime.now(timezone.utc).isoformat(),
            "keyframes": [],
            "quickScan": {
                "en": {
                    "title": path.name,
                    "caption": one,
                    "detailedSummary": detailed,
                    "searchableText": f"{one} {detailed[:1200]}".strip(),
                },
            },
        }
        dest.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(dest.relative_to(library).as_posix())
        n += 1
    return n


def main() -> None:
    global MATRIX_DATA
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True, help="Library root; existing sidecars may be replaced, back them up first")
    parser.add_argument("--matrix-data", type=Path, help="Optional legacy .matrix directory")
    args = parser.parse_args()
    library = args.library.expanduser().resolve()
    MATRIX_DATA = args.matrix_data.expanduser().resolve() if args.matrix_data else None
    if not library.is_dir():
        parser.error("--library must be an existing directory")
    if MATRIX_DATA is not None and not MATRIX_DATA.is_dir():
        parser.error("--matrix-data must be an existing directory")
    probe = load_probe(library)
    matrix = load_matrix_captions()
    written = 0
    for path in collect_media(library):
        rel = path.relative_to(library).as_posix()
        dest = sidecar_path(library, rel)
        dest.parent.mkdir(parents=True, exist_ok=True)
        record = build_record(library, path, probe, matrix)
        dest.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        written += 1
        print(dest.relative_to(library).as_posix())
    written += write_document_analyses(library)
    print(f"wrote {written} sidecars")


if __name__ == "__main__":
    main()

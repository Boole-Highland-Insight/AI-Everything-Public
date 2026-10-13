#!/usr/bin/env python3
"""Validate count, distribution, hashes, and file integrity for the benchmark."""

from __future__ import annotations

import hashlib
import json
import zipfile
from collections import Counter, defaultdict
from pathlib import Path

from PIL import Image
from pypdf import PdfReader


ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / "labels.jsonl"
EXPECTED_MEDIA = {"text": 30, "image": 25, "pdf": 25, "pptx": 20}
EXPECTED_LABELS = {"completion": 25, "optimization": 20, "none": 45, "duplicate": 10}


def sha256(path: Path) -> str:
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return digest


def main() -> None:
    rows = [json.loads(line) for line in MANIFEST.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert len(rows) == 100, f"expected 100 rows, got {len(rows)}"
    assert len({row["id"] for row in rows}) == 100, "duplicate ids"
    assert Counter(row["media_type"] for row in rows) == Counter(EXPECTED_MEDIA)
    assert Counter(row["label"] for row in rows) == Counter(EXPECTED_LABELS)

    groups: dict[str, list[dict]] = defaultdict(list)
    hashes: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        path = ROOT / row["relative_path"]
        assert path.is_file(), path
        assert sha256(path) == row["sha256"], f"hash drift: {path}"
        hashes[row["sha256"]].append(row)
        if row["media_type"] == "image":
            with Image.open(path) as image:
                image.verify()
        elif row["media_type"] == "pdf":
            reader = PdfReader(str(path))
            assert len(reader.pages) >= 1
        elif row["media_type"] == "pptx":
            with zipfile.ZipFile(path) as archive:
                bad = archive.testzip()
                assert bad is None, f"bad PPTX member: {bad}"
                assert "ppt/presentation.xml" in archive.namelist()
        if row["duplicate_group"]:
            groups[row["duplicate_group"]].append(row)

    assert len(groups) == 5, f"expected 5 duplicate groups, got {len(groups)}"
    for group, members in groups.items():
        assert len(members) == 2, f"{group} has {len(members)} members"
        assert len({member["sha256"] for member in members}) == 1, f"{group} is not byte-identical"
    repeated_hashes = [members for members in hashes.values() if len(members) > 1]
    assert len(repeated_hashes) == 5, f"unexpected byte-identical groups: {len(repeated_hashes)}"
    for members in repeated_hashes:
        assert len(members) == 2, f"unexpected duplicate count: {len(members)}"
        assert len({member["duplicate_group"] for member in members}) == 1
        assert members[0]["duplicate_group"] is not None, "unlabelled byte-identical files"
    print(json.dumps({"instances": 100, "media": EXPECTED_MEDIA, "labels": EXPECTED_LABELS, "duplicateGroups": 5}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

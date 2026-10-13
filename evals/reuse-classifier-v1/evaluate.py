#!/usr/bin/env python3
"""Score JSONL predictions against labels.jsonl without third-party dependencies."""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path


LABELS = ("completion", "optimization", "none", "duplicate")


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("predictions", type=Path, help='JSONL rows: {"id":"...","predicted_label":"..."}')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    gold = {row["id"]: row for row in read_jsonl(root / "labels.jsonl")}
    predictions = {row["id"]: row["predicted_label"] for row in read_jsonl(args.predictions)}
    missing_ids = sorted(set(gold) - set(predictions))
    extra_ids = sorted(set(predictions) - set(gold))
    if missing_ids or extra_ids:
        raise SystemExit(json.dumps({"missingIds": missing_ids, "extraIds": extra_ids}, ensure_ascii=False, indent=2))
    unknown = sorted({label for label in predictions.values() if label not in LABELS})
    if unknown:
        raise SystemExit(f"unknown predicted labels: {unknown}")

    confusion = defaultdict(Counter)
    errors = []
    for instance_id, row in gold.items():
        actual = row["label"]
        predicted = predictions[instance_id]
        confusion[actual][predicted] += 1
        if actual != predicted:
            errors.append({"id": instance_id, "actual": actual, "predicted": predicted, "path": row["relative_path"]})

    per_class = {}
    for label in LABELS:
        tp = confusion[label][label]
        fn = sum(confusion[label].values()) - tp
        fp = sum(confusion[other][label] for other in LABELS if other != label)
        per_class[label] = {
            "support": sum(confusion[label].values()),
            "precision": round(tp / (tp + fp), 4) if tp + fp else None,
            "recall": round(tp / (tp + fn), 4) if tp + fn else None,
            "misses": fn,
            "falsePositives": fp,
        }
    correct = sum(confusion[label][label] for label in LABELS)
    print(json.dumps({
        "instances": len(gold),
        "accuracy": round(correct / len(gold), 4),
        "correct": correct,
        "errors": len(errors),
        "perClass": per_class,
        "confusion": {label: dict(confusion[label]) for label in LABELS},
        "errorItems": errors,
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

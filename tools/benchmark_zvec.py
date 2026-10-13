#!/usr/bin/env python3
"""Offline ANN feasibility benchmark against a copied AI Everything SQLite database."""

import argparse
import json
import os
import shutil
import sqlite3
import tempfile
import time

import numpy as np
import zvec


FORMAT = "f16-le-v1-normalized"


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, min(len(ordered) - 1, int(np.ceil(len(ordered) * fraction)) - 1))]


def directory_size(path: str) -> int:
    return sum(os.path.getsize(os.path.join(root, name)) for root, _, names in os.walk(path) for name in names)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("database", help="Path to a SQLite backup, never the live database")
    parser.add_argument("root", help="Authorized root path represented in that database")
    parser.add_argument("--queries", type=int, default=20)
    parser.add_argument("--top-k", type=int, default=80)
    args = parser.parse_args()
    if args.queries < 1 or args.top_k < 1:
        raise SystemExit("queries and top-k must be positive")

    connection = sqlite3.connect(f"file:{os.path.abspath(args.database)}?mode=ro", uri=True)
    root_id = connection.execute("SELECT id FROM roots WHERE path=? AND active=1", (args.root,)).fetchone()
    if root_id is None:
        raise SystemExit("root is not active in this database")
    space = connection.execute(
        """
        SELECT x.model_key,x.dimensions,count(*)
        FROM chunks c JOIN files f ON f.current_version_id=c.version_id
        JOIN features x ON x.subject_type='content_unit' AND x.subject_id=c.id
          AND x.content_hash=c.content_hash AND x.feature_type='text_embedding'
          AND x.vector_format=?
        WHERE f.present=1 AND f.root_id=?
        GROUP BY x.model_key,x.dimensions ORDER BY count(*) DESC LIMIT 1
        """,
        (FORMAT, root_id[0]),
    ).fetchone()
    if space is None:
        raise SystemExit("no current vectors for this root")
    space_id, dimensions, _ = space
    rows = connection.execute(
        """
        SELECT c.id,x.vector_blob
        FROM chunks c JOIN files f ON f.current_version_id=c.version_id
        JOIN features x ON x.subject_type='content_unit' AND x.subject_id=c.id
          AND x.content_hash=c.content_hash AND x.feature_type='text_embedding'
          AND x.vector_format=? AND x.model_key=?
        WHERE f.present=1 AND f.root_id=? ORDER BY c.id
        """,
        (FORMAT, space_id, root_id[0]),
    ).fetchall()
    connection.close()
    ids = [row[0] for row in rows]
    vectors = np.stack([
        np.frombuffer(row[1], dtype="<f2", count=dimensions, offset=12).astype(np.float32)
        for row in rows
    ])
    queries = vectors[: min(args.queries, len(vectors))]
    top_k = min(args.top_k, len(vectors))

    zvec.init(log_type=zvec.LogType.CONSOLE, log_level=zvec.LogLevel.ERROR, query_threads=1, optimize_threads=2)
    temporary = tempfile.mkdtemp(prefix="aie-zvec-benchmark-")
    directory = os.path.join(temporary, "collection")
    try:
        started = time.perf_counter()
        schema = zvec.CollectionSchema(
            name="aie_vectors",
            vectors=[zvec.VectorSchema(
                name="embedding",
                data_type=zvec.DataType.VECTOR_FP32,
                dimension=dimensions,
                index_param=zvec.HnswIndexParam(metric_type=zvec.MetricType.COSINE),
            )],
        )
        collection = zvec.create_and_open(path=directory, schema=schema)
        for start in range(0, len(ids), 256):
            collection.insert([
                zvec.Doc(id=ids[index], vectors={"embedding": vectors[index].tolist()})
                for index in range(start, min(start + 256, len(ids)))
            ])
        collection.optimize()
        build_seconds = time.perf_counter() - started

        latencies = []
        recalls = []
        for query in queries:
            exact = np.argpartition(-(vectors @ query), top_k - 1)[:top_k]
            exact_ids = {ids[index] for index in exact}
            started = time.perf_counter()
            results = collection.query(
                queries=zvec.Query(field_name="embedding", vector=query.tolist()),
                topk=top_k,
                output_fields=[],
            )
            latencies.append((time.perf_counter() - started) * 1_000)
            recalls.append(len(exact_ids.intersection(result.id for result in results)) / top_k)
        report = {
            "backend": "zvec-hnsw-0.7.0",
            "candidateCount": len(ids),
            "dimensions": dimensions,
            "queryCount": len(queries),
            "topK": top_k,
            "buildSeconds": build_seconds,
            "indexBytes": directory_size(directory),
            "p50Milliseconds": percentile(latencies, 0.50),
            "p95Milliseconds": percentile(latencies, 0.95),
            "meanRecallAtK": float(np.mean(recalls)),
            "minimumRecallAtK": float(np.min(recalls)),
        }
        print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


if __name__ == "__main__":
    main()

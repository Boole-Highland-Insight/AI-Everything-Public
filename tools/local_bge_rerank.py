#!/usr/bin/env python3
import json
import sys
import os
import time
import resource

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer


audit_path = os.environ.get("AIE_AUDIT_TRACE_PATH", "")
audit = audit_path.startswith(("/tmp/", "/private/tmp/"))
load_started = time.monotonic()
model_id = "BAAI/bge-reranker-v2-m3"
device = "mps" if torch.backends.mps.is_available() else "cpu"
dtype = torch.float16 if device == "mps" else torch.float32
tokenizer = AutoTokenizer.from_pretrained(model_id, local_files_only=True)
model = AutoModelForSequenceClassification.from_pretrained(
    model_id, dtype=dtype, local_files_only=True
).to(device).eval()
load_ms = (time.monotonic() - load_started) * 1000


def memory_stats():
    # macOS ru_maxrss is bytes and a lifetime high-water mark, not current RSS.
    result = {"worker_peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
    if device == "mps":
        for name in ("current_allocated_memory", "driver_allocated_memory"):
            try:
                result["mps_" + name + "_bytes"] = getattr(torch.mps, name)()
            except (AttributeError, RuntimeError):
                pass
    return result


for line in sys.stdin:
    try:
        message = json.loads(line)
        pairs = message.get("pairs", [])
        started = time.monotonic()
        cpu_started = time.process_time() if audit else 0
        tokenize_ms = 0
        details = {}
        diagnostic_ms = 0
        if pairs:
            inputs = tokenizer(
                pairs, padding=True, truncation=True, max_length=512, return_tensors="pt"
            )
            if audit:
                inspection_started = time.monotonic()
                lengths = inputs["attention_mask"].sum(dim=1).tolist()
                details = {"pair_count": len(pairs), "pair_tokens_after_truncation": lengths,
                           "padded_tokens_per_pair": inputs["input_ids"].shape[1],
                           "padded_token_slots": inputs["input_ids"].numel(),
                           "nonpadding_tokens": sum(lengths),
                           "pairs_at_token_cap": sum(n == 512 for n in lengths)}
                details.update(memory_stats())
                diagnostic_ms = (time.monotonic() - inspection_started) * 1000
            inputs = inputs.to(device)
            tokenize_ms = (time.monotonic() - started) * 1000
            execute_started = time.monotonic()
            with torch.inference_mode():
                scores = model(**inputs).logits.view(-1).float().cpu().tolist()
            execute_ms = (time.monotonic() - execute_started) * 1000
        else:
            scores = []
            execute_ms = 0
        response = {"scores": scores}
        if audit:
            cpu_ms = (time.process_time() - cpu_started) * 1000
            details.update(memory_stats())
            response["audit"] = {**details, "load_ms": load_ms,
                                 "tokenize_ms": tokenize_ms - diagnostic_ms,
                                 "diagnostic_ms": diagnostic_ms,
                                 "execute_ms": execute_ms, "worker_cpu_ms": cpu_ms,
                                 "device": device, "worker_pid": os.getpid(),
                                 "request_trace_id": message.get("trace_id")}
        print(json.dumps(response), flush=True)
        load_ms = 0
    except Exception as error:
        print(json.dumps({"error": str(error)}), flush=True)

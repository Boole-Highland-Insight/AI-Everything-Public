#!/usr/bin/env python3
"""Pull into the private Ollama service and publish bounded, non-secret UI progress."""
import argparse
import json
import os
import urllib.request

ENDPOINT = "http://127.0.0.1:11435"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model")
    parser.add_argument("--digest")
    args = parser.parse_args()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def installed():
        with opener.open(ENDPOINT + "/api/tags", timeout=10) as response:
            return next((m for m in json.load(response).get("models", [])
                         if m.get("name") == args.model), None)

    current = installed()
    if current and current.get("digest") and (not args.digest or current["digest"] == args.digest):
        print("Reusing installed model: " + args.model)
        return
    progress = os.environ.get("AIE_INSTALL_PROGRESS_FILE")
    handle = None
    if progress:
        fd = os.open(progress, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        handle = os.fdopen(fd, "w", encoding="utf-8")
    try:
        request = urllib.request.Request(
            ENDPOINT + "/api/pull",
            data=json.dumps({"model": args.model, "stream": True}).encode(),
            headers={"Content-Type": "application/json"},
        )
        final = {}
        with opener.open(request, timeout=120) as response:
            for line in response:
                final = json.loads(line)
                if final.get("error"):
                    raise RuntimeError("Local model download failed")
                if handle:
                    # Rewrite the latest event only, so long downloads do not grow a log forever.
                    handle.seek(0)
                    handle.truncate()
                    handle.write(json.dumps({
                        "aiePhase": "下载 " + args.model,
                        "completed": final.get("completed"), "total": final.get("total"),
                    }) + "\n")
                    handle.flush()
        if final.get("status") != "success":
            raise RuntimeError("Model download did not complete")
        current = installed()
        if not current or not current.get("digest"):
            raise RuntimeError("Downloaded model is not visible to the local runtime")
        if args.digest and current["digest"] != args.digest:
            raise RuntimeError("Model digest mismatch")
        print("Local model ready: " + args.model)
    finally:
        if handle:
            handle.close()


if __name__ == "__main__":
    main()

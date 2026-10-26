#!/usr/bin/env python3
"""Build the relocatable, offline BGE dependency bundle (Apple Silicon)."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
PYTHON_ARCHIVE = "cpython-3.11.17+20261003-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_SHA256 = "0c9fbd0b2ddfbb6877493a650259bf379ee71a91b17f0f5f06dd2dcd52fbcade"
MODEL_REVISION = "953dc6f6f85a1b2dbfca4c34a2796e7dde08d41e"
MODEL_SHA256 = "d9e3e081faff1eefb84019509b2f5558fd74c1a05a2c7db22f74174fcedb5286"
REQUIREMENTS = ROOT / "tools/bge-requirements.txt"


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def download(url, path):
    if not path.exists():
        temporary = path.with_suffix(path.suffix + ".partial")
        with urllib.request.urlopen(url) as source, temporary.open("wb") as output:
            shutil.copyfileobj(source, output)
        temporary.replace(path)


def main():
    if platform.machine() != "arm64" or os.environ.get("AIE_ARCH", "arm64") != "arm64":
        raise SystemExit("The bundled BGE release currently requires Apple Silicon.")
    destination = Path(sys.argv[1]).resolve()
    cache = ROOT / ".build/bge-distribution"
    bundle = cache / "BGERuntime"
    cache.mkdir(parents=True, exist_ok=True)
    marker = bundle / "SOURCE.json"
    build_id = hashlib.sha256(Path(__file__).read_bytes() + REQUIREMENTS.read_bytes()).hexdigest()
    if not marker.exists() or json.loads(marker.read_text()).get("builder_sha256") != build_id:
        archive = cache / PYTHON_ARCHIVE
        download("https://github.com/astral-sh/python-build-standalone/releases/download/20261003/"
                 + PYTHON_ARCHIVE.replace("+", "%2B"), archive)
        if digest(archive) != PYTHON_SHA256:
            raise SystemExit("Portable Python checksum mismatch")
        if bundle.exists():
            shutil.rmtree(bundle)
        bundle.mkdir()
        with tarfile.open(archive) as source:
            source.extractall(bundle)
        python = bundle / "python/bin/python3"
        environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1")
        environment.pop("PYTHONPATH", None)
        environment.pop("PYTHONHOME", None)
        subprocess.run([str(python), "-m", "pip", "install", "--no-compile", "--only-binary=:all:",
                        "-r", str(REQUIREMENTS)], env=environment, check=True)
        subprocess.run([str(python), "-m", "pip", "check"], env=environment, check=True)
        model = bundle / "model"
        model.mkdir()
        source = cache / "original-model"
        source.mkdir(parents=True, exist_ok=True)
        existing = Path(os.environ.get("AIE_BGE_MODEL_SOURCE", str(source)))
        base_url = "https://huggingface.co/BAAI/bge-reranker-v2-m3/resolve/" + MODEL_REVISION + "/"
        original = existing / "model.safetensors" if (existing / "model.safetensors").exists() else source / "model.safetensors"
        download(base_url + original.name, original)
        if digest(original) != MODEL_SHA256:
            raise SystemExit("BGE original model checksum mismatch")
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json",
                     "special_tokens_map.json", "sentencepiece.bpe.model", "README.md"]:
            # Only public model files are copied, never cache credentials or metadata.
            public_file = existing / name if (existing / name).exists() else source / name
            download(base_url + name, public_file)
            shutil.copy2(public_file, model / name)
        # The tested Apple Silicon worker already runs float16 on MPS. Store that
        # representation to avoid shipping an unused second half of each FP32 weight.
        subprocess.run([str(python), "-c", """
import sys, torch
from safetensors.torch import load_file, save_file
weights = load_file(sys.argv[1])
save_file({k: v.to(torch.float16) if v.is_floating_point() else v for k, v in weights.items()},
          sys.argv[2], metadata={"format": "pt"})
""", str(original), str(model / "model.safetensors")], env=environment, check=True)
        shutil.copy2(ROOT / "apps/macos/AIEPopup/Resources/EmbeddingGemma2-APACHE-2.0.txt",
                     model / "LICENSE-APACHE-2.0.txt")
        packages = subprocess.check_output([str(python), "-m", "pip", "freeze"], env=environment, text=True)
        marker.write_text(json.dumps({"builder_sha256": build_id, "python_archive": PYTHON_ARCHIVE,
            "python_sha256": PYTHON_SHA256, "model": "BAAI/bge-reranker-v2-m3",
            "revision": MODEL_REVISION, "original_sha256": MODEL_SHA256,
            "distribution_dtype": "float16", "model_sha256": digest(model / "model.safetensors"),
            "packages": packages.splitlines()}, indent=2) + "\n")
    shutil.copy2(ROOT / "tools/local_bge_rerank.py", bundle / "local_bge_rerank.py")
    if destination != bundle:
        shutil.copytree(bundle, destination, symlinks=True, dirs_exist_ok=True)
    print("Offline BGE runtime ready:", destination, flush=True)


if __name__ == "__main__":
    main()

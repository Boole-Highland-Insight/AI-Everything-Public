#!/usr/bin/env python3
"""Check staged files before publishing; report locations without secret values."""
import re
import subprocess
import sys
from pathlib import PurePosixPath

PATTERNS = {
    "API credential": re.compile(rb"sk-(?:or-v1-)?[A-Za-z0-9_-]{24,}"),
    "GitHub credential": re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})"),
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
}


def main():
    paths = subprocess.check_output(["git", "ls-files", "--cached", "-z"]).split(b"\0")
    count, issues = 0, 0
    for raw in filter(None, paths):
        name = raw.decode("utf-8")
        path = PurePosixPath(name)
        if (any(part in {"build", "scanner", "__pycache__"} or part.endswith(".app") for part in path.parts)
                or path.name == ".DS_Store" or path.suffix in {".key", ".pem", ".p12", ".p8", ".log"}
                or (path.name.startswith(".env") and path.name != ".env.example")):
            print(f"Excluded runtime/secret file staged: {name}")
            issues += 1
        data = subprocess.check_output(["git", "show", ":" + name])
        count += 1
        for label, pattern in PATTERNS.items():
            for match in pattern.finditer(data):
                line = data[:match.start()].count(b"\n") + 1
                print(f"Possible {label}: {name}:{line}")
                issues += 1
        if name.startswith(("apps/", "tools/")) and re.search(rb"/Users/[A-Za-z0-9._-]+/", data):
            print(f"Machine-specific absolute path: {name}")
            issues += 1
    if count == 0:
        print("No staged/tracked files. Stage the intended source files first.")
        return 1
    print(f"Checked {count} staged files; {issues} findings. Secret values are never printed.")
    return bool(issues)


if __name__ == "__main__":
    sys.exit(main())

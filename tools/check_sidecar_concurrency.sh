#!/bin/bash
# Compatibility entry point; runtime sidecars were replaced by SQLite transactions.
set -euo pipefail
exec bash "$(dirname "$0")/check_database_concurrency.sh"

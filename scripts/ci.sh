#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FORGE="$(bash scripts/find-forge.sh)"

export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-ci}"

bash scripts/bootstrap.sh
"$FORGE" fmt --check
"$FORGE" build
"$FORGE" test

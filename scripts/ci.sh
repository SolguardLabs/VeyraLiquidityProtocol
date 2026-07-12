#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v forge >/dev/null 2>&1; then
  echo "forge no está disponible en PATH" >&2
  exit 127
fi

export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-ci}"

forge fmt --check
forge build
forge test


#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
exec env DUNE_CACHE="${DUNE_CACHE:-disabled}" dune exec ./ocaml/bin/deterministic_cli.exe -- "$@"

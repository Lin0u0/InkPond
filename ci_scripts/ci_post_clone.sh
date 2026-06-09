#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"

cd "$REPO_ROOT"

if [[ -f "$HOME/.cargo/env" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.cargo/env"
fi

if ! command -v cargo >/dev/null 2>&1 || ! command -v rustup >/dev/null 2>&1; then
  echo "Rust toolchain not found. Installing rustup minimal profile..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  # shellcheck source=/dev/null
  source "$HOME/.cargo/env"
fi

if [[ -z "${CARGO_BUILD_JOBS:-}" ]]; then
  CARGO_BUILD_JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  export CARGO_BUILD_JOBS
fi

"$REPO_ROOT/scripts/ensure_typst_xcframework.sh"

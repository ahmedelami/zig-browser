#!/usr/bin/env bash
set -euo pipefail

if command -v zig >/dev/null 2>&1; then
  echo "zig already installed: $(zig version)"
  exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install brew first, then re-run."
  exit 1
fi

brew install zig
echo "installed zig: $(zig version)"


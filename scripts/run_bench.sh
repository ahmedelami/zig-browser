#!/usr/bin/env bash
set -euo pipefail

# Placeholder for the M0 bench harness.
# Runs the Zig bench runner which exercises the multi-process bootstrap.

zig build -Doptimize=ReleaseFast
zig build bench -Doptimize=ReleaseFast -- --iterations 10

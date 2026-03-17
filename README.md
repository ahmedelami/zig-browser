# zig-browser

Goal: a modern desktop web browser built **from scratch in Zig**, optimized for “instant” UX end-to-end.

## Project potential rating

**Rating: 8/10 (High potential).**

Why:
- Clear and ambitious scope (multi-process browser architecture in Zig).
- Practical developer workflow already exists (`run`, `bench`, `navbench`, `inspect`, `guardrails`).
- Strong upside if performance and standards compatibility continue improving with roadmap milestones.

Project plan: `plan_progress.md`

## Quick start (macOS)

1. Install Zig:
   - `brew install zig`
2. Build:
   - `zig build`
3. Run the bootstrap multi-process skeleton:
   - `zig build run`
   - Tip: in the GUI address bar, typing a plain query (e.g. `zig language`) searches via **Google**.
     - Override: `zig build run -- --search-engine ddg` (DuckDuckGo Lite, works without JS) or `zig build run -- --search-engine bing`
   - To run headless/oneshot (used by benchmarks): `zig build run -- --oneshot`
   - To run headless navigation (no AppKit window; exits on nav done or timeout): `zig build run -- --headless --url https://example.com --quit-after-ms 8000`
   - To auto-exit after N ms (useful for smoke tests): `zig build run -- --quit-after-ms 2000`
   - By default, `zig build run` (with auto-generated run dirs) writes debug artifacts and prints an ASCII preview on exit.
     - Disable: `zig build run -- --no-artifacts`
     - Logs are still captured under `run/` unless you pass `--no-logs`
     - Inspect latest: `zig build inspect -- --latest` (add `--ascii` if artifacts are enabled; add `--verbose` for full DOM/layout/display-list dumps)
       - JS dev: `renderer_scripts.txt` lists captured inline scripts; `renderer_scripts/` contains dumped `script_*.js` files for analysis.
     - Open the latest rendered frame (macOS): `zig build inspect -- --latest --open` or `zig build run -- --headless --url https://example.com --open`

Outputs go under `run/` (IPC sockets + per-process trace files).
Each run also writes `machine.json` with detected hardware/OS/toolchain details.

## Debugging

- Probe TLS/HTTP quickly: `zig build tlsprobe -- --url https://news.ycombinator.com --http`

## Guardrails (anti “god modules”)

`zig build` runs guardrails automatically (see `guardrails.json`).

- Run explicitly: `zig build guardrails`
- Build + guardrails: `zig build check`

## Bench (M0)

- `zig build bench -- --iterations 10`
- UI first-frame bench (opens a window briefly): `zig build bench -- --ui --iterations 10`
- Budgets live in `bench/budgets.json` (very loose in M0; tighten as we add real rendering milestones).

## Nav bench (page load)

- Warm-cache timings: `zig build navbench -- --url https://news.ycombinator.com --iterations 20`
- Cold timings (clears disk cache each iter): `zig build navbench -- --url https://example.com --iterations 10 --cold`
- Per-iter output: `--verbose` (add `--artifacts` if you want render artifacts per iter)

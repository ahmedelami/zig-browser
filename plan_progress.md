# Instant Zig Browser — Plan & Progress

Last updated: 2026-02-09

This file is the source of truth for the project plan and ongoing progress. The goal is a modern, “instant” desktop web browser built **from scratch in Zig**, end-to-end.

## Status

- Phase: Bootstrap
- Current focus: **Streaming navigation + streaming HTML→DOM→layout→paint for “instant” first paint + scroll-driven repaints**

## Baseline Machine (detected)

Captured automatically per run in `run/*/machine.json`.

- Chip: **Apple M4** (sysctl `machdep.cpu.brand_string`)
- Model: **Mac16,13** (sysctl `hw.model`)
- CPU cores: **10** total (**4P + 6E**) (sysctl `hw.ncpu` + `hw.perflevel*`)
- Memory: **16 GiB** (17179869184 bytes; sysctl `hw.memsize`)
- OS: **macOS 26.2** (build **25C56**; Darwin **25.2.0**) (sysctl `kern.*`)
- Zig: **0.15.2**

Note: we’re optimizing for **this** laptop/hardware right now (no cross-machine baselines yet).

## Progress Checklist

### M0 — Toolchain, Build, and Tracing Backbone
- [x] Zig toolchain bootstrap script (`scripts/install_zig_macos.sh`)
- [x] Multi-process launcher + supervisor (`zb_browser` spawns `zb_net`/`zb_renderer`/`zb_gpu`)
- [x] IPC transport + schema versioning (magic + `wire_version`)
- [x] Always-on tracing (Chrome Trace Event JSON per process under `run/`)
- [x] Debug artifacts (dev mode): auto-run writes `gpu_last_frame.ppm` + `gpu_last_display_list.*`, and `zb_inspect --ascii` renders a terminal preview (disable with `--no-artifacts`)
- [x] Per-process logs: child `stdout`/`stderr` captured under `run/` (`net_*.log`, `renderer_*.log`, `gpu_*.log`) and surfaced by `zb_inspect`
- [x] `zb_inspect`: concise previews by default; pass `--verbose` for full dumps (DOM/layout/display list)
- [x] Headless navigation mode: `zig build run -- --headless --url https://example.com` (no AppKit window; exits on nav done/timeout)
- [x] Latest-run pointer: `run/latest.txt` lets tools default to the most recent auto-run directory
- [x] Perf budgets + bench runner + regression gates (`zig build bench`, `bench/budgets.json`)
- [x] Navigation bench harness (`zig build navbench -- --url https://example.com --iterations 20 [--cold]`)
- [x] Guardrails: file size/lines/import/export limits enforced on build (`zig build guardrails`, `guardrails.json`)

### M1 — Window + GPU Compositor + `about:` Pages
- [x] macOS window + `CAMetalLayer` + **present shared IOSurface** (GPU raster → UI blit)
- [x] Shared framebuffer via **IOSurface** (macOS-only, local laptop target)
- [ ] macOS window + Metal swapchain in GPU process
- [x] Minimal UI chrome rendered in-engine (top bar + URL)
- [x] Address bar input + Enter navigation (macOS)
- [x] Address bar search heuristic: non-URL text maps to Google search (`--search-engine ddg|bing` overrides)
- [x] Nav thread event loop: input responsive during streaming loads (poll net/renderer/input; request_id-based cancellation)
- [x] Scroll wheel: vertical scroll offset for content (macOS)
- [x] Mouse click: open links via hit-testing (macOS)
- [ ] Tabs (multi-session UI)
- [x] Back/forward/reload + history (`:back`, `:forward`, `:reload`)
- [x] `about:blank`, `about:version`, `about:tracing`, `about:help`, `about:metrics`, `about:cache`
- [x] `about:js` (inline JS smoke test)
- [ ] Damage tracking + frame scheduling scaffolding

### M2 — Networking Stack v1 (Real Internet)
- [x] Streaming fetch over IPC (begin/chunk/end) + progressive updates
- [x] Net fetch end status/result/bytes forwarded to renderer (shown in header)
- [x] In-memory response cache (URL → body; streams cache hits over IPC)
- [x] Persistent disk response cache (`run/http-cache`) + cache source surfaced (`src=mem|disk|net`)
- [x] Post-load same-host link prefetch (warms in-memory cache)
- [x] Request cancellation IPC (browser→net) + socket shutdown
- [ ] WHATWG URL parsing/canonicalization
- [ ] DNS + caching
- [x] TCP + TLS (Zig): TLS 1.2/1.3; supports TLS 1.2 ECDSA-only hosts (forked stdlib TLS client)
- [x] HTTP/1.1 GET + redirects + chunked + keep-alive
- [ ] gzip/deflate decompression (blocked by Zig stdlib flate panics; we currently avoid negotiating `Accept-Encoding` and fail fast if a server still sends compressed bodies)
- [x] HTTP keep-alive + connection pooling
- [x] Cookies v0 (network-only): ingest `Set-Cookie` + send `Cookie` headers on subsequent requests
- [x] Cookies v0.5 (plumbing): renderer can set cookies via `document.cookie = "..."` (setter-only; forwarded to net cookie jar)
- [ ] Cache + cookies (v1) (full: partitioning, persistence, `document.cookie`, etc.)

### M3 — HTML + DOM + Basic Rendering (Progressive)
- [x] HTML tokenizer + tree builder (subset; chunk-safe; style/script raw-text mode)
- [x] DOM skeleton (tree only; title/body detection; no events yet)
- [x] Streaming parse → progressive display list updates (DOM + flow text layout)
- [x] Link rectangles attached to display lists (renderer → browser hit-testing)
- [ ] Incremental render safe points (avoid re-layout-from-root each update)
- [x] CSS parser v0 (tag selectors + global colors)
- [x] CSS selectors v0: tag/`.class`/`#id` for `color` + `background(-color)` with simple specificity + last-wins
- [x] CSS properties v0: `margin*` + `padding*` (px ints; applied as simple insets/spacing in text-flow layout)
- [x] Computed style v0: per-element `color` (inherited) + active background propagation (for text-flow)
- [x] Inline `style="..."` attribute parsing (color/bg/margin/padding) and application (highest precedence)
- [x] Inline `<style>` tag capture + CSS parsing (raw-text mode for style contents)
- [x] Stability: fixed inline `<style>` CSS lifetime bug (avoid selector slices dangling; YouTube no longer crashes)
- [x] External stylesheet fetch plumbing (renderer→browser→net→browser→renderer)
- [x] HTML entity decoding in `href` attributes (fix `&amp;` in stylesheet/link URLs; improves Wikipedia, etc.)
- [ ] Cascade + computed styles (beyond v0: inheritance tree, more properties, !important, compound selectors, invalidation)
- [x] Layout v0: flow text (word wrap; headings/lists; monospace)
- [x] Paint v0: display list text + `hr` rects
- [x] Paint v0.5: per-line background rects for active `background-color` (text-flow)
- [x] Scroll-driven repaints: browser sends scroll position; renderer repaints a clipped window (+overscan) so scrolling works past first viewport
- [ ] Paint v1: box backgrounds + borders (real box model)

### M4 — Fonts + Text Shaping (No OS text shortcuts)
- [ ] TTF/OTF parsing
- [ ] Glyph rasterizer + atlas
- [ ] Shaping + bidi + GSUB/GPOS (phased but real)
- [ ] Font fallback + caches

### M5 — CSS Coverage to Modern Layout
- [ ] Selector engine optimization + invalidation
- [ ] Layout: flexbox + grid + positioned + stacking
- [ ] Paint: transforms/opacity/shadows/gradients (phased)
- [ ] Compositing: layer heuristics + threaded scrolling

### M6 — JavaScript Engine (Full, in Zig)
- [x] Inline `<script>` capture (bounded) + ordered execution queue
- [x] JS v0 exec (best-effort): `console.log(...)`, `document.title = "..."`, `document.cookie = "..."` (setter-only), `location.replace("...")` (string-literal only)
- [ ] Parser + bytecode compiler
- [ ] VM + GC + modules (phased but real)
- [ ] Event loop + microtasks
- [ ] Web IDL binding layer to DOM
- [ ] test262 subset runner + dashboard outputs

### M7 — Core Web APIs
- [ ] Fetch + Streams + Encoding
- [ ] Storage: cookies/localStorage/sessionStorage (done earlier) + Cache Storage
- [ ] CORS/CSP/mixed-content plumbing
- [ ] Workers (later milestone, planned early)

### M8 — Media & Images (All Zig)
- [x] PNG decoder (subset; non-interlaced; common 8-bit modes including palette/gray)
- [ ] JPEG/GIF/WebP decoders (Zig)
- [ ] Animated images
- [ ] Canvas 2D (phased)
- [ ] Audio/video decoding (separate epic after images/canvas)

### M9 — Security, Sandboxing, Site Isolation Hardening
- [ ] Process-per-site-instance policy hardening
- [ ] Same-origin enforcement test suite
- [ ] macOS sandbox profiles per process type
- [ ] Crash recovery (sad tab) + resilience
- [ ] Continuous fuzzing for parsers/decoders

---

## Plan (decision-complete)

### Summary
Build a modern, standards-based desktop web browser **from scratch in Zig** (no Chromium/WebKit/Servo/CEF), targeting **Chromium-level compatibility ASAP** while optimizing for “instant” UX via **progressive rendering**, aggressive caching, and end-to-end latency budgeting.

Initial platform: **macOS**.  
Graphics: **Metal**.  
Security model: **multi-process sandboxed** (browser/UI, network, renderer(s), GPU).

“Instant” definition: the browser paints *something correct* ASAP and stays responsive; it continues refining progressively (streaming parse/style/layout/paint).

### Non-negotiable Constraints
- Engine written in Zig: HTML/CSS/JS/Web APIs/network/TLS/fonts/codecs/etc implemented in Zig.
- No embedding other engines or delegating core work to OS frameworks for web rendering or JS.
- No “shortcuts” in architecture: every subsystem is built as the real thing, even if delivered in milestones.

### High-level Architecture

#### Processes
1. **Browser/UI Process**
   - Windowing, input, tab/session model, permissions, UI chrome.
   - Owns process manager and policy (site isolation, sandbox profiles).
2. **Network Process**
   - DNS, TCP, TLS, HTTP/1.1 + HTTP/2 (HTTP/3 later), cache, cookies, proxy, cert store, Fetch plumbing.
3. **Renderer Process (per-site or per-site-instance)**
   - HTML parser → DOM → CSS → style → layout → paint → display lists.
   - JS engine + Web APIs (DOM bindings, events, timers, Fetch integration).
4. **GPU Process**
   - Metal device/queue, rasterization pipeline, texture upload, compositing, vsync scheduling.

#### IPC
- **Unix domain sockets** with a **binary, versioned protocol** (flat structs + varlen payloads).
- Strict message schemas, backpressure, tracing IDs, cancellation tokens.
- Capability-based handles (no ambient authority): renderer can only request resources via brokered interfaces.

#### Threading
- Each process uses:
  - one main event loop thread (`kqueue`)
  - worker pools for parsing/JS jobs/raster decode
  - dedicated “compositor” thread in GPU process for frame scheduling

### Repo Layout
- `README.md` (goals, build, run, perf gates)
- `docs/`
  - `architecture.md` (process model, IPC, sandboxing)
  - `perf_budget.md` (budgets + required metrics)
  - `standards_roadmap.md` (WPT/test262 milestones)
  - `security_model.md` (site isolation, same-origin, CSP, sandbox)
- `build.zig` / `build.zig.zon`
- `src/`
  - `browser/` (UI, tabs, navigation, permissions)
  - `ipc/` (schemas, codec, transport, tracing context)
  - `net/` (dns, tcp, tls, http1, http2, cache, cookies)
  - `engine/`
    - `html/` (tokenizer, tree builder)
    - `dom/` (nodes, events, GC integration)
    - `css/` (parser, cascade, computed styles)
    - `layout/` (block/inline/flex/grid; fragmentation)
    - `paint/` (display list, invalidation, text runs)
    - `compositor/` (layers, scrolling, transforms, hit-testing)
    - `media/` (images, later audio/video)
    - `fonts/` (ttf/otf parse, raster, shaping)
    - `js/` (parser, bytecode VM, GC, later JIT)
    - `webapi/` (fetch, url, encoding, timers, workers)
  - `gpu/` (metal backend, raster, text atlas, compositor)
  - `tools/` (in-tree utilities used by tests/bench)
- `tests/`
  - `unit/` (zig `test`)
  - `integration/` (spawn processes, scripted pages)
  - `wpt_harness/` (subset runner, expected failures)
  - `test262_harness/` (subset runner)
- `bench/`
  - `scenarios/` (cold start, nav, scroll, tab ops)
  - `runner/` (repeats, stats, regression gates)

### Milestones (no shortcuts, staged delivery)

#### M0 — Toolchain, Build, and Tracing Backbone
Deliver:
- Zig toolchain bootstrap scripts (install/verify).
- Multi-process launcher + supervisor.
- IPC transport + schema versioning + fuzzer seed corpus for codec.
- Always-on tracing (Chrome Trace Event JSON) with per-process clock sync at launch.
- Perf budgets defined and enforced in CI: cold start, input-to-frame latency, nav-to-first-meaningful-paint.

#### M1 — Window + GPU Compositor + `about:` Pages
Deliver:
- macOS window + Metal swapchain in GPU process.
- Browser UI chrome (tabs, address bar, back/forward/reload).
- Render `about:blank`, `about:version`, `about:tracing`.
- Compositor supports surfaces/transforms/clipping/scroll container + damage tracking.

#### M2 — Networking Stack v1 (Real Internet)
Deliver:
- WHATWG URL parsing + canonicalization.
- DNS resolver with caching.
- TCP + TLS (Zig) + cert validation.
- HTTP/1.1 keep-alive + gzip/deflate + caching basics.
- Fetch plumbing skeleton.

#### M3 — HTML + DOM + Basic Rendering (Progressive)
Deliver:
- HTML tokenizer + tree builder.
- DOM with event model scaffolding.
- Incremental streaming parse + safe-point paints.
- Minimal CSS parser + selector/cascade subset.
- Layout v1 (block/inline/line-break).
- Paint pipeline v1 (background/borders/text; images placeholder).

#### M4 — Fonts + Text Shaping
Deliver:
- TTF/OTF parsing, rasterizer into glyph atlas.
- Shaping + bidi + OpenType GSUB/GPOS (phased, but real).
- Font fallback + caches across tabs.

#### M5 — CSS Coverage to Modern Layout
Deliver:
- Selector engine optimization + invalidation.
- Layout: flexbox, grid, positioned, stacking contexts.
- Painting: gradients/shadows/transforms/opacity (phased).
- Compositing: layer promotion heuristics + threaded scrolling.

#### M6 — JavaScript Engine (Full, in Zig)
Deliver:
- Parser + bytecode compiler.
- VM with GC + spec semantics + modules (phased).
- Event loop integration (tasks/microtasks).
- Web IDL binding layer to DOM.

#### M7 — Core Web APIs
Deliver:
- DOM/events fully wired; Fetch + Streams + URLSearchParams + Encoding.
- Storage: cookies, local/session storage, Cache Storage (phased).
- Service Worker planned early, implemented later.

#### M8 — Media & Images (All Zig)
Deliver:
- PNG/JPEG/GIF/WebP decoders (Zig) + animated images.
- Canvas 2D (phased).
- Audio/video decoding planned as a separate epic after images/canvas.

#### M9 — Security, Sandboxing, Site Isolation Hardening
Deliver:
- Process-per-site-instance + same-origin + CORS/CSP/mixed-content enforcement.
- macOS sandbox profiles per process type.
- Crash recovery (sad tab) + fuzzing harnesses + continuous runs.

### “Instant” Performance Strategy
- Budgets enforced: input-to-pixels (p95), nav-to-meaningful-paint (p95), scroll frame time (p95), memory per tab.
- Mechanisms: progressive rendering, explicit stage queues + backpressure, aggressive caching (DNS/TLS/HTTP/fonts/layout), predictive prework, vsync-aligned compositor with damage rects.

### Testing & Conformance
- Unit + integration tests per subsystem.
- WPT curated subsets with expected failures tracked.
- test262 curated subset with ongoing expansion.
- Fuzzing for HTML/CSS/JS parsers and decoders.

### Risk Register
- Chromium-level parity quickly is multi-year.
- Pure Zig only increases scope dramatically (TLS/codecs/shaping/JIT).
- “Instant” is achievable via responsiveness + progressive paint; “fully loaded instantly” is network-bound.

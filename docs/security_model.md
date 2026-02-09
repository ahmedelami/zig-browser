# Security Model (target)

Target model: multi-process, site-isolated, sandboxed.

- Browser/UI process: privileged coordinator.
- Network process: handles all network I/O and sensitive state (cookies, cache).
- Renderer process: per-site-instance; no direct filesystem/network access.
- GPU process: isolated GPU access and compositing.

Enforcement is staged, but the interfaces are designed capability-first from day one.


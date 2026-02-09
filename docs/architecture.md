# Architecture (initial)

This project targets a modern multi-process browser architecture:

- `zb_browser`: UI + supervisor (spawns child processes, owns policy).
- `zb_net`: networking stack (DNS/TCP/TLS/HTTP/cache/cookies).
- `zb_renderer`: HTML/CSS/layout/paint + JS + Web APIs.
- `zb_gpu`: Metal device + compositing + frame scheduling.

Communication uses unix domain sockets with a small binary framing protocol (versioned).

The current implementation is M0 scaffolding: process supervision + IPC ping/pong + trace output.


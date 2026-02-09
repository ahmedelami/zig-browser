# Performance Budgets (bootstrap)

Budgets evolve over time, but are enforced early to prevent regressions.

**Initial always-on metrics (M0/M1):**
- cold start → first frame (browser UI visible)
- input → pixels latency (p95)
- navigation → first meaningful paint (p95)

In M0 we only wire tracing + timing infrastructure; real thresholds get locked once M1 first-frame exists.


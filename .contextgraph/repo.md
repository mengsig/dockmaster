<!-- contextgraph:managed:start -->
## ContextGraph

Canonical repository memory is stored in `.contextgraph/repo.md`; use `contextgraph recall --query <task> --file <path>` instead of loading it wholesale. Save only durable, non-obvious user facts or repository facts verified by evidence files; update a changed fact by reusing its key with `--replace`. Never store secrets or transient task state.

### Repository memories

<!-- contextgraph:item:v1 -->
### `reference-implementation` · decision

**Fact:** manhandler-cc reimplements the concepts of firstmate \(github.com/kunchenguid/firstmate\) but is NOT constrained by its structure or language; it targets Claude Code native primitives instead of bash+tmux.

- **Why:** All architecture decisions flow from choosing the best-fit Claude Code primitive over firstmate's generic-harness bash machinery.
- **Source:** user
- **Priority:** normal
- **Created:** `2026-07-17T06:16:11.610Z`
- **Checked:** `2026-07-17T06:16:11.610Z`

<!-- contextgraph:item:v1 -->
### `work-boundary` · invariant

**Fact:** This work happens in manhandler-cc; the sibling directory ../manhandler must NEVER be read or written.

- **Why:** Hard user boundary; violating it corrupts a separate project.
- **Source:** user
- **Priority:** normal
- **Created:** `2026-07-17T06:16:11.698Z`
- **Checked:** `2026-07-17T06:16:11.698Z`
<!-- contextgraph:managed:end -->

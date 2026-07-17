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

<!-- contextgraph:item:v1 -->
### `contextgraph-scope` · pitfall

**Fact:** contextgraph doctor here reports many errors because the root store discovers sidecars inside gitignored repos/, state/, and data/ \(managed clones\), yielding orphan/misplaced/malformed nodes and CORRUPT\_STORE on recall. Sidecar discovery does not honor .gitignore; an ignore for repos/state/data is the fix.

- **Why:** Avoids re-diagnosing the red doctor and recall corruption every session.
- **Source:** verified
- **Priority:** normal
- **Created:** `2026-07-17T11:59:36.650Z`
- **Checked:** `2026-07-17T11:59:36.650Z`
- **Evidence:** [{"path":".gitignore","sha256":"5a62bf81fde8a1a28892c737782c22c5d08e53c935aff18c5ef662c598b9aedc"}]

<!-- contextgraph:item:v1 -->
### `pr-description-style` · convention

**Fact:** PR descriptions and commit messages: 5-7 lines, dry and concrete, lead with what the change does, a little genuine enthusiasm is fine, no LLM cadence or filler. Always commit as the operator — never an agent co-author or a generated-by line.

- **Why:** Operator directive on PR/commit voice; every PR and commit the manhandler produces must match it.
- **Source:** user
- **Priority:** normal
- **Created:** `2026-07-17T13:36:38.350Z`
- **Checked:** `2026-07-17T13:36:38.350Z`
<!-- contextgraph:managed:end -->

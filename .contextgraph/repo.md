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

**Fact:** Root-store sidecar walk skips only hardcoded dirs \(.git/.contextgraph/node\_modules\); no config knob extends it, so it walks into gitignored repos/state/data and chokes on managed clones' sidecars — recall/doctor AT THE ROOT throw CORRUPT\_STORE. Per-clone recall \(crewmate --root inside a clone\) is UNAFFECTED. Only real fix is a contextgraph code change to skip nested .contextgraph roots.

- **Why:** Root recall stays broken until contextgraph is patched; do not hunt for a config knob and do not assume crew memory is impaired.
- **Source:** verified
- **Priority:** normal
- **Created:** `2026-07-17T11:59:36.650Z`
- **Checked:** `2026-07-17T16:51:14.157Z`
- **Evidence:** [{"path":".gitignore","sha256":"b9cd7268ff3174b9bde858b8686e371369d9ca633eba36274525d6710997c463"}]

<!-- contextgraph:item:v1 -->
### `pr-description-style` · convention

**Fact:** PR descriptions and commit messages: 5-7 lines, dry and concrete, lead with what the change does, a little genuine enthusiasm is fine, no LLM cadence or filler. Always commit as the operator — never an agent co-author or a generated-by line.

- **Why:** Operator directive on PR/commit voice; every PR and commit the manhandler produces must match it.
- **Source:** user
- **Priority:** normal
- **Created:** `2026-07-17T13:36:38.350Z`
- **Checked:** `2026-07-17T13:36:38.350Z`
<!-- contextgraph:managed:end -->

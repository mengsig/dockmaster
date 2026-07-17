---
name: coding-guidelines
description: The maintainable-code commandments every crewmate follows when writing or changing code. The canonical copy — crewmate briefs bake this in verbatim, and the manhandler loads it before editing this distro's own code. Keep it in sync with the mirror in AGENTS.md.
---

# Maintainable Code Commandments for Coding Agents

You are a coding agent. Make the code work, and leave the code you touch easier to understand, safer to modify, and cheaper to maintain—without changes outside the requested scope.

**Priority order** (never sacrifice a higher goal for a lower one): **1. Correctness → 2. Safety → 3. Readability → 4. Maintainability → 5. Simplicity → 6. Practical performance → 7. Conciseness.** Safety means no data loss or corruption, no security regressions, no undefined behavior, no unsafe concurrency, and no leaked or misused resources. Example tiebreaks: if avoiding three duplicated lines requires a new abstraction layer, duplicate them; if a faster path hides an error condition, take the slower, visible path.

**Hard requirements:** correctness, safety, visible failures, honest reporting, and preservation of established behavior outside the requested change. Everything else—guidance about size, complexity, assertions, duplication, performance—is a review signal, not a quota. Never make a change merely to satisfy a heuristic. Follow the project's established conventions and public contracts unless they conflict with the requested behavior, correctness, or safety.

**Comments:** Never restate the code. Comment only non-obvious intent, invariants, tradeoffs, compatibility constraints, or externally imposed behavior—as much as needed for understanding, and no more.

## The Ten Commandments

**1. Write for humans first.** Make code easy for a new engineer to read, debug, and modify. Prefer clear names, direct and flat control flow (guard clauses and early returns over deep nesting), and boring structure. Make the normal path and the failure paths easy to tell apart. Avoid cleverness unless it materially improves correctness or relevant performance and can be explained simply.

**2. Keep units cohesive.** Each function, type, module, and file should have one clear responsibility. A function beyond ~60 lines, a long parameter list, or high complexity warrants a second look at the design—not automatic extraction. Extract well-named behavior when it improves comprehension; never create mechanical fragments or single-use indirection without clear benefit.

**3. Express and enforce meaningful invariants.** Validate untrusted or possibly-invalid input at system boundaries and return useful errors. Use assertions or contracts for states that should be impossible; prefer static types, schemas, tests, or explicit error handling when they express an invariant better. Pay extra attention to parsing, state transitions, mutation, concurrency, security-sensitive behavior, numerical computation, indexing, serialization, and external systems. Do not duplicate guarantees already enforced reliably, or use assertions for expected user errors.

**4. Never hide failure.** No empty handlers, catch-all handling without a recovery plan, ignored error results, log-and-continue when the operation failed, or fake/empty fallback data unless that fallback is explicitly safe and part of the contract. Intercept an error only to add context, translate it into a meaningful domain error, clean up, retry with a bound, handle an expected failure, or recover into a known-safe state—preserving the original cause.

**5. Make data flow, ownership, and dependencies explicit.** A reader should see where data comes from, how it changes, and where it goes. Avoid hidden global state, implicit mutation, surprising side effects, and needless shared mutable state. Make ownership, lifecycle, and resource cleanup clear.

**6. Fit the design to the actual problem.** Do not add frameworks, configuration layers, generic helpers, inheritance, caching, concurrency, or metaprogramming without demonstrated need; a little duplication is often cheaper than the wrong abstraction. Choose algorithms and data structures appropriate to the expected scale—avoid material repeated work, avoidable O(n²) behavior, blocking in hot paths, and excessive I/O—but optimize through clear design first and never micro-optimize cold code or trade away readability without evidence or a real requirement.

**7. Verify changed behavior.** Add or update focused tests when practical, especially for regressions, edge cases, invariants, and failure paths. Run the narrowest relevant checks, then broader ones when warranted. Keep tests deterministic and independent of accidental machine state. Do not weaken valid tests to make them pass, and do not confuse type-checking, linting, or compilation with behavioral testing.

**8. Avoid tight coupling; design clean boundaries.** Coupling is a primary driver of maintenance cost: when a single change repeatedly ripples into unrelated modules, a boundary is misplaced. Modules should interact through small, stable, well-named interfaces that hide implementation details; where the design has layers, keep dependencies pointing in one direction. Treat these as coupling red flags: reaching into another module's internals, circular dependencies, shared mutable state across boundaries, god objects that everything depends on, changes that must be synchronized across distant files, and implicit ordering requirements between calls. Separate concerns—keep I/O, side effects, and framework glue at the edges where practical, and core logic deterministic and independently testable. A good boundary lets a reader understand, test, or replace one side without knowing the internals of the other.

**9. Get the data model right first.** The choice of data structures and representations shapes everything downstream—simple code follows from the right model, and clever code compensates for the wrong one. Prefer representations that make illegal states unrepresentable. Keep a single source of truth for each piece of state; avoid duplicated or derived state that can drift out of sync, and when derivation is necessary, make the direction and ownership explicit.

**10. Keep changes scoped and compatible.** Make the smallest complete change that satisfies the request and preserves established behavior outside it. Reuse existing representations and conventions when suitable; do not refactor unrelated code to impose these preferences. If a nearby problem materially blocks correctness or safety, fix it within scope or report it clearly.

## Workflow

**Before changing:** Inspect the relevant code, tests, contracts, call sites, and conventions. Understand current behavior before changing it; resolve ambiguity from available evidence rather than speculating.

**Before finishing:** Review only what you added or changed: responsibility clear, invariants handled by the right mechanism, failures visible or safely recovered, data flow explicit, unrelated behavior preserved, relevant checks run. Fix genuine problems; do not expand the change to satisfy a heuristic.

## Response Requirements

Summarize what changed and what verification you actually performed. For substantial changes, note important invariants, error-handling decisions, and intentional tradeoffs; omit categories that don't apply. Never claim a check passed unless you ran it, or that a file changed unless you changed it. Distinguish verified facts from assumptions, and state known limitations.

## Additional Info
- Do not use default agent name tag for commit messages. Just let my github tag inherit.
- Do not write written by claude code or anything like that.

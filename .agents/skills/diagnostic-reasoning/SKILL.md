---
name: diagnostic-reasoning
description: Discipline for scoping and diagnosing a reported bug — establish observed behavior, separate trigger from masking condition from symptom, test the causal explanation, and treat a diagnosis as evidence, not authorization to implement. Load before scoping a bug or acting on a diagnostic report.
---

# diagnostic-reasoning

A diagnosis is evidence, not a license to change code. This discipline keeps a
bug investigation honest and prevents "plausible but wrong" fixes.

## Establish observed behavior

- Anchor on the **end user's experience**, not an internal error string.
- Get a real reproduction on the actual user path when feasible. If you can only
  reproduce a proxy, record the exact limitation — never present the proxy as
  equivalent.
- Capture expected vs observed, setup, inputs, and repeatability **before**
  assigning any cause.

## Separate three facts — never collapse them

- **Trigger** — what starts the fault.
- **Masking condition** — independent state/timing/config that hides or exposes
  it.
- **Symptom** — what is observed, often several layers downstream of the trigger.

## Test the causal explanation

- Compare the failing path against a proven-working path; find the earliest
  meaningful divergence.
- Inspect history (blame, recent commits, migrations) but do not assume the most
  recent nearby change is causal without evidence.
- Find the smallest counterfactual that *should* flip the outcome; change one
  condition at a time.
- Deliberately seek **disconfirming** evidence: name what would falsify your
  explanation, run it, and keep contradictory results.

## Scope and act

- A diagnosis brief should ask for: reproduction, trigger/mask/symptom
  separation, path comparison, relevant history, the smallest counterfactual,
  and disconfirming evidence.
- A report must keep observed facts separate from hypotheses.
- Before acting on a fix, verify the claimed cause explains both the
  reproduction and the proven path without leaning on an untested masking
  condition. If a load-bearing element is missing, route a focused follow-up
  rather than treating confidence as proof.
- **Implementation requires separate authorization.** When a fix is authorized,
  the reproduction becomes the regression test (promote the scout — see
  `task-lifecycle`).

<!-- GENERATED from the private dotfiles source repo — edit there, not here. -->

# Project Memory — Structure & Detail Rubric

How much Obsidian footprint a project gets, and the detail level of each piece.
Bias: **fewer, denser, pointer-first notes.** The repo is on disk; Obsidian is
the layer that routes an agent *to* the repo and holds the why/gotchas/who.

## Sizing by project

| Project shape | What to create |
|---|---|
| Small / stable / solo (a script, a settled lib) | **MOC only.** Fold gotchas + glossary into sections of the MOC. |
| Medium / active (a service you're shipping on) | MOC + **gotchas/field-guide** note + (if jargon-heavy) a glossary section. |
| Large / multi-subsystem / multi-person (a platform or core service) | MOC as hub + per-concern notes: decisions, gotchas, people, and links out to existing Architecture/Debug/Incident notes. The MOC *indexes* them. |

When unsure, start at MOC-only and **promote** a section to its own note when it
outgrows a few lines or needs to be linked from elsewhere.

## Detail level per artifact

### MOC — `MOCs/MOC - <Project>.md` (always)
The map. Sections, each with **1–2 lines of orientation per linked item** so an
agent knows where to dig without opening everything. Recommended sections:

- **Drift anchor** *(always)* — `last_synced` + `synced_commit` in frontmatter, plus a "how to re-sync" block listing the diff baselines (ADR count, release line, active ticket areas, the synced HEAD) and the exact command to check each. This is what makes a re-run a cheap *diff* instead of a re-derive. See the `remember-project` SKILL "Re-syncing" section.
- **Where the truth lives** — repo (+ how to fetch, e.g. `git clone <url>`), issue tracker, observability, cloud targets, datalake, console URLs. Pure routing.
- **Architecture & design (the why)** — link the design notes / ADRs; one line each on *what mental model it gives you*.
- **Active work** — what's in flight; link tickets/PRs.
- **Gotchas & debug** — link the traps; one line each on symptom.
- **Incidents** — what has actually broken.
- **People & meetings** — who owns what.

No code, no API shapes, no file contents. If a section would just reproduce the
repo, replace it with a pointer to the repo path.

### Decisions / why (only if real trade-offs exist)
Per decision: **what** was decided, **why**, **what was rejected and why that's
non-obvious**, and a link to the ADR/PR/ticket/thread. Stop there — no
implementation walk-through. If the repo has `docs/adr/`, link it and only
capture the *why* that the ADR omits.

### Gotchas / field guide (only if operational traps exist)
Terse bullets. Each: **symptom → cause → where to look (repo path / command)**.
This is the highest-value-per-line note — it's pure "what the code won't warn
you about". Date entries that may rot.

### Glossary (only if jargon is heavy)
`term → one-line meaning → where it lives in code`. Terse. A lookup table, not
prose.

### People / ownership (only if >1 stakeholder)
`name → role → owns → when to ping`. Use `[[People/Name]]` links so it joins the
vault's people graph. Keep it to who an agent or a newcomer would actually need.

## Anti-patterns (do not do)

- A note that paraphrases a README or a source file. Link it instead.
- An "architecture overview" that an agent could reconstruct by reading the repo. Capture only the *surprising* parts + a pointer.
- Copying API signatures, schemas, or config. They drift; the repo is truth.
- Pre-creating empty notes "to fill later". Create on real content only.
- Undated state claims. Anything that changes gets an "as of YYYY-MM-DD".
- A MOC with no drift anchor. Without it, the next run can't tell what rotted and either re-reads everything or trusts stale claims.
- Re-running by rewriting. A re-sync diffs the anchor forward and edits drifted lines in place; it does not re-interview or regenerate the hub.

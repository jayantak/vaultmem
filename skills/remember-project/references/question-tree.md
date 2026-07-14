<!-- GENERATED from the private dotfiles source repo — edit there, not here. -->

# Project Memory — Question Tree

The interview. Ask **one question at a time**, always with a recommended
default, and **skip any branch the repo already answers** (you read the README,
docs, ADRs, and code layout in step 1 — don't re-ask those).

The aim is to extract what is *in the user's head and not in the repo*. If an
answer turns out to be "just read file X", capture the pointer to X, not the
content.

Order the branches roughly as written, but follow the user — chase the threads
that produce the most non-obvious knowledge and abandon branches that keep
returning "it's obvious from the code".

## 0. Re-sync check (only if a MOC already exists)

If `MOCs/MOC - <Project>.md` is already there, this is a **re-sync, not a first
interview** — do not walk the whole tree. Run the MOC's drift-anchor diff
(`git log <synced_commit>..HEAD`, new ADRs, new release line, new ticket areas)
to see what the repo already tells you, then ask the user only the residual that
a diff can't reveal:

- Since `<last_synced>`, what changed in the **why / who / direction** that a
  git diff wouldn't show? (a re-org, a new owner, a killed or pivoted
  initiative, a constraint that lifted, a decision reversed)
- Anything in the existing hub that's now **wrong** (not just stale) — a gotcha
  that no longer bites, an owner who left, a boundary that moved?

Then update the drifted sections in place and re-stamp the anchor. Only fall
through to the full tree below for genuinely new subsystems that appeared since
the last sync.

## 1. Identity & purpose

- What is this repo, in one sentence, to someone who's never seen it?
- Who/what are its users or consumers (humans, other services, jobs)?
- What does success look like? What is it explicitly *not* trying to do?
- Where does it sit in the larger system — what's upstream, what's downstream?

## 2. The mental model

- If you had to draw this on a whiteboard in 60 seconds, what are the boxes and arrows?
- What's the single core abstraction or data model everything else hangs off?
- What's the main flow — the request/event/job that, if you understand it, you understand the system?
- What part of the design is *surprising* or counter-intuitive to a newcomer?

## 3. Decisions & rationale (the why)

- What were the hard, hard-to-reverse decisions, and *why* did you choose as you did?
- What did you deliberately reject, and why is rejecting it non-obvious?
- What constraints (legacy, org, perf, cost, deadline) shaped the design but aren't written down?
- Are there ADRs/PRs/Slack threads/tickets that capture any of this? (Capture the *link* + the one-line why.)

## 4. Boundaries & integrations

- What external systems does it touch (APIs, DBs, queues, datalakes, third parties)?
- For each: what's the contract, who owns the other side, and what breaks if it changes?
- What's the auth/identity story at each boundary?
- Which boundaries are stable vs. actively changing?

## 5. Where the truth lives (the map)

- Where are the entry points in the repo (main, handlers, routes, the "start reading here" file)?
- Repo → key directories: what lives where, in one line each? (Pointer, not a tour.)
- How is it deployed / run locally? (Link the command or doc; don't transcribe.)
- External truth: issue tracker project/labels, observability dashboards & key monitors, cloud accounts/targets, datalake tables, any UI/console URLs.

## 6. Gotchas & footguns

- What has bitten you (or a teammate) that the code doesn't warn you about?
- What's the "looks wrong but is intentional" stuff?
- What are the sharp edges in local dev, deploy, migrations, or tests?
- What incidents has this had, and what was the real root cause? (Link the incident note.)
- What's the thing you always forget and have to re-learn?

## 7. People & ownership

- Who owns this overall? Who owns each major subsystem or boundary?
- Who do you ask when X breaks? When Y needs a decision?
- Any stakeholders/PMs whose context matters for *why* things are the way they are?

## 8. State — what's in flight

- What's actively being built right now? Where does it live (branch, PR, ticket)?
- What's half-done, stubbed, or known-broken that an agent should not trust?
- What's the near-term direction — what's about to change?

## 9. Glossary

- What domain terms / acronyms / internal names would confuse a newcomer?
- For each: one-line meaning, and where it shows up in the code.

## 10. Closing sweep

- "What would you tell a new engineer on day one that isn't written anywhere?"
- "What did I not ask that I should have?"

Then summarize back what you heard, and only *after* confirmation, write to
Obsidian per `references/structure-rubric.md`.

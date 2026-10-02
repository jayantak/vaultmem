# Design spec: vaultmem as distilled facts, not history

Status: proposal, for review. No code or vault changes ride with this doc.

## Summary

vaultmem today stores two things in one vault: durable facts (decisions, root
causes, gotchas) and a history of work (Session logs, Project indexes, daily
notes, Tasks). The 30-day transcript study (2026-10-02, vault note
`Agent Workflow Audit`) shows agents act on the first and ignore the second:

- Every read that changed an agent's action (7 of 32 sampled hits) hit a
  fact: a decision, a root cause, a "98% recall is a goal, not a measurement"
  correction. None hit a history log.
- Re-read rate of notes modified in the last 60 days: Architecture + Debug +
  Zettelkasten 33%, Session logs 18%, Meetings 0 of 5. Overall, 73% of notes
  are written and never read.
- Git, PRs, and Linear already hold the historical record.

Proposal: a vault holds **one fact per note**, edited in place or superseded,
never appended to. Capture writes a fact or writes nothing. Recall is search
plus a brief-injection path for dispatched workers. The Session/Project/Task
lifecycle tier, the Agent Index, MOCs, groom, and daily-note appends retire.

Citations: `file:line` refers to this repo at `6ef4704`. "Study" refers to the
numbers above and in the brief (`.scratch/dispatch/audit-2026-10-02/vault-spec.md`
in the dotfiles repo).

## 1. Note model

### One fact per note

A fact note answers one question an agent would otherwise re-derive. It has
five kinds:

| `kind` | Answers | Example claim |
|---|---|---|
| `decision` | Why is it built this way? | Journal/audit storage lives in `utility_entities`, not dedicated tables. |
| `root-cause` | Why did X break? | ElectroDB `put([...])` rejects a batch with duplicate keys, so one dup poisons the whole drainer batch. |
| `gotcha` | What surprises people here? | RDS Proxy rejects `PGOPTIONS` startup params; set timeouts per session instead. |
| `constraint` | What must stay true? | `vaultmem status` must exit 0 and print nothing on a missing vault. |
| `convention` | How do we do X here? | Never wikilink a Linear issue id; write it as plain text. |

A note that fits none of the five is not a fact (see § 2, distill-or-nothing).

### Frontmatter (schema 2)

vaultmem reads only scalar frontmatter (`SCHEMA.md:40-42`), so every field the
tool reads is a single `key: value` line.

```yaml
---
kind: gotcha                     # decision | root-cause | gotcha | constraint | convention
claim: RDS Proxy rejects PGOPTIONS startup params; set statement_timeout per session.
scope: flocasts/flo360           # repo (owner/name) or system name; comma-separated if several
date: 2026-08-01                 # when the fact was established
verified: 2026-08-01             # last date someone checked it against the source
source: https://github.com/flocasts/flo360/pull/3400   # PR, commit, or ticket id; the strongest one
status: live                     # live | superseded | retracted
supersedes:                      # slug of the fact this one replaces (empty if none)
superseded_by:                   # set on the old note when a newer fact replaces it
aliases: []                      # optional, as today
---
# RDS Proxy rejects PGOPTIONS startup params

<claim, one or two sentences, may restate the frontmatter claim with detail>

**Why:** <the evidence or reasoning; what was tried; why the alternative fails>

**Applies when:** <the trigger an agent would hit: file, command, error string>

**Sources:** <extra PR/commit/ticket links beyond `source:`>
```

Changes against `SCHEMA.md`:

| Field | Today | Schema 2 |
|---|---|---|
| `schema` | `1` in `Home.md` (`SCHEMA.md:8-9`) | `2`; a vault declares it once (see Open question 9) |
| `kind`, `claim`, `scope`, `verified`, `source`, `supersedes`, `superseded_by` | absent | new, read by search ranking, `brief`, and `verify` |
| `status` | session/project vocabulary `active/parked/done` (`SCHEMA.md:80-97`), task vocabulary (`SCHEMA.md:110-128`) | fact vocabulary `live/superseded/retracted`. `doctor` already treats `superseded`/`retracted`-like words as dead (`SCHEMA.md:99-102`) |
| `updated`, `project`, `type`, `thread`, `task`, `blocked_by`, `session`, `repos`, `linear`, `moc` (`SCHEMA.md:44-58`) | lifecycle tier | dropped with the tier (§ 4). `date` + `verified` replace `updated` |

Required on a fact: `kind`, `claim`, `scope`, `date`, `source`, `status`. A
missing one is a `FACT-FM` lint (§ 2, verify). `source` may be a ticket id
(`OFP-117`) when no PR exists yet; it may not be empty. A fact with no source is
an opinion, and the study's fabrication cases (§ 2) are exactly unsourced claims.

### Layout

```
<vault-root>/
  Home.md          # frontmatter only: schema: 2 (no Agent Index)
  Facts/           # flat; one <slug>.md per fact; slug = kebab-case of the claim's subject
  _archive/        # everything pre-migration, original paths preserved (§ 6)
  Templates/Fact.md
```

Flat, not foldered by kind: `kind` is a frontmatter field, so a fact that is both
a root cause and a gotcha never has to pick a folder, and moving a note never
changes its identity. Topical folders (`Debug/`, `Architecture/`) stop receiving
new notes.

### Size cap

Body (after frontmatter) at most **40 lines and 3 KB**. A longer note is two
facts or a history log. `verify` flags it as `FACT-SIZE`. For scale: a session
`_index.md` is allowed to reach 150 lines before groom calls it checkpoint-due
(`vaultmem:71`, `SCHEMA.md:104-108`), and a measured one was 11,950 bytes
(`skills/session/SKILL.md:441-443`).

### Edit in place, supersede, never append

Today capture extends an existing note by appending a dated
`### YYYY-MM-DD - <subtopic>` section (`skills/vault-capture/SKILL.md:36`).
That is how a note becomes a log. Schema 2 replaces it with two moves:

- **Edit in place** when the claim stays true and gains precision or a new
  source. Rewrite the body, bump `verified:`, keep `date:`. No dated sections.
- **Supersede** when the claim is now false and an agent may still hold the old
  belief. Write a new fact with `supersedes: <old-slug>`; set the old note's
  `status: superseded` and `superseded_by: <new-slug>`. Search hides superseded
  facts by default (§ 3) but `resolve` still finds them, so an old link still
  lands somewhere that points forward.
- **Retract** (`status: retracted`) when a fact was never true. Keep the note so
  the retraction is findable; body states what was wrong.

History of how the fact changed lives in git (if the vault is versioned) and in
the PRs the `source:` links point to, not in the note.

## 2. Capture

### Distill-or-nothing

Capture runs one test: **would a future agent, starting cold, change what it
does because this note exists?** If yes, write or update one fact. If no, write
nothing and say so. "Session went well, merged PR #123" fails the test (the PR
is the record). "Merged #123 because the obvious fix breaks Safari autoplay"
passes as a `decision`.

Explicit non-captures: work logs, meeting recaps, status updates, people
context, timelines, anything whose only source is "this session". These are
what today's three-artifact capture writes (`skills/vault-capture/SKILL.md:211-213`:
note + Agent Index update + daily note append), and they are the 73% never read.

A capture that writes nothing is a correct outcome, not a failure. The skill
must say so plainly, because the study found at least 7 of 40 runs that wrote
nothing or fabricated a write, and a runner that believes it must produce a
note is the one that fabricates.

### Steps

1. **Distill** (whoever has the context, normally the parent agent): produce
   `kind`, `claim`, `why`, `source`, `scope`. If any of `claim`/`source` cannot
   be filled, stop: nothing to write.
2. **Dedupe**: `vaultmem brief -n 3 <claim keywords>` (§ 3). If a live fact
   covers it, edit in place or supersede. Otherwise create `Facts/<slug>.md`.
3. **Write** the file.
4. **Verify once**: `vaultmem verify --proof <file>`. It prints
   `OK <path> <mtime-epoch> <bytes>` on success, lint lines and exit 1 on a
   finding.
5. **Return** the `OK` line verbatim. A parent that receives no `OK` line
   treats the capture as not done.

That is three vaultmem calls (`brief`, `verify`, optionally `cat` to read the
existing fact before editing). Today's contract asks for `resolve` per link,
`dangling` per note, and `verify` (`skills/vault-capture/SKILL.md:153-171`), plus
an Agent Index edit (`:39-43`) and a daily append (`:45-46`); the study measured
~13 lint reads per run (`resolve` x79 and `dangling` x63 across 40 runs).

### `verify` changes

Today `cmd_verify` lints only `Sessions/*/_index.md` and `Projects/*.md` against
the schema, plus dangling links on any note, and is silent on success
(`vaultmem:3838-3884`, success `return 0` at `:3879`). Schema 2:

- Lints `Facts/*.md`: `FACT-FM` (required field missing or `kind`/`status`
  outside its vocabulary), `FACT-SIZE` (§ 1 cap), `FACT-SUPERSEDE-DANGLING`
  (`supersedes`/`superseded_by` names no fact), `FACT-SUPERSEDE-DESYNC` (A
  supersedes B but B is not `superseded`).
- `--proof` prints the `OK` line on success. Without `--proof`, behavior is
  unchanged, so the PostToolUse hook, which fires on every file write
  (`docs/hooks.md:176-178`), stays silent on clean writes.
- Fail-quiet contract for non-vault paths stays (`vaultmem:3841-3846`).

### Model and cost

- **Default: inline, no subagent.** The parent already holds the context; the
  distilled fact is ~10 lines. Writing it inline costs one file write and two
  short CLI calls, under 10k tokens. Today's default, a capture subagent at
  every stopping point (`~/.claude/CLAUDE.md` § Subagents;
  `skills/vault-capture/SKILL.md:192-213`), costs a mean 2.5M tokens per run
  across 40 runs (study), about 100M tokens a month.
- **Subagent only when the parent is near its context limit.** The parent still
  does step 1 and passes the five distilled fields, never a raw session
  summary. The subagent runs steps 2-5 on **Haiku**: dedupe, write, and verify
  are mechanical once the fact is distilled. Distillation is the judgment step
  and stays on the session model.
- **Cost target:** inline under 10k tokens; subagent under 100k tokens and
  under 5 tool calls. 25x below today's mean at the subagent ceiling.

### Repo onboarding (Workflow D)

Today it creates a project note, MOC rows, signpost notes, an Agent Index entry,
and a daily append (`skills/vault-capture/SKILL.md:221-300`). Schema 2 shrinks it
to: list the repo's non-obvious `constraint` and `convention` facts (the things
its README and AGENTS.md do not already say), one note each, `scope: <owner/repo>`.
Anything the repo's own docs state is the repo's job (`AGENTS.md`: "never answer
a live-code question from memory").

## 3. Recall

### Search stays

`vaultmem <query>` stays the primary read. Changes:

- **Rank facts first.** Today curated Agent Index and MOC lines print first
  (`vaultmem:2424-2440`, design note `:173-174`). Schema 2 replaces the curated
  tier with live facts whose `claim:` matches, printed as one line each:
  `<kind> <claim> [<slug>]`. The claim line is the index; no separate one to
  maintain.
- **Hide superseded/retracted and `_archive/` by default.** Today search skips
  only `Templates/` (`vaultmem:2279`), so archived session logs compete with
  facts. `--all` restores the full scope, which is how the archived history
  stays reachable after migration.
- `--rerank`, `--format`, `--exclude`, `-n` unchanged.

### Brief injection for workers

Workers get their context from briefs; only 7% of worker sessions read the
vault (study). The one clear re-derivation in the study was a worker inferring
"PGOPTIONS fails via RDS Proxy" while the note "Resolution V3 - RDS Proxy
Rejects Timeout Startup Params" existed. The fix is to push facts into the
brief, not to ask workers to pull.

New subcommand:

```
vaultmem brief [-n 3] [--scope <repo>] <ticket-id | topic terms...>
```

- Searches live facts only. A ticket id matches `source:` and body text; topic
  terms AND-match like search.
- With `--scope`, facts scoped to that repo rank first; unscoped facts still
  appear.
- Prints paste-ready markdown, at most `-n` facts (default 3):

  ```
  ## Known facts (vaultmem)
  - gotcha: RDS Proxy rejects PGOPTIONS startup params; set statement_timeout per session. (source: flocasts/flo360#3400; Facts/rds-proxy-pgoptions.md)
  ```
- Prints nothing and exits 0 when no fact matches, so a brief writer can call
  it unconditionally.

`dispatch`'s brief writer (dotfiles repo, not this one) runs
`vaultmem brief --scope <repo> <ticket-id> <2-4 topic terms from the ticket title>`
and pastes the output verbatim under the task. The worker never needs to know
the vault exists.

### SessionStart

The picker (`vaultmem sessions`, `vaultmem:1499-1576`) was shown in 367 of 367
sessions and resumed by number 0 times, by name 4 (study). It came out of
SessionStart on 2026-10-02; only `vaultmem status` remains, and nothing inside
fleet worktrees.

**Keep `status`, shrink it to one line.** Today it prints the index count, the
MOC list, a reflex line, and the groom nudge (`vaultmem:476-487`). Schema 2:

```
vaultmem: 212 facts · before re-deriving a decision/root cause/gotcha: vaultmem <q>
```

No nudge (groom retires), no MOC list (MOCs retire). Cost stays a few dozen
tokens per session; its job is the reflex reminder, which is the only recall
path a non-worker session has. Fail-quiet contract unchanged (`AGENTS.md`
§ The hooks model).

### Stop hook (`nudge`)

Today `nudge` warns when notes changed but no `Sessions/*/_index.md` did
(`vaultmem:520-527`), and optionally adds a `capture-worthy` line from the Jev
extension (`vaultmem:83-87`). The session half retires with sessions. Keep the
`capture-worthy` half: it is a distill-or-nothing trigger by design (it only
fires when the transcript tail holds a durable decision or root cause).

## 4. What to retire

| Surface | Verdict | Evidence | Code and docs |
|---|---|---|---|
| Session notes (`Sessions/<thread>/_index.md`) | **Delete** tier; archive files | Session logs re-read 18% (study); 0 of 7 action-changing reads hit one; Flo vault 17 of 18 active sessions stale >7d | `SCHEMA.md:19-20,70-78`; `skills/session/SKILL.md:142-218` |
| Session picker (`vaultmem sessions`) | **Delete** | 367/367 shown, 0 resumed by number, 4 by name (study) | `vaultmem:1499-1576`; `docs/hooks.md:18-48` |
| `bookmark`, `worktrees` | **Delete** | Read only by session resume | `vaultmem:3705-3804`, usage `:136-145` |
| Groom + nudge counts | **Delete** | Exists to clean up the session pile: Flo 17/18 active stale >7d, all 11 parked >21d, groom runs as rare big sweeps (study). No sessions, no pile | `vaultmem:1595-1632`, `cmd_groom` `:1961`; `skills/session/SKILL.md:369-434` |
| `groom --triage`, `groom-triage` Jev set | **Delete** | Advisory layer over groom | `vaultmem:76-82`; `ext/jev/sets/groom-triage.json` |
| Checkpoints / distill | **Delete as a step; absorbed by capture** | Checkpoint promotes durable bits out of a log (`skills/session/SKILL.md:330-349`); with no log, capture does that directly | `skills/session/references/distill.md`; `BLOAT_LINES` (`vaultmem:71,1578-1594`) |
| Projects tier (`projects`, `project`, `## Sessions` rows) | **Delete** | Indexes sessions; Linear holds the epic | `vaultmem:3007-3088`; `SCHEMA.md:226-238` |
| Tasks tier (`next`, `task`, `--promote`) | **Delete** (Open question 4) | No usage number in the study; Linear is already canonical for team work (`SCHEMA.md:144-148`); workers get briefs from `dispatch`, not from `task` | `vaultmem:91-112,3089-3401`; `SCHEMA.md:110-162` |
| Agent Index (`Home.md` rows, `index`, curated search, `doctor` BROKEN/STALE/INDEX-DRIFT, `doctor --drift`) | **Delete** | A hand-maintained second copy of every claim; capture must edit it every time (`skills/vault-capture/SKILL.md:39-43`); fact `claim:` lines replace it (§ 3) | `vaultmem:476-481,699-750,2424-2440,1220-1300`; `SCHEMA.md:192-224` |
| MOCs (`mocs`, MOC curated lines, `doctor --deep` UNINDEXED) | **Delete**; archive files | Hubs for graph traversal into history notes; facts are reached by search and `brief`, and `scope:` groups them by repo | `vaultmem:1404-1417`; `SCHEMA.md:240-243`; `skills/vault-recall/SKILL.md:120-160` |
| `frontier`, `dangling --by-target` | **Delete** | "What to write next" by graph shape rewards writing more; the new rule is write less | `vaultmem:3942-4075`, usage `:122-125` |
| Daily-note appends | **Delete** | Pure history; Meetings 0/5 re-read is the closest proxy (study) | `skills/vault-capture/SKILL.md:45-46,211-213,298` |
| Wikilink graph (`resolve`, `links`, `backlinks`, `neighbors`, `dangling <note>`) | **Keep** | `supersedes` chains and cross-fact links still need resolution; cheap | `vaultmem:3402-3560` |
| `cat` | **Keep** | Token-frugal read of a fact | `vaultmem:3595-3671` |
| `verify` | **Keep, extend** (§ 2) | The capture proof | `vaultmem:3838-3884` |
| `doctor` | **Shrink** | Config lint + fact lints + growth line; drop session/project/task/index lints | `vaultmem:1301-1403` |
| `status` | **Keep, shrink** (§ 3) | Reflex reminder | `vaultmem:476-487` |
| `nudge` | **Shrink** to `capture-worthy` only (§ 3) | | `vaultmem:503-540` |
| Router (`vaults`, `path`, `which`), `init`, `jev`, search | **Keep** | Unaffected | |

### What is lost, and what replaces it

- **Resume-by-thread.** The bookmark (`Last / Next / Open`) let a fresh session
  pick up mid-task. Replacement, in order: the branch and its PR description;
  the Linear ticket; the harness's own transcript resume (`claude --resume`,
  Codex resume); the `handoff` skill for deliberate mid-flight transfers. Four
  name-resumes in 367 sessions (study) is the measured demand.
- **A per-project "what happened" narrative.** Replacement: the PR list and
  Linear project. Durable outcomes of that narrative become `decision` facts.
- **Personal backlog** (`vaultmem next`). Replacement: Open question 4.
- **Graph-shaped exploration** (MOC → links → backlinks). Replacement: `scope:`
  filtering and search. Archived MOCs stay readable with `--all`.

Removal follows the jev rename pattern: one release where each retired
subcommand prints one stderr line naming its replacement and exits 0
(`vaultmem:193-198`), then removal in the next breaking release.

## 5. Native memory

Rule (supersedes the looser wording in `~/.claude/CLAUDE.md` § Memory):

- `MEMORY.md` holds **pointers only**: `- <one-line constant> → vault: Facts/<slug>.md`.
- Cap: **2 KB** (~500 tokens) per `MEMORY.md`, and at most 15 lines.
- A native file that is not a pointer must be a load-bearing operational
  constant (a deploy invocation, a git footgun) that also exists as a vault
  fact. No native-only facts.
- A pointer whose target is `superseded` or missing is deleted, not fixed.

flo360 cleanup (22.6 KB `MEMORY.md`, ~6k tokens every session; 89 native files,
50 with no vault counterpart; study):

1. **Script:** for each of the 89 files, `vaultmem brief -n 1` on its title; tag
   each `has-fact` / `no-fact`.
2. **Agent (Sonnet, one pass, ~50 files):** for each `no-fact` file, apply the
   distill-or-nothing test. Pass → write a fact with a source. Fail (derivable
   from the repo, or history) → drop.
3. **Agent:** rewrite `MEMORY.md` to the ≤15 load-bearing pointers; delete the
   other native files.
4. **Check:** `wc -c MEMORY.md` ≤ 2048. Estimated saving ~5.5k tokens per flo360
   session.

The same pass runs over every other project's native memory dir; flo360 is the
largest and goes first.

## 6. Migration

Scope: the ~270 notes modified in the last 60 days, plus older
`Architecture/`, `Debug/`, and `Zettelkasten/` notes (the 33% re-read group).
Everything else is archived. **Nothing is deleted.**

### Phases

| Phase | Work | Who | Rough cost |
|---|---|---|---|
| 0. Tooling | Schema 2 in vaultmem: `Facts/` lints in `verify`/`doctor`, fact-first search, `brief`, `status` one-liner, `verify --proof`, `_archive/` excluded from search. Old surfaces still work. Tests on fixture vaults. | One code PR, agent | Normal PR |
| 1. Inventory | List candidates: `find` by mtime (60d) + the three folders; emit TSV `path, folder, bytes, mtime`. | Script | Seconds |
| 2. Distill | Batches of ~10 notes per agent (Sonnet). Per note: emit 0..N facts with `source:` (search the note for PR/commit/ticket links; if none, the fact gets `source:` the archived note path and `verified:` empty, flagged for review). Apply the distill-or-nothing test per candidate; most Session logs should yield 0-2 facts. Each fact goes through `verify --proof`. | Agents, parallel | ~420 notes (270 + an estimated ~150 older; real count from phase 1) at ~150k tokens per 10-note batch ≈ 6-7M tokens. Under one week of today's capture spend (~100M/month) |
| 3. Dedupe | Pairwise near-duplicate check across new facts with the existing `dupes` Jev set (`ext/jev/sets/dupes.json`), else `brief` on each claim. Merge or supersede. | Agent + Jev | ~1M tokens |
| 4. Review | Jay spot-checks 10% of facts and every fact with an archived-note `source:`. | Jay | ~1 hour |
| 5. Archive | `mv` every non-`Facts/` note into `_archive/<original path>`. Basename resolution keeps old `[[links]]` working (`SCHEMA.md:245-250`); a script reports any new `DANGLING` from `vaultmem dangling`. | Script | Seconds |
| 6. Retire | Skills swap (§ 7); hooks drop session wiring; deprecation release; native memory cleanup (§ 5). | Agent | One PR here, one in dotfiles |
| 7. Remove | Breaking release removes retired subcommands and lints. | Agent | One PR |

Phases 0 and 1 are reversible and independent. Phase 5 is the cutover; until
then both models coexist and search sees both. Run phase 2 on the Flo vault
first (the larger session pile), then personal.

### Scriptable vs agent work

- **Scriptable:** inventory, archive move, dangling report, native-memory
  tagging, size and schema checks (`verify` over `Facts/`), link rewriting for
  `supersedes`.
- **Agent:** the distill-or-nothing judgment, writing `claim`/`why`, finding the
  strongest `source`, dedupe merges.
- **Human:** the spot check and the open questions below.

## 7. Skill changes

The four skills are canonical here and sync into the dotfiles
(`skills/vault-capture/SKILL.md:11`). Changes:

### `session`: delete

Its job (cross-session working memory, picker, park/checkpoint, groom triage,
backlog) is the retired tier (`skills/session/SKILL.md:22-38,142-434`). Remove
`skills/session/`, its plugin entries (`.claude-plugin/marketplace.json:11`,
`.claude-plugin/plugin.json:4`), and its rows in the dotfiles `AGENTS.md` skill
table. Keep one paragraph of its lesson, "at park time decide done vs parked;
sessions are not ticket trackers" (`skills/session/SKILL.md:358-367`), as the
justification line in this spec's archive, not in a skill.

### `vault-capture`: rewrite around one fact

- Replace Workflow B (`:28-55`) with § 2 Steps. Delete the dated-section append
  (`:36`), the Agent Index step (`:39-43`), the daily append (`:45-46`).
- Replace § Definition of done (`:153-171`) with "one `verify --proof`, return
  the `OK` line".
- Replace § Frontmatter (`:173-190`) with the schema 2 block.
- Replace Workflow C (`:192-213`) with "parent distills, subagent (Haiku)
  writes"; state that writing nothing is a valid result.
- Shrink Workflow D (`:221-383`) per § 2, Repo onboarding.
- Delete `references/optional-layouts.md`, `structure-rubric.md`; rewrite
  `question-tree.md` as the distill-or-nothing test plus the five kinds.
- Description: drop "meeting, milestone, people context"; triggers become
  "decision, root cause, gotcha, constraint, convention just established".

### `vault-recall`: search and brief only

- Keep § The reflex (`:20-40`), § Fast search (`:55-77`), frugal reading.
  Drop "the history the code cannot show" (`:28-29`): the vault no longer
  holds history.
- Delete § Agent Index (`:78-97`), § graph traversal and § Maps of Content
  (`:120-160`).
- Add `brief` and the rule "a superseded fact is not an answer; follow
  `superseded_by`".
- Add: facts carry `verified:`; a fact older than its `scope` repo's relevant
  change is a lead to re-check, not an answer (same stance as today's negative
  trigger, `:31-35`).

### `vault-curate`: fact health only

- Delete the gap surfaces (`dangling --by-target`, `frontier`; `:24-45`) and the
  lifecycle surface (`groom`; `:95-125`).
- Keep `doctor` and `verify`, retargeted to fact lints.
- New pass: list facts with `verified:` older than N days (Open question 7) in
  scopes with recent merges; list supersede chains longer than 2; run `dupes`.
- Rename candidates: none needed; the job ("is the vault rotting") survives.

### Lint and tests

- `tests/subcommand-lint.sh` fails on any skill reference to a removed
  subcommand, so phase 7 and the skill rewrite land in one PR.
- `tests/vaultmem.bats` lifecycle tests move to deprecation-line assertions in
  phase 6 and are deleted in phase 7. New fixture vault: `Facts/` with one note
  per kind, one supersede pair, one oversized note.

## 8. Open questions for Jay

1. **Folder layout: flat `Facts/`, folders per kind, or keep topical folders?**
   Recommend flat `Facts/`. Kind is a field; folders force a choice for
   multi-kind facts and make moves look like identity changes.
2. **Where does the archive live?** Recommend in-vault `_archive/` with original
   paths, excluded from default search, reachable with `--all`. Keeps old
   wikilinks resolving and Obsidian search over history intact.
3. **Delete `session` outright, or keep a stub that points at `handoff`?**
   Recommend delete. 4 name-resumes in 367 sessions does not justify an
   always-on skill; `handoff` already covers deliberate transfers.
4. **Personal backlog after Tasks retire?** Recommend GitHub issues on the
   relevant repo (or a Linear personal team) instead of a vault tier. Planned
   work is history-in-waiting; a tracker already does it. Fallback: one
   `Backlog.md` checklist, no CLI support.
5. **Inline capture as the default, with a subagent only near context limit?**
   Recommend yes, and change the `~/.claude/CLAUDE.md` § Subagents line that
   spawns a capture subagent at every stopping point. That line is the 100M
   tokens/month.
6. **Edit-in-place vs supersede threshold.** Recommend: edit when the claim
   stays true and gains precision or sources; supersede when an agent holding
   the old claim would now act wrongly. Retract when it was never true.
7. **Re-verify window.** Recommend 90 days for `verified:` before `vault-curate`
   lists a fact, and only in scopes with merges since; no automatic expiry.
8. **People context and meetings.** No fact kind covers them. Recommend archive
   with no replacement (Meetings 0/5 re-read); a people convention that changes
   agent behavior ("X owns approvals for Y") is a `convention` fact.
9. **Where does `schema: 2` live once `Home.md` loses its index?** Recommend
   keep a frontmatter-only `Home.md` (it already gates surfaces, `SCHEMA.md:6`),
   so `doctor` can warn on an unknown version without a new config key.
10. **Same model for the personal vault?** Recommend yes. One tool, one schema;
    personal Zettelkasten notes are the closest existing thing to facts already.
11. **Release shape.** Recommend phase 0 as a minor release (additive), phases
    6-7 as the next major with one deprecation release between, matching the
    jev rename (`AGENTS.md` § The extension model, last bullet).
12. **Should `brief` live in core or the Jev extension?** Recommend core. It is
    search plus formatting, no network; `--rerank` can apply on top when Jev is
    enabled.

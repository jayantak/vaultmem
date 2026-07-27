---
name: vault-recall
description: >
  Check the vault before you re-derive. Trigger before reconstructing a past
  decision, root cause, incident, architecture rationale, or "why is it built
  this way" — even when no memory question is asked — and on explicit lookups
  ("what do I know about X", "check my notes"). Not for what the code does now;
  that's the repo.
---

<!-- CANONICAL SOURCE: this repo (jayantak/vaultmem). The dotfiles copy under agents-source/skills/ is synced FROM here — edit this file, not that one. -->

# vault-recall — check before you re-derive

Your Obsidian vaults **are** your agent-memory layer. This skill is the read
side: find what is already written down before spending tool calls
reconstructing it. Writing new knowledge back is `vault-capture`; keeping the
vault healthy is `vault-curate`; per-thread working state is `session`.

## The reflex

Before you investigate a past decision, root cause, or incident, explain "why is
it built this way," or spend more than a couple of tool calls reconstructing
project or people context — **search the vault first**.

- It is ~60ms and ~700 tokens. That is cheaper than reading two files, so a miss
  costs nearly nothing and the default is to check, not to skip.
- Grepping the repo tells you *what* the code does. The vault tells you *why*,
  and the history the code cannot show.
- Do not trust "I already sort of know this" for a past decision. That is how a
  stale or invented answer ships.

**Negative trigger — current code or behavior is the repo, never the vault.**
Memory goes stale the moment the code changes; `rg` and direct file reads are
the source of truth for what the code does right now. Use the vault for the
why/decisions/gotchas/people the code can't tell you.

If the user is asking about something with no plausible note (a pure code
question, a fresh algorithm), proceed without the vault. This skill being loaded
does not mean every response goes through Obsidian.

## Your vaults

Never hardcode a vault path or id. Resolve them at runtime: `vaultmem vaults`
prints the registry (id, root path, sessions root, MOC, roles, routing rules),
and `vaultmem path <vault>` prints one root for use in scripts
(`V="$(vaultmem path <vault>)"`). `vaultmem which` guesses the vault that
routes for the current repo/cwd. A typical setup has a **work** vault
(debugging, incidents, meetings, projects, architecture, people) and a
**personal** vault (learnings, side projects, ideas, non-work notes).

Default to the work vault unless content is clearly personal. If a topic could
plausibly be in either, check both — they're small.

## Fast search: the `vaultmem` CLI

A ripgrep-backed helper on `PATH` is the quickest way in — no need to read whole
notes to find the right one. `vaultmem <query>` searches all vaults, curated
Agent-Index/MOC hits first, then note-content matches; `vaultmem mocs` lists the
domain hubs. Locate candidates first, then read only those. Two rules make it
reliable:

- **You are the query expander.** One hopeful query is not a search. Run 2–3
  deliberate variants — the exact term, a synonym, an adjacent concept
  (`drainer` / `OOM` / `memory limit`). Each call is ~60ms; a missed note
  because you stopped at one phrasing is the expensive outcome.
- **Snippets are only leads.** Match lines locate the note; they are not the
  answer. Read the note — or the relevant section, below — before answering.
  Never answer from search output alone.

## Agent Index (the entry point)

Each vault's `Home.md` contains an `## Agent Index` section between
`<!-- AGENT-INDEX:START -->` and `<!-- AGENT-INDEX:END -->` markers: one row per
note (`| [[Folder/Note]] | one-line summary |`), grouped under `### <Section>`
headings.

**Start with `vaultmem index`, not by reading `Home.md`.** It prints the *shape*
— section names with counts, plus the MOC list — and expands on demand. Reading
`Home.md` whole was cheap at 20 notes and stops being cheap fast: on a real
75-note vault `Home.md` is 19,275 bytes while `vaultmem index` gives the same
orientation in 403 — **48× cheaper**, and the gap widens with every note.

- `vaultmem index` — section counts + MOCs. The default first move.
- `vaultmem index <section>` — expand one section's rows (e.g. `index architecture`).
- `vaultmem index all` — full flat dump. An escape hatch, not a default.

Only open `Home.md` directly when you need to *edit* it (adding an index row —
that is `vault-capture`'s job).

## Reading a note frugally

Once you have a candidate, don't slurp the file — `vaultmem cat` reads it the way
the graph commands resolve it (basename, `Folder/Name`, or alias, so you needn't
know the path):

- `vaultmem cat <note>` — line-numbered read of the whole note.
- `vaultmem cat <note> --section '## Decisions'` — just that heading block
  (through the next heading of same-or-higher level). Usually all you want.
- `vaultmem cat <note> --from 40 --lines 30` — window the result.

A miss prints up to 3 `Did you mean:` near-matches, so a wrong guess costs one
call instead of a path hunt. For a session's resumable state, `vaultmem bookmark
<thread>` prints only its `## Bookmark` + `## Pinned` (measured on a real vault:
2568 bytes vs 11950 for the whole `_index.md`, **4.7× cheaper**).

**`vaultmem cat`/`bookmark` are inspection only — they do NOT satisfy the Edit
tool's read-before-write precondition.** They are separate processes; the Edit
tool only counts a file as read when *you* read it with the Read tool. Use them
freely for cheap inspection, and Read the file itself before your first edit to
it.

## Researching by following wikilinks (graph traversal)

These vaults are a *linked graph*, not a flat pile — the highest-signal way to
research a topic is to start at a hub and **follow the `[[wikilinks]]` outward**,
the same way you'd read the code by following imports. Keyword search finds a
note; link-following finds the note's *neighbourhood* (the decisions, gotchas,
and people around it). Use both: search to find the entry note, then traverse.

The `vaultmem` link subcommands do this over ripgrep (no Obsidian app, no
graph DB). All accept a wikilink target — a basename (`Mikey`), a `Folder/Name`
path, or an alias (`Payments`) — or a file path:

- `vaultmem links <note>` — the note's **outbound** `[[links]]`, each resolved to its file (or flagged `DANGLING`).
- `vaultmem backlinks <note>` — notes that link **to** this one (reverse edges; alias-aware). This is how you find "what else touches this".
- `vaultmem neighbors <note>` — outbound + backlinks together (the one-hop view).
- `vaultmem resolve <name>` — resolve a single `[[link]]` to its path; non-zero exit + `DANGLING` if it points nowhere.

**Traversal protocol** (keep it cheap — depth, not breadth):

1. **Pick the entry hub.** `vaultmem mocs` for the domain MOC, or `vaultmem index` for the Agent Index, or a search hit. MOCs are built to be entry points — start there.
2. **Fan out one hop.** `vaultmem links <hub>` (or `neighbors`). Read the one-line orientation each MOC gives its links; pick the 1–3 that match the question. Don't open everything.
3. **Read those, then traverse again only if needed.** Follow a second hop from a note you actually read. **Stop at ~2 hops** — relevance decays fast and the vault is small.
4. **Use `backlinks` to widen or climb back.** To answer "what depends on / discusses X", `backlinks X` surfaces notes that don't mention X by keyword but point at it.
5. **A `DANGLING` target is a dead end** — don't invent its content; note it (it may be a capture gap worth fixing — see `vault-curate`) and move on.

Prefer this over reading whole folders. For a 3+ note synthesis, hand the
resolved paths to an Explore subagent (see below).

## Maps of Content (the nested layer)

As a vault grows, the flat Agent Index doesn't scale, so domains get a **MOC** —
a hub note in `MOCs/` (`MOC - <Topic>.md`, frontmatter `type: moc`, tag `moc`)
linked from the `## Maps of Content` section of `Home.md`. A MOC is a *map, not
a duplicate*: it links its domain's notes with a line of orientation each, plus a
"where the truth lives" section pointing to the repo and external systems.

Reading order: `vaultmem mocs` → the relevant MOC → the specific note or the
repo. **Promote** a domain to a MOC once it passes ~8 related notes, and add it
to `Home.md` (that write is `vault-capture`). Building a *repository's* MOC +
signpost notes is the repo-onboarding workflow in `vault-capture`.

## Workflow A: Reference

Triggered by the reflex above, or by user questions that might be answered better
with prior notes — a person's name, project name, system name, debug pattern,
"what do I know about X", "have I noted Y".

1. **Pick the vault.** Work topics → the work vault. Personal → the personal vault. Ambiguous → both. Unsure which routes here → `vaultmem which`.
2. **Search, then orient.** `vaultmem <query>` first — it is the fastest path to a
   candidate. If the query is vague ("what do I know about X"), `vaultmem index`
   for the shape, then `vaultmem index <section>` for the one section that matches.
3. **Pick candidates.** Match the topic against title and summary. Note 0-N candidate paths.
4. **Route by candidate count and depth:**
   - **0 candidates** → tell the user nothing relevant is in the vault, proceed without it. (If the topic clearly *should* have been written down, that is a capture gap — see `vault-capture`.)
   - **1-2 candidates with focused content** → read inline (`vaultmem cat`, section-scoped where possible) and synthesize directly.
   - **3+ candidates OR cross-cutting synthesis** → use a delegated explorer when available, with the candidate paths and a focused question. Otherwise, inspect only the most relevant notes directly.
5. **Cite the notes used** so the user can open them in Obsidian.

### When to dispatch the Explore subagent

Use it any time you'd otherwise be reading 3+ notes, or any task that requires
synthesizing across notes (e.g. "summarize what I know about distributed
systems"). For one long note, prefer `vaultmem cat --section` over a subagent.
Pattern:

```
Ask an explorer to read these vault notes:
- <path1>
- <path2>
- <path3>

Answer: <focused question>. Quote the notes you used.
```

## Frugality rules

- Never read a full file when a section will do (`vaultmem cat <note> --section '## <Heading>'`).
- Never read a whole folder when the graph will route you (`links`/`backlinks`/`neighbors`).
- Never read `Home.md` whole when `vaultmem index` gives the same orientation 48× cheaper.
- Never answer from search output alone — snippets are leads, notes are answers.

## Handing off

- Something worth writing down came out of this? → `vault-capture`.
- Search kept missing, or you hit `DANGLING` targets and thin spots? → `vault-curate`.
- This is ongoing multi-turn work that should survive `/clear`? → `session`.

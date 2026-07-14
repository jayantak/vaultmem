<!-- GENERATED from the private dotfiles source repo — edit there, not here. -->

# Distill (hot → cold)

Promotes durable insights from the hot session into the vault's MOC tree. Two
callers share one loop:

- **Checkpoint** — distill in place, session stays `active`. No clear.
- **Park** — checkpoint + a `_meta.md` event + "`/clear` is now safe".

Park is checkout; checkpoint is a save-point. Same distill loop underneath.

## Distill loop (shared — where linking is maximized)

For each durable item under `## Decisions` (and any reusable insight in the
work log):

1. Decide the target note (OUTSIDE `Sessions/`):
   - **Cross-session work state** (a decision, a finished analysis, a gotcha that
     the *next session on this project* will need) → the **Project note**
     (`Projects/<name>.md`), into its `## Decisions` or `## Pinned`. The Project
     is the work accretion point — this is what lets individual sessions stay
     small.
   - **Durable domain knowledge** (a reusable pattern, a root cause, an
     architecture fact worth finding from anywhere) → an atomic note in the
     vault's MOC tree, wikilinked into the right `[[MOC - <Topic>]]`.
   Use `vaultmem <query>` to find an existing note first; prefer updating
   over duplicating.
2. Write/update the atomic note via `obsidian-vault` conventions, wikilinked
   into the right MOC with backlinks that **resolve in-vault** — link the MOC by
   its real filename `[[MOC - <Topic>]]` or a declared alias, never a bare topic
   guess. See `obsidian-vault` § Linking Rules.
3. **Verify the note exists before pointing at it.** Run
   `vaultmem resolve "<note basename>"` — it must print a real path. This
   is non-negotiable when a subagent did the write: never collapse the source on
   a subagent's word that the note was created (the recorded failure mode is a
   fabricated note + dangling pointer). No resolve, no collapse.
4. **Collapse the source.** Replace the promoted work-log bullets (and the
   distilled `## Decisions` entry) with a single one-line pointer:
   `→ promoted to [[<note>]]`, using the note's **exact saved basename** (copy
   it from the file you just wrote — do not paraphrase the title, or the pointer
   dangles). This is the decomposition that keeps `_index.md` lean — the trail
   survives as a link, the detail moves to the cold layer.
5. **Leave `## Pinned` intact.** It is the durable in-session anchor, not work-log
   noise — distill never strips or promotes it (a constant may also deserve a
   vault note, but the pinned line stays for fast resume).
   The Project note's own `## Pinned` follows the same rule — promote cross-session
   constants into it, correct them in place, never strip them.
6. Refresh `## Bookmark` and bump `updated:`. If you wrote or edited any note this
   pass, finish with `vaultmem dangling <note>` to confirm no new link dangles.

Cross-vault caveat: only link within the session's own vault — work↔personal
wikilinks dangle.

## Checkpoint (distill in place)

Triggered by "checkpoint", "distill but keep going", or a long-running session
whose `_index.md` is drifting past ~200 lines while the unit is still open.

1. Run the distill loop above.
2. Leave `status: active`. Do NOT touch `_meta.md`. Do NOT tell the user to
   clear — the session continues in this same conversation.
3. One-line confirm: what was promoted and where (e.g. "Checkpointed — 2 notes
   into [[<MOC>]], work log trimmed. Still active.").

## Park (checkout) — adds to checkpoint

Runs on explicit "park" / "wrapping up", or the stopping-point heuristic below.

1. Run the distill loop above.
2. Update `<vault_path>/Sessions/_meta.md` (create if missing): the Sessions
   table (name, last active, status, summary), a repo map aggregated from each
   session's `## Git state`, and the last 10 park events as a timeline.
3. **Update the parent Project.** In `Projects/<name>.md`, flip this session's
   `## Sessions` index entry status (`active` → `parked`/`done`), bump the
   Project's `updated:`, and — on a project with a `linear:` pointer — you
   MAY post a Linear project-update or comment summarizing the unit of work
   (reads/updates are supported; never attempt to write a Linear Document). Then
   renumber the remaining steps.
4. Tell the user `/clear` is now safe; the session resumes from the picker.

Setting status `done` here does NOT move the folder — `vaultmem groom`
later archives every `done` session into `Sessions/_archive/` and flips the
Project line to `archived`. See `SKILL.md` § Lifecycle & grooming for the groom
nudge and the cold-parked retire flow.

### Stopping-point heuristic (park only)

Offer to park when ALL hold:
- The active task list is drained (nothing in-progress).
- A coherent unit of work just closed (a decision reached, a fix landed, a
  question answered).
- Context is growing (long conversation).

Phrase it as an offer, never automatic: "Natural stopping point — distill +
clear?" If the user declines, keep working; do not re-offer until the next unit.
A checkpoint is the lighter alternative when the unit is still open.

# Optional vault layouts

Conventions some vaults adopt on top of the SCHEMA.md contract. **None of these
is part of the schema.** Use one only when `vaultmem index` or the vault's own
`CLAUDE.md`/`AGENTS.md` shows it already exists — never create one unprompted.

## Topical folders

Richer vaults often add `Debug/`, `Incidents/`, `Meetings/`, `Architecture/`,
`People/`, `Areas/`, `Resources/`, or an `Inbox/`. When they are present:

- **Event-shaped notes** (`Meetings/`, `Incidents/`) date-prefix the filename
  `YYYY-MM-DD - <Title>.md` so the folder sorts chronologically. An aggregator
  note uses the earliest date it covers.
- **State-tracking notes** (`Debug/`, `Architecture/`, `People/`) use plain
  descriptive titles, no date prefix.
- **Extending an existing un-prefixed note** leaves the filename alone unless
  asked.

## Daily log

If the vault keeps one (`Daily/YYYY-MM-DD.md`), append under `## Notes`:

```
- **HH:MM** — Brief description → [[Folder/Note Title]]
```

Create today's entry from its daily template if missing.

## The Zettelkasten pattern

Some vaults keep a flat folder of atomic notes where structure comes from links
rather than hierarchy — one idea per note, timestamp-named
(`YYYYMMDDHHMM <Title>.md`), frontmatter `type: zettel`, a `## Related` footer.

If a vault has one, it is the right home for *generalizable* insight: a pattern,
mental model, or trade-off framework you'd want again in six months, as distinct
from a project-specific fact. A debug session's durable lesson ("socket
exhaustion causes OOM under backpressure") is a zettel; the ticket it came from
is not.

If the vault has no such folder, don't create one — capture the insight as an
ordinary note and link it from the relevant MOC. The value is the atomicity and
the links, not the folder name.

# The `judge` extension

`judge` is an optional extension that asks an evaluation model typed questions
about vault content: a yes/no probability, a one-of-N choice, or a rubric score.
The model is TypeSafe's Jev, reached through Vercel AI Gateway.

It is off by default, and it is advisory only. A judgment can annotate or
recommend. It never moves, archives, deletes, or rewrites a note. With the
extension absent, disabled, offline, or denied, every `vaultmem` command behaves
exactly as it does without it.

All HTTP lives in `ext/judge/vaultmem-judge`. The core `vaultmem` script never
opens a socket and gains no dependency. Design and rationale:
[design/judge-extension.md](design/judge-extension.md).

## Install

The extension needs `curl` and `jq`. Core `vaultmem` needs neither.

```bash
./install.sh --ext judge      # symlinks ext/judge into ${XDG_DATA_HOME:-~/.local/share}/vaultmem/ext/
```

`vaultmem judge ...` finds the executable in this order, with no `PATH` lookup:

1. `$VAULTMEM_EXT_DIR/judge/vaultmem-judge`
2. `${XDG_DATA_HOME:-~/.local/share}/vaultmem/ext/judge/vaultmem-judge`
3. `ext/judge/vaultmem-judge` beside the `vaultmem` script itself

Then:

1. Create a Vercel AI Gateway API key. The gateway needs a card on file even
   for free credits.
2. Store it: export `AI_GATEWAY_API_KEY`, or write it to the `key_file` and
   `chmod 600` that file. Hooks often run without your interactive shell's
   environment, which is why `key_file` exists.
3. Set `enabled = true` under `[ext.judge]`, and `judge = true` on each vault
   whose content may leave the machine.
4. Run `vaultmem judge doctor`, then `vaultmem judge doctor --live`.

## Configuration

Keys live in the registry (`~/.config/vaultmem/config.toml`, see
[config.md](config.md)). The extension never parses that file. It runs
`vaultmem judge config`, which prints the parsed values as `key=value` lines.

```toml
[ext.judge]
enabled = true
zdr = false

[vault.personal]
judge = true

[vault.work]
judge = false
```

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Master switch. Anything but `true` makes every call exit 3. |
| `model` | `typesafe-ai/jev` | Gateway model id. The gateway offers no versioned id. |
| `base_url` | `https://ai-gateway.vercel.sh` | Must be `https`. Plain `http` is accepted only for `localhost` and `127.0.0.1`, because the key rides on every call. |
| `zdr` | `true` | Sends `providerOptions.gateway.zeroDataRetention: true`. Never downgraded automatically. |
| `timeout_ms` | `1500` | Whole-request limit, passed to `curl --max-time`. |
| `key_file` | `~/.config/vaultmem/ai-gateway.key` | Read when `AI_GATEWAY_API_KEY` is unset. Refused if its mode is wider than 600. |
| `log` | `true` | Write the decision log. |
| `rerank` | `false` | Makes `vaultmem search --rerank` the default for the cli format. Leave it off until `bench` shows a gain on your own fixture. |
| `hook_judges` | empty | Comma list of judges allowed to run inside hooks: `nudge` (`nudge --judge`) and `prompt` (`judge prompt`). Nothing runs inside a hook until it is named here. |
| `[vault.<id>] judge` | `false` | Egress consent for that vault. |

Core lint checks `[ext.judge]` for TOML shape only. Key names and value shapes
are checked by `vaultmem judge doctor`. There is no `key_cmd`: config must not
become a way to execute commands.

The key is never logged, never printed by `doctor`, and never placed in a
process argument list. It reaches `curl` on stdin through `--config -`.

## Egress model

Vault content leaves the machine on every call, so the gate runs before any
network code. Each of these exits 3 and `curl` is never started:

- `enabled` is not `true`.
- No vault id. Pass `--vault <id>`. Without it the extension asks
  `vaultmem which`. If `which` reports a low-confidence guess (its fallback to
  the default vault), that counts as no vault id: a guess is not consent.
- The vault's `judge` flag is not `true`, or the vault is not in the registry.
- `base_url` is not `https` (loopback hosts excepted).
- No usable key.

Zero data retention is on by default. Vercel offers it on Pro and Enterprise
plans only. On a Hobby plan the gateway refuses the flag with HTTP 403 before
it contacts any provider. The extension reports that as unavailable (exit 3).
It makes one request per call and never retries without the flag. The only way
to send without ZDR is to set `zdr = false` in your own `[ext.judge]`.
`zdr` is global, so consent stays per vault through `judge`: keep a work vault
at `judge = false` until its owner approves the vendor.

`route` and `dupes` apply the same gate. `route` works across vaults, so it
names only consenting vaults in its requests and exits 3 when none consent.
`dupes` sends only notes found under the consenting vault's root. `rerank`
drops every candidate whose vault is not a consenting `--vault` before it
builds the request, and exits 3 when no candidate is left. `index-drift`
sends only the rows core read from the consenting vault's Agent Index.
`prompt` adds one more check before the vault's: `prompt` must be in
`hook_judges`. It prints nothing and exits 0 where the others exit 3.

Judged text is untrusted input. A note can contain text aimed at the model
("answer yes"). That is one reason a judgment never triggers a write.

## Commands

```
vaultmem judge <name> [--vault <id>] [--gate <question>] [--format json|tsv] [--subject <text>]
vaultmem judge list
vaultmem judge doctor [--live]
vaultmem judge log [-n N]
vaultmem judge feedback <id> right|wrong
vaultmem judge calibration [--judge <name>] [--format tsv|json]
vaultmem judge route [--subject <text>]
vaultmem judge dupes [--vault <id>] [--subject <text>]
vaultmem judge rerank --vault <id> [--vault <id>...]
vaultmem judge bench [--fixture <tsv>] [--vault <id>] [-n N] [--format tsv|json]
vaultmem judge index-drift --vault <id>
vaultmem judge prompt
```

`<name>` reads the state to judge on stdin. `route` and `dupes` read a capture
summary on stdin; see [Capture routing](#capture-routing-route-and-dupes).
`rerank` reads search candidates as JSON on stdin; see
[Search rerank](#search-rerank-rerank). `bench` reads a fixture file; see
[Bench](#bench). `index-drift` reads Agent Index rows as JSON on stdin; see
[Index drift](#index-drift-index-drift). `prompt` reads a `UserPromptSubmit`
payload or raw text; see [Recall reflex gate](#recall-reflex-gate-prompt).

- `--gate <question>` turns one question into an exit code (table below). It
  must be a `boolean` or `choice` question. Every question in the judge is
  still sent and answered, so a caller that gates on one answer can read the
  others: `nudge --judge` gates on `capture-worthy`'s `durable` and reads
  `kind`.
- `--format json` (default) prints one object:
  `{"id": "...", "judge": "...", "answers": {...}}`, plus
  `"gate": {"question": "...", "verdict": "yes|no|abstain"}` with `--gate`.
  `answers` is the gateway's answers object, unchanged, so `choice` and `score`
  answers keep their `confidence` field. `id` is the decision log row's id.
- `--format tsv` prints one row per question: `question`, `type`, `value`,
  `probability`. A boolean's value is `yes`, `no`, or `abstain` by its
  thresholds. A choice's value is the chosen key and its probability. A score's
  value is the score, with an empty probability.
- `--subject <text>` is a label for the log row, such as the note's path. It is
  never sent to the gateway.

`list` prints `name`, `shipped|user`, and the description, tab-separated.

`doctor` checks that `curl` and `jq` exist, that `[ext.judge]` has only known
keys with well-formed values, that a key is present and its file mode is 600 or
narrower, and that every judge file parses. It exits 1 on any error and 0
otherwise. A missing key is an error only when `enabled = true`. A key file
that is too open is always an error. `doctor` never prints the key.

`doctor --live` also makes one real call with the `smoke` judge and a fixed
synthetic sentence. No vault content is sent. It prints the gateway's
`.error.type` and `.error.message` on failure, because these are setup faults a
bare exit 3 would hide:

| HTTP | `.error.type` | Cause |
|---|---|---|
| 401 | `authentication_error` | Invalid or missing key. |
| 403 | `customer_verification_required` | No card on file. |
| 403 | `permission_denied` | ZDR requested on a Hobby plan. |
| 404 | `model_not_found` | Wrong `model`. |
| 400 | `invalid_request_error` | A malformed judge file. Says nothing about the key: the schema is checked first. |

`feedback` and `calibration` are offline. They read and append to the local
decision log, never the gateway, so they work with `enabled = false`, with no
key, and with no network. Neither starts `curl`.

`feedback <id> right|wrong` records whether a logged judgment was correct. The
`id` is the one printed on stdout by the call and stored in its log row;
`groom --judge` prints it beside each row for this purpose. The row is
**appended**, never edited, and the rotated `judge.jsonl.1` is never rewritten.
An id is looked up in `.1` first and then the live file, so a decision that has
rotated is still markable. An id with no decision row exits 64 with one line on
stderr. Marking the same id twice is allowed and appends again: the latest
feedback for an id is the one that counts.

`calibration` joins feedback rows to their decision rows and buckets the judged
probability, so you can see whether a stated 0.9 really means 0.9 on your own
notes. The bucketed number is the top choice answer's probability when the
judge has a `choice` question, and the highest boolean probability otherwise:
that is the number a caller acts on. Probabilities below 0.5 fall in no bucket.
Output is TSV with a header, or `--format json`. `--judge <name>` limits it to
one judge. With no feedback rows it prints one line saying so and exits 0.

```
$ vaultmem judge calibration --judge groom-triage
bucket	n	right	accuracy
0.7-0.8	4	3	0.75
0.8-0.9	9	8	0.89
0.9-1.0	17	16	0.94
```


### Capture routing: `route` and `dupes`

Both serve the `vault-capture` skill and scripts. They take the same text a
capture subagent is handed: a short summary of what to write down, first line
first. The skill text that calls them lands in the private upstream skills
source and syncs into `skills/`; it is not edited here.

**`route`** answers where a note goes when there is no repo context for
`vaultmem which` to route on. `which` stays the default; `route` is for a
capture from a chat, a meeting, or a cross-repo session. It asks up to three
`choice` questions about the summary:

| Question | Choices | From |
|---|---|---|
| `vault` | each consenting vault's id | criteria are the vault's `label`, plus `: <description>` when `[vault.<id>] description` is set. A missing `description` line (an older core) reads as empty. |
| `category` | `Projects`, `Sessions`, `Tasks`, `MOCs`, `root` | the SCHEMA.md folder vocabulary, fixed in `route.json`. `root` is a standalone note: the vault root or one of the vault's own topical sections. |
| `moc` | that vault's MOC names | `vaultmem --vault <id> mocs`, one-liners as criteria. Omitted when the vault has no MOC. |

- Only vaults with `judge = true` are ever named in a request, and only they
  can receive the summary. With none, `route` exits 3 and never starts `curl`.
- **One consenting vault: one request.** The vault is known, so `vault` is not
  asked; `category` and `moc` ride together. `probabilities.vault` is `1`.
- **Several consenting vaults: two requests.** `moc` depends on the vault, so
  the first request asks `vault` and `category` and carries the summary once;
  the second asks `moc` over the chosen vault's MOCs and carries it again, to
  that same consenting vault. Both rows are logged under the top vault choice.
  A chosen vault that was not offered is a bad response (exit 3).
- **Low confidence stops early.** When the top `vault` probability is below
  `route.json`'s `thresholds.vault.min_confidence` (0.6), `route` prints what
  it has with `moc: null` and exits 2. The second request is not sent: the
  summary does not go out again on a guess.
- A MOC is offered only when `vaultmem --vault <id> resolve "<name>"` lands
  under that vault's root (from `vaultmem vaults`). Core's `mocs` lists the
  first registry vault's hubs regardless of `--vault`, so for any other vault
  this filter drops them all and `moc` is omitted; a non-consenting vault's MOC
  names never reach a request.

```
$ printf '%s\n' "Nightly rebuild OOM: stream per team" | vaultmem judge route
{"vault":"personal","category":"root","moc":"MOC - Agent Memory",
 "probabilities":{"vault":0.91,"category":0.88,"moc":0.79},
 "id":"20260922T101500Z-4f2a","moc_id":"20260922T101501Z-9c01"}
```

`id` is the first request's log row. `moc_id` appears only when a second
request ran. `moc` and `probabilities.moc` are `null` when `moc` was not asked.

**`dupes`** answers whether an existing note already covers the summary, so the
skill extends that note instead of creating a duplicate. Run it before creating
a note.

- The vault is `--vault <id>`, or `vaultmem which` when omitted, under the same
  rules as a named judge: a low-confidence guess is not consent. The consent
  check runs before the search.
- Candidates come from `vaultmem --vault <id> --format json -n 5 <query>`. The
  query is the summary's first line with punctuation turned into spaces, cut to
  7 words. Search ANDs every term at file level, so a long, specific first line
  finds fewer candidates; lead the summary with its key terms.
- Each distinct file under the vault's root becomes one boolean, `c1` to `c5`:
  "this note already covers the summary". The state is the summary, then per
  candidate its vault-relative path, its title (first `# ` heading, else the
  file name), and its first 20 lines from `vaultmem cat <path> --lines 20`.
  The summary gets a quarter of `max_state_bytes` and each candidate an equal
  share of the rest, so no candidate is crowded out of the request.
- Output is `[{"path": "...", "probability": 0.94}, ...]`, absolute paths,
  sorted by probability, highest first. No candidate: `[]`, exit 0, no `curl`.

```
$ vaultmem judge dupes --vault personal <summary.txt
[{"path":"/vaults/personal/Notes/Streaming patterns.md","probability":0.94},
 {"path":"/vaults/personal/Debug/Athlete rebuild OOM.md","probability":0.21}]
```

Both share the named-judge request path: the same `enabled` check, egress
gate, `zdr` flag, `timeout_ms`, key rules, and log row per request (`judge` is
`route` or `dupes`). Their question text lives in `route.json` and `dupes.json`
and can be overridden like any judge file; `dupes.json`'s `covers` question is
the template for each `cN`, with `{candidate}` replaced by `cN (<path>)`.

**Intended use in `vault-capture`:** call `route` when the capture has no repo
context and `which` would fall back to a guess; call `dupes` on the target
vault before creating a note, and extend the top candidate when its probability
clears 0.85. Exit 3 or 2 means "no opinion": fall back to the skill's manual
steps.

### Search rerank: `rerank`

`rerank` is the primitive under core's `vaultmem search --rerank`, and under
`bench`. Core assembles the candidates and reorders its own output; the
extension builds the one request and returns a score per candidate. Scripts
can call it too.

Stdin is one JSON object:

```json
{"query": "athlete rebuild OOM",
 "candidates": [
   {"id": "c01", "vault": "personal", "path": "/vaults/personal/Debug/Athlete rebuild OOM.md",
    "title": "Athlete rebuild OOM", "description": "Root cause of the nightly rebuild OOM.",
    "head": "first 5 body lines, newline-joined", "matches": ["matched line", "..."]}]}
```

- `query` is a non-empty string. `candidates` holds at most 20 objects.
- Each candidate needs `id` (letters, digits, `_`, `-`; unique) and `vault` (a
  registry id). `path`, `title`, `description`, and `head` are strings or
  `null`; `matches` is an array of strings or `null`. Other fields are
  ignored.
- Anything else exits 64 with one line on stderr, before any config or
  network code.

On exit 0 stdout is one line:

```json
{"id": "20260922T101500Z-4f2a", "scores": {"c01": 2.87, "c04": 1.95}}
```

`id` is the decision log row. Each score is the gateway's `score` for that
candidate: the probability-weighted level, from 0 to 3. The four levels, in
order, are `unrelated`, `mentions`, `relevant`, and `answers` (the candidate
answers the query). Keys follow the input order. A candidate the extension
dropped is absent from `scores`; the caller keeps it in its original order
below the scored ones.

- **Consent.** Every `--vault` must be a consenting vault (`judge = true`) to
  count; a non-consenting `--vault` is ignored, not an error. A candidate is
  kept only when its `vault` is one of the consenting `--vault` ids. Dropped
  candidates are removed before the state is built, so none of their text is
  in the request. No consenting `--vault`, or no candidate left: exit 3, no
  `curl`.
- **State.** The query, then per candidate its `id`, title, description,
  `head` (as "First lines"), and matched lines. `path` is never sent. One
  `score` question per candidate id, from the `relevance` template in
  `rerank.json` with `{candidate}` replaced by the id. Questions share the
  state.
- **Budget.** `rerank.json` sets `max_state_bytes` to 32000 (about 400 tokens
  per candidate at 20 candidates). The query is capped at a quarter of it.
  Over budget, every candidate's matched lines are dropped first; if that is
  still too long, each candidate is cut to an equal share of the budget,
  shortening its `head` first, so no candidate is crowded out. Either step
  logs `truncated: true`.
- The log row's `vault` is the comma-joined list of vaults whose candidates
  were sent, and `subject` is `null`.
- A response that lacks a score for any sent candidate is a bad response
  (exit 3).

### Bench

`bench` decides whether rerank earns its keep on your own notes. It compares
plain search order with reranked order on a fixture of queries whose relevant
notes you know. It is also the model-drift detector: the gateway offers no
versioned model id, so rerun `bench` after a model change and compare.

```
vaultmem judge bench [--fixture <tsv>] [--vault <id>] [-n N] [--format tsv|json]
```

The fixture is TSV, one query per line:

```
athlete rebuild OOM	Debug/Athlete rebuild OOM.md,Notes/Streaming patterns.md
hook timeout	Debug/Hook timeout.md
```

- Column 1 is the query as you would type it to `vaultmem search`. Column 2 is
  a comma-separated list of the relevant notes, as paths relative to the vault
  root. Blank lines and lines starting with `#` are skipped.
- The default path is `${XDG_CONFIG_HOME:-~/.config}/vaultmem/bench.tsv`;
  `--fixture` overrides it. **Keep your real fixture outside the repo**: it
  names private notes. The repo ships only a synthetic one,
  `tests/fixtures/judge/bench.tsv`, over the notes in
  `tests/fixtures/judge/bench-vault/`.
- `--vault` names the vault (else `vaultmem which`, with the usual rule that a
  guess is not consent). `-n` is the candidate cap, 1 to 20, default 20.

For each query `bench`:

1. Runs `vaultmem --vault <id> --format json -n N <query>` and keeps the
   unique files, in order, under the vault's root. That is the baseline.
2. Builds one `rerank` candidate per file: `title` from the first `# `
   heading (else the file name), `description` from frontmatter, `head` from
   the first 5 non-blank body lines after the frontmatter and title (read with
   `vaultmem cat <note> --lines 40`), and up to 2 matched lines from the search
   output.
3. Calls `rerank` and sorts by score, highest first; ties keep baseline order.
   A query with no hits sends nothing and scores 0.

It reports, per query and as the mean over queries: precision@5 (relevant
notes in the top 5, divided by 5), recall@10 (relevant notes in the top 10,
divided by the number of relevant notes), and MRR (1 over the rank of the
first relevant note, 0 when none is found), for baseline and reranked order.
It also sums the input tokens, `cost`, and `market_cost` from the gateway
responses. TSV output starts with one `# model:` line naming the model the
gateway reported, then a header and a row per query, then an `(all)` row:

```
$ vaultmem judge bench --vault personal
# model: typesafe-ai/jev  vault: personal  n: 20
query	candidates	relevant	base_p@5	base_r@10	base_mrr	rerank_p@5	rerank_r@10	rerank_mrr	input_tokens	cost	market_cost
rebuild	6	2	0.0000	0.5000	0.1667	0.2000	0.5000	1.0000	1200	0.00000000	0.00004800
...
(all)	15	8	0.2000	0.8000	0.6333	0.2400	0.8000	0.8667	3000	0.00000000	0.00012000
```

`--format json` prints one object: `model`, `vault`, `n`, `queries` (each with
`query`, `relevant`, `candidates`, `baseline` and `reranked` as
`{p_at_5, r_at_10, mrr}`, `input_tokens`, `cost`, `market_cost`), and
`overall` with the same fields plus `queries`. Metrics are rounded to 4
places.

Exit 0 when it ran. Exit 3 when the extension is unavailable, including a
gateway failure on any query: output is buffered, so stdout stays empty. A
missing fixture, a line with no relevant paths, or a fixture with no queries
exits 64. Every query sends that vault's candidates to the gateway, so `bench`
needs the same consent as `rerank`, and costs one request per query with hits.

### Index drift: `index-drift`

`index-drift` is the primitive under core's `vaultmem doctor --judge`. Core
reads the Agent Index, skips `BROKEN` rows, and sends the rest in batches;
the extension asks whether each row still describes the note it points at.

Stdin is one JSON object with 1 to 5 rows (more hurts accuracy, so more is a
usage error):

```json
{"rows": [
  {"id": "r1", "row": "- [[Athlete rebuild OOM]] - root cause of the nightly rebuild OOM",
   "title": "Athlete rebuild OOM", "frontmatter": "type: debug\nupdated: 2026-09-01",
   "head": "the note's first 30 lines, newline-joined"}]}
```

- Each row needs `id` (letters, digits, `_`, `-`; unique) and a non-empty
  `row`. `title`, `frontmatter`, and `head` are strings or `null`.
- Zero rows, more than 5, or any other shape exits 64 with one line on stderr,
  before any config or network code.

On exit 0 stdout is one line:

```json
{"id": "20260922T101500Z-4f2a", "answers": {"r1": {"probability": 0.97}, "r2": {"probability": 0.04}}}
```

`probability` is the chance the row accurately describes its note. The
extension applies no threshold here; core compares against `index-drift.json`'s
`no` threshold (0.15) and prints a `DRIFT` row at or below it.

- **Consent.** `--vault <id>` is required in practice (core always passes it;
  without it the extension asks `vaultmem which`, and a guess is not consent).
  The vault must set `judge = true`.
- **State.** Per row: `Row <id>`, the index row text, the note title, its
  frontmatter, and its first lines. One boolean per row id, from the
  `accurate` template in `index-drift.json` with `{row}` replaced by the id.
- **Budget.** `max_state_bytes` is 24000. Over budget, each row is cut to an
  equal share, shortening its first lines first, so no row is crowded out.
  The log row records `truncated: true`.
- A response that lacks an answer for any sent row is a bad response (exit 3).
- Findings are informational. `doctor --judge` exits what `doctor` exits.

### Recall reflex gate: `prompt`

`prompt` is for a `UserPromptSubmit` hook. It asks whether the prompt is a
"why" question (a past decision, a root cause, or why something is built the
way it is) and, on a confident yes, prints one line the harness adds to the
agent's context:

```
vaultmem: this looks like a "why" question; run `vaultmem <query>` before re-deriving.
```

- **Stdin.** A JSON object is read as the hook payload and only its `prompt`
  field is sent: never the session id, paths, or any other field. An object
  with no string `prompt`, or an empty prompt, sends nothing. Anything that is
  not a JSON object is sent as raw text.
- **Gate.** It runs only when all of these hold, and otherwise exits 0 with
  nothing on stdout and no `curl`: `enabled = true`; `prompt` is named in
  `hook_judges`; `vaultmem which` routes `$PWD` confidently (a guess is not
  consent); that vault sets `judge = true`.
- **Every prompt leaves the machine** once the gate holds. Leave `prompt` out
  of `hook_judges` to keep prompts local.
- **Verdict.** The `asks_why` boolean in `prompt.json`, gated at 0.85. A no, an
  abstain, a timeout (`timeout_ms`), an HTTP error, or a bad response prints
  nothing and exits 0.
- **Quiet.** Stderr stays empty in every case. `VAULTMEM_VERBOSE=1` prints the
  reason a call printed nothing, for debugging a hook. The only non-zero exit
  is 64, for arguments (`prompt` takes none).
- The log row has `judge: "prompt"` and `subject: "prompt"`.

Wiring: [hooks.md](hooks.md#userpromptsubmit-vaultmem-judge-prompt).

### The owner review loop

Calibration is the only evidence that the vendor's stated probabilities hold on
your data, and it needs your judgment as the ground truth. Over about two weeks:

1. Run `vaultmem groom --judge` as part of your normal grooming. Each row
   carries a recommendation, a probability, and the decision log `id`.
2. When you act on a row, say whether the judgment was right:
   `vaultmem judge feedback <id> right` or `... wrong`. Judge the
   recommendation, not the outcome you chose for other reasons.
3. Read `vaultmem judge calibration` at the end.

What the numbers mean: accuracy in a bucket should roughly match the bucket. A
0.9-1.0 bucket running at 0.6 says the model is overconfident on your notes, so
raise the thresholds in your own judge file under
`~/.config/vaultmem/judges/groom-triage.json`, or stop acting on the column.
A bucket with a handful of rows says nothing yet; wait for more. Nothing here
changes behavior on its own: the judgment stays advisory, and `groom` still
moves notes on `status:` alone.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK. With `--gate`: yes. A boolean's probability is at or above its `yes` threshold, or a choice's top probability is at or above `min_confidence`. |
| 1 | `--gate` only: no. The probability is at or below the `no` threshold. |
| 2 | `--gate` only: abstain. Between thresholds, or the top choice is below `min_confidence`. `route`: the top vault is below `min_confidence`. |
| 3 | Unavailable: disabled, no consent, no key, timeout, any non-2xx status, or a response body that does not parse as an evaluate response. |
| 64 | Usage error: bad flag, unknown judge, unknown or ungateable `--gate` question, malformed `rerank` or `index-drift` stdin (including more than 5 rows), a missing or empty `bench` fixture. |

Without `--gate` the code is 0 or 3. On exit 3 stdout is empty and one line on
stderr names the reason. Callers treat anything other than 0, 1, or 2 as "no
opinion" and carry on as if the extension were absent.

## Judge files

A judge is a JSON file: `ext/judge/judges/<name>.json`, overridden by
`${XDG_CONFIG_HOME:-~/.config}/vaultmem/judges/<name>.json` of the same name.
Names may contain letters, digits, `.`, `_`, and `-`.

```json
{
  "version": 1,
  "description": "Smoke test: one boolean question.",
  "max_state_bytes": 4000,
  "truncate": "head",
  "questions": {
    "failed": {
      "type": "boolean",
      "instructions": "The text reports that something failed.",
      "criteria": { "true": "...", "false": "..." }
    }
  },
  "thresholds": { "failed": { "yes": 0.85, "no": 0.15 } }
}
```

| Field | Required | Meaning |
|---|---|---|
| `version` | yes | Must be `1`. |
| `description` | no | Shown by `list`. |
| `max_state_bytes` | no, default 24000 | State longer than this is cut to this many bytes. |
| `truncate` | no, default `head` | `head` keeps the start (notes). `tail` keeps the end (transcripts). |
| `questions` | yes | Gateway question objects, sent verbatim. Each `type` is `boolean`, `choice`, or `score`. |
| `thresholds` | no | Per question: `yes` and `no` for a boolean (defaults 0.85 and 0.15), `min_confidence` for a choice (default 0.6). Keys must name a question. |

The question shapes are the gateway's: `boolean` takes `criteria` with `true`
and `false` keys, `choice` takes one key per option, and `score` takes an
ordered array of 2 to 10 levels. In a `score` answer the `probabilities` keys
are the zero-based level index as strings. `min_confidence` compares the top
choice's probability, not the gateway's `confidence` field.

Writing questions: one atomic question each, positive phrasing, no double
negatives, explicit criteria, and no arithmetic or date reasoning. The model is
weak at dates and counting. Compute those in bash and keep the state small.

An invalid judge file makes the call exit 3 before any network code runs.

### Shipped judges

| Name | Purpose |
|---|---|
| `smoke` | One boolean. Used by the tests and by `doctor --live`. |
| `groom-triage` | Triage one cold or stale session. Used by `groom --judge`. |
| `capture-worthy` | Does a session transcript hold durable knowledge, and what kind. Used by `nudge --judge`. |
| `route` | Question text for `judge route`. Not run by name. |
| `dupes` | Question text for `judge dupes`. Not run by name. |
| `rerank` | Question text for `judge rerank`: the four-level `relevance` score template. Not run by name. |
| `index-drift` | Question text for `judge index-drift`: the `accurate` boolean template, one per row. Not run by name. |
| `prompt` | Question text for `judge prompt`: the `asks_why` boolean. Not run by name. |

All judges, by who runs them:

| Judge | Consumer | Questions | Hook |
|---|---|---|---|
| `smoke` | `judge doctor --live`, tests | `failed` (boolean) | no |
| `groom-triage` | `vaultmem groom --judge` | 4 booleans, `recommendation` (choice) | no |
| `capture-worthy` | `vaultmem nudge --judge` | `durable` (boolean), `kind` (choice) | Stop, when `nudge` is in `hook_judges` |
| `route` | `judge route` (`vault-capture`) | `vault`, `category`, `moc` (choices) | no |
| `dupes` | `judge dupes` (`vault-capture`) | `c1` to `c5` (booleans) | no |
| `rerank` | `vaultmem search --rerank`, `judge bench` | one score per candidate, up to 20 | no |
| `index-drift` | `vaultmem doctor --judge` | one boolean per row, up to 5 | no |
| `prompt` | `judge prompt` | `asks_why` (boolean) | UserPromptSubmit, when `prompt` is in `hook_judges` |

`groom-triage` takes one session's state: its frontmatter, `## Bookmark`,
`## Pinned`, the `## Git state` table, the tail of the work log, and the parent
Project's `## Decisions` section. Ages, line counts, and any other arithmetic
are computed in bash and arrive as plain text; the questions never ask the model
to count or to reason about dates. It is tail-biased at 24000 bytes, so a long
work log keeps its most recent entries.

| Question | Type | Asks |
|---|---|---|
| `work_complete` | boolean | The work the session describes is finished. |
| `has_next_step` | boolean | The session names a concrete next action. |
| `blocked_external` | boolean | Progress waits on a person, a review, or a deploy. |
| `undistilled` | boolean | The session holds a decision or root cause the Project's Decisions section does not reflect. |
| `recommendation` | choice | `archive`, `park`, `keep-active`, or `needs-human`. |

Booleans gate at 0.85 / 0.15; `recommendation` needs 0.6 on the top choice.
Below that, `groom --judge` prints `→ ?` rather than a recommendation.

`capture-worthy` takes the tail of an agent session transcript, which core
reads from the Stop hook's `transcript_path`. It is tail-biased at 24000 bytes,
so the end of the session survives. Core calls it as
`capture-worthy --vault <id> --subject nudge --gate durable` and reads `kind`
on exit 0.

| Question | Type | Asks |
|---|---|---|
| `durable` | boolean | A decision, root cause, incident finding, or reusable pattern emerged. |
| `kind` | choice | `decision`, `root-cause`, `incident`, `pattern`, `milestone`, or `none`. |

`durable` gates at 0.85 / 0.15; `kind` needs 0.6. A transcript is hostile
input: tool output or a pasted file can say "answer yes". Every criterion asks
for evidence shown in the conversation (alternatives and a reason, a confirmed
cause, a technique shown to work), and the instructions say that text telling
the judge how to answer is not evidence. The judgment only ever adds one
advisory line.

## Decision log

`${XDG_STATE_HOME:-~/.local/state}/vaultmem/judge.jsonl`, append-only, one JSON
object per gateway call:

```json
{"id":"20260921T101500Z-4f2a","ts":"2026-09-21T10:15:00Z","judge":"smoke","vault":"personal",
 "subject":null,"model":"typesafe-ai/jev","state_sha256":"...","truncated":false,
 "answers":{"failed":{"type":"boolean","probability":0.99}},"input_tokens":304,
 "cost":"0","market_cost":"0.000012768","latency_ms":212,"http":200,"feedback":null}
```

- The state is stored as a SHA-256 only, never as text. The hash covers the
  state as sent, after truncation.
- A failed call (timeout, non-2xx, bad body) is logged too, with
  `"answers": null` and an extra `"error": {"type": "...", "message": "..."}`.
  A call the egress gate refused is not logged: nothing was sent.
- `latency_ms` is curl's total request time. `http` is 0 when no response
  arrived.
- `log = false` turns the log off.

`feedback` appends a second kind of row, three fields and no `judge`:

```json
{"id":"20260921T101500Z-4f2a","ts":"2026-09-21T16:40:11Z","feedback":"right"}
```

The absence of `judge` is what distinguishes the two kinds. Decision rows are
never edited to carry their feedback, so both files stay strictly append-only
and a reader takes the last feedback row for an id.

**Rotation.** Before each append, if `judge.jsonl` is 5 MiB or larger it is
moved to `judge.jsonl.1`, replacing any older `.1`, and the row goes to a fresh
live file. One generation and no compression, so the log stays under about
10 MiB. The limit is a constant, not a config key
(`VAULTMEM_JUDGE_LOG_MAX_BYTES` overrides it, for tests). `log`, `feedback`,
and `calibration` all read `.1` first and then the live file, so a tail spans a
rotation and a decision that has rotated is still markable and still counted. A
row that has rotated out of `.1` is gone, along with any feedback on it. A
rotation or write failure never fails the call: the row is skipped.

## Testing

`tests/judge.bats` never touches the network, a real vault, or a real config.
It stubs `VAULTMEM_BIN` with a script that prints the `judge config` contract,
and puts a fake `curl` first on `PATH` that records its arguments, stdin, and
request body, then replays a canned response from `tests/fixtures/judge/`.

```bash
bats tests/judge.bats
VAULTMEM_TEST_BASH=/bin/bash bats tests/judge.bats   # extension under macOS bash 3.2
```

bash resets `$BASH` when it starts, so `BASH=/bin/bash bats ...` on its own
does not change the shell the extension runs under. `VAULTMEM_TEST_BASH` makes
the suite invoke the extension with that interpreter. One test also runs it
under `/bin/bash` whenever that is bash 3.2.

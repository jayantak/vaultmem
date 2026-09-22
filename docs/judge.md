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
| `rerank` | `false` | Reserved for search rerank (a later phase). |
| `hook_judges` | empty | Comma list of judges allowed to run inside hooks (a later phase). |
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
```

`<name>` reads the state to judge on stdin.

- `--gate <question>` turns one question into an exit code (table below). Only
  that question is sent. It must be a `boolean` or `choice` question.
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

`bench` arrives in a later phase. Until then it is a usage error.

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
| 2 | `--gate` only: abstain. Between thresholds, or the top choice is below `min_confidence`. |
| 3 | Unavailable: disabled, no consent, no key, timeout, any non-2xx status, or a response body that does not parse as an evaluate response. |
| 64 | Usage error: bad flag, unknown judge, unknown or ungateable `--gate` question. |

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

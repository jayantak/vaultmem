# Design: the `judge` extension (typed decisions via Vercel AI Gateway)

Status: **proposed, approved in principle by the owner 2026-09-21. Not built.**
Audience: an agent picking this up cold in this repo. Read `AGENTS.md` first.

## 1. Summary

Add an optional extension, `judge`, that lets vaultmem ask an evaluation model
(TypeSafe's Jev, reached through Vercel AI Gateway) typed questions about vault
content: yes/no probabilities, one-of-N choices, and rubric scores. Core
commands consult it at defined points (`groom`, `nudge`, search, `doctor`,
capture routing). With the extension absent, disabled, offline, or denied, every
command behaves exactly as it does today.

Naming: this repo already uses "plugin" for the Claude Code plugin
(`docs/plugin.md`, `.claude-plugin/`). To avoid a collision this document says
**extension**, the directory is `ext/`, and the config header is `[ext.<name>]`.

## 2. Owner decisions already made (do not re-litigate)

- Transport is **Vercel AI Gateway**, not TypeSafe's API directly.
- The integration is **extensive**: many commands, not one.
- It ships as an **extension outside the core script**. `./vaultmem` gains no
  network code and no new dependency.
- This **amends the roadmap non-item** "embeddings / vector / hybrid / rerank /
  LLM query expansion". The amendment is narrow: a stateless, opt-in, remote
  judge with no local models, no daemon, no index, no build step. Embeddings,
  vector stores, and any maintained index stay rejected.

## 3. Ethos contract (hard constraints)

1. `./vaultmem` never opens a socket. All HTTP lives in `ext/judge/vaultmem-judge`.
2. Core dependencies are unchanged. The extension may require `curl` and `jq`.
3. bash 3.2 floor applies to the extension. Add it to `tests/bash32-lint.sh`,
   `shellcheck`, and `shfmt --diff` in CI.
4. **Fail-open to today's behavior.** Extension missing, disabled, no key,
   egress denied, timeout, HTTP error, malformed response: the calling command
   prints what it prints today and exits as it exits today. The fail-quiet
   contract of `status` / `sessions` / `verify` / `nudge` is untouched.
5. **Advisory only.** A judgment may annotate, reorder, or recommend. It never
   moves, archives, deletes, or rewrites a note. `groom` moves stay driven by
   `status:` frontmatter alone.
6. **Deterministic logic stays in bash.** The model is weak at dates, counting,
   and arithmetic. Age thresholds, line counts, and link counts are computed by
   core and are never delegated.
7. No state beyond an append-only decision log (section 9). No cache, no index.

## 4. Gateway API (from Vercel docs, then verified live 2026-09-21)

Use the provider-neutral endpoint, not the TypeSafe-compatible one. It accepts
`providerOptions` (needed for zero data retention) and keeps the door open to
other evaluation models.

```
POST https://ai-gateway.vercel.sh/v1/evaluate
Authorization: Bearer $AI_GATEWAY_API_KEY
Content-Type: application/json
```

Request:

```json
{
  "model": "typesafe-ai/jev",
  "state": "<string | object | array>",
  "questions": {
    "done":  { "type": "boolean", "instructions": "...", "criteria": { "true": "...", "false": "..." } },
    "route": { "type": "choice",  "instructions": "...", "criteria": { "a": "...", "b": "..." } },
    "rel":   { "type": "score",   "instructions": "...", "criteria": ["low: ...", "mid: ...", "high: ..."] }
  },
  "providerOptions": { "gateway": { "zeroDataRetention": true, "only": ["typesafe-ai"] } }
}
```

Response:

```json
{
  "model": "typesafe-ai/jev",
  "answers": {
    "done":  { "type": "boolean", "probability": 0.98 },
    "route": { "type": "choice", "choice": "a", "probabilities": { "a": 1, "b": 0 } },
    "rel":   { "type": "score", "score": 1.97, "probabilities": { "0": 0, "1": 0.03, "2": 0.97 } }
  },
  "usage": { "inputTokens": 275, "outputTokens": 20 },
  "providerMetadata": { "gateway": { "cost": "0.00001155", "generationId": "gen_..." } }
}
```

Errors (verified live, see below): an HTTP status plus

```json
{ "error": { "message": "...", "param": null, "type": "invalid_request_error" } }
```

The envelope is OpenAI-style, nested under `error`, and the discriminator is
`type`. Vercel's docs show a flat `{ "message", "error_type" }` object; the live
gateway does not return that.

Naming differs from TypeSafe's native API: there the yes/no type is `noul` and
its answer field is also `noul`; here they are `boolean` and `probability`, and
score `criteria` is an ordered array. Use the gateway names everywhere.

Model limits (TypeSafe docs): 64k tokens per request, 32k for state plus the
longest question, text only, up to 255 choice options, 2 to 10 score levels,
1,200 requests/min. Input $0.042/M tokens, output free. Typical latency ~100ms
(vendor claim).

### Verified 2026-09-21

Throwaway `curl` calls against `https://ai-gateway.vercel.sh` with synthetic
state only ("The build failed with exit code 1."), on a **Hobby** plan team with
a card on file and $5 of gateway credit.

**Success shape (200).** Matches the example above, with these differences:

- `choice` and `score` answers carry an extra `confidence` number. `boolean`
  answers do not. Live answers from one request:
  `{"type":"choice","choice":"failed","probabilities":{"passed":0,"failed":1,"skipped":0},"confidence":1}`
  and
  `{"type":"score","score":1.99,"probabilities":{"0":0,"1":0.01,"2":0.99},"confidence":0.99}`.
- `score` `probabilities` keys are the **zero-based index of the criteria
  array, as strings** (`"0"`, `"1"`, `"2"`), not the criteria text. `score` is
  the probability-weighted index. `choice` `probabilities` keys are the criteria
  keys; their order is not the request order, so never index by position.
- `boolean`: `{"type":"boolean","probability":0.99}`, as documented.
- `providerMetadata` also has `typesafe.confidence` (a map of question name to
  confidence; empty for boolean-only requests), and `gateway` carries `routing`
  (attempts, provider, per-attempt `startTime`/`endTime`), `cost`, `marketCost`,
  `surchargeCost`, `gatewayCost`, `generationId`. On these calls `cost` was
  `"0"` and `marketCost` was `"0.000012768"` for 304 input tokens, and
  `GET /v1/credits` still read `{"balance":"5","total_used":"0"}` after ~15
  calls. Log `marketCost` as well as `cost`.
- A one-line state plus one boolean question is 304 input tokens and 20 output
  tokens; adding a choice and a score question made it 392 / 53. The per-request
  overhead is about 300 tokens.

**Zero data retention: refused on Hobby.** `zeroDataRetention: true` returns
`403`:

```json
{"error":{"message":"Zero Data Retention (ZDR) is only available for Pro and Enterprise plans. Current plan: hobby. ...",
  "type":"permission_denied",
  "param":{"name":"ZdrUnauthorizedError","statusCode":403,"type":"permission_denied","error":"...","message":"..."}},
 "providerMetadata":{"gateway":{"routing":{...,"totalProviderAttemptCount":0},"generationId":"gen_..."}}}
```

No provider was attempted (`totalProviderAttemptCount: 0`), so nothing left the
gateway. `zeroDataRetention: false` and `only: ["typesafe-ai"]` without the flag
both return 200. The extension detects this case by
`.error.param.name == "ZdrUnauthorizedError"` (or `.error.type ==
"permission_denied"`), reports unavailable, and **never retries without the
flag.** With `zdr = true` as the default, the extension is unavailable on a
Hobby plan until the owner upgrades or sets `zdr = false` (section 14,
question 4). The model entry in `/v1/models` has `"zdr":"all"` and
`"no_training":"all"`: every provider supports ZDR; the plan is the gate.

**Model pinning: none.**

- `GET /typesafe/v1/models` (200) returns one model:
  `{"name":"jev","release_date":"2026-09-15"}` plus a description.
- `GET /v1/models` (200, needs no auth) lists one `typesafe-ai/*` id,
  `typesafe-ai/jev`, with `"type":"evaluation"`, `"context_window":32000`,
  `"max_tokens":0`, `"released":1789430400`, and pricing
  `"input":"0.000000042"`, `"output":"0"` per token ($0.042/M input).
- `typesafe-ai/jev-1.13.0` and `typesafe-ai/jev-1` return `404`
  `{"error":{"message":"Model '...' not found","type":"model_not_found","param":{"modelId":"..."}}}`.
- The evaluate response reports `"model":"typesafe-ai/jev"` and
  `routing.canonicalSlug: "typesafe-ai/jev"`. No versioned id appears anywhere
  in the response.
- So model drift is invisible per call. `release_date` from the models listing
  is the only version signal: `judge doctor --live` and `bench` record it, and
  the bench (section 10) is the drift detector.

**Errors.** Envelope as corrected above. `param` is `null`, an object, or
absent depending on the error, so never assume its type.

| Case | Status | `.error.type` | `.error.message` |
|---|---|---|---|
| Invalid or missing key | 401 | `authentication_error` | `Authentication failed` |
| Unknown question `type` | 400 | `invalid_request_error` | `questions.q.type: Invalid discriminator value. Expected 'boolean' \| 'choice' \| 'score'` |
| Body is not JSON | 400 | `invalid_request_error` | `Invalid JSON in request body` |
| Unknown model slug | 404 | `model_not_found` | `Model '<slug>' not found` |
| ZDR on Hobby plan | 403 | `permission_denied` | `Zero Data Retention (ZDR) is only available for Pro and Enterprise plans. ...` |
| No card on file | 403 | `customer_verification_required` | `AI Gateway requires a valid credit card on file to service requests. ...` |

The request schema is checked before authentication: a malformed question
returns 400 even with an invalid key, so a 400 says nothing about the key. The
card check applies even to the free credits, and while it fails it masks the
404 and the ZDR 403.

**Timing.** Ten sequential one-question calls, a fresh TLS connection each, from
a US residential link: median 394 ms, max 488 ms, min 346 ms total. The
gateway's own provider leg (`routing...endTime - startTime`) was 130 to 147 ms,
so the vendor's ~100 ms is the model alone and the rest is gateway plus
network. `timeout_ms = 1500` leaves about 3x headroom over the observed max.
Informational; no large-state call was timed.

Not checked: calibration, rate limits, and latency with state near
`max_state_bytes`.

## 5. Architecture

```
vaultmem (core, unchanged deps)
  ├─ `judge` subcommand ── thin exec shim ──► ext/judge/vaultmem-judge
  └─ _judge <name>  (internal helper used by groom, nudge, search, doctor)
        returns 3 "unavailable" instantly when the extension is absent/disabled

ext/judge/vaultmem-judge   (bash 3.2, curl + jq)
  ├─ builds request from a judge file + state on stdin
  ├─ enforces egress policy BEFORE any network call
  ├─ calls the gateway with a hard timeout
  ├─ normalizes the response, applies thresholds, sets the exit code
  └─ appends to the decision log
ext/judge/judges/*.json    shipped judge definitions (user overrides win)
```

### 5.1 Core changes (keep them small)

- Dispatch: add `judge) _ext_exec judge "${ARGS[@]:1}" ;;`. Every new
  subcommand steals a word from the default search fall-through. `judge` is the
  only word this design takes. Do **not** add git-style "any `vaultmem-<x>` on
  PATH becomes a subcommand": with search as the default case that is ambiguous.
- `_ext_exec <name> [args]`: resolve the executable in order:
  `$VAULTMEM_EXT_DIR/<name>/vaultmem-<name>`, then
  `${XDG_DATA_HOME:-~/.local/share}/vaultmem/ext/<name>/vaultmem-<name>`, then
  `<dir of $0 after symlink resolution>/ext/<name>/vaultmem-<name>`. No PATH
  lookup. Not found: print one line to stderr, exit 3.
- `_judge <judge-name>`: internal. Reads state on stdin. Returns 3 without
  forking when `[ext.judge] enabled` is not `true`. Otherwise runs the
  extension with `--vault <id>`. Callers treat any non-0/1/2 as "no opinion".
- Environment passed to the extension: `VAULTMEM_BIN` (absolute path to the
  running script), `VAULTMEM_CONFIG`. The extension reads vault data only by
  calling `"$VAULTMEM_BIN"` (`--format json`, `cat --section`, `bookmark`,
  `vaults`). It never parses the registry itself.
- Config (section 6): `_parse_config` / `_lint_config` accept `[ext.<name>]`
  headers and one new `[vault.<id>]` key, `judge`. Update `docs/config.md` and
  the `doctor hard-errors on …` bats tests in the same change.
- A read-only `vaultmem judge config` is served **by the shim in core**, which
  prints the parsed `[ext.judge]` keys plus each vault's `judge` flag as
  `key=value` lines. This is how the extension gets config without a second
  TOML parser. Exact format, one per line, values unquoted, defaults filled in:
  `ext.judge.<key>=<value>` then `vault.<id>.judge=true|false` for every
  registry vault. This format is the core/extension contract; extension tests
  stub `VAULTMEM_BIN` with a script that prints it, so they never depend on
  core's implementation.
- Usage block: add the `judge` lines and **bump both `sed -n '4,Np'` ranges**;
  keep the "usage output ends with the final usage comment line" test pointed
  at the real last line.
- `install.sh --ext judge`: copy or symlink `ext/judge/` into the XDG data dir.

### 5.2 Extension CLI

```
vaultmem judge <name> [--vault <id>] [--gate <question>] [--format json|tsv]   # state on stdin
vaultmem judge list                  # judges available (shipped + user)
vaultmem judge doctor [--live]       # key present, config valid, judges parse; --live = one 1-question call
vaultmem judge bench [--fixture F]   # section 10
vaultmem judge log [-n N]            # tail the decision log
vaultmem judge feedback <id> right|wrong
vaultmem judge calibration           # accuracy per confidence bucket, from feedback rows
```

Exit codes (the contract core and hooks rely on):

| Code | Meaning |
|---|---|
| 0 | ok; with `--gate`, the answer is yes (probability ≥ `yes` threshold) |
| 1 | `--gate` only: the answer is no (probability ≤ `no` threshold) |
| 2 | abstain: between thresholds, or top choice probability below `min_confidence` |
| 3 | unavailable: disabled, not installed, no key, egress denied, timeout, HTTP error (verified: 400, 401, 403, 404), bad response |
| 64 | usage error |

Without `--gate`, stdout is the normalized answers JSON and the code is 0 or 3.

Every non-2xx maps to 3. The extension reads `.error.type` and `.error.message`
(section 4) for the log and for `judge doctor --live`, which must print them:
`authentication_error` (401), `customer_verification_required` (403, no card on
file), `permission_denied` (403, ZDR on a Hobby plan), and `model_not_found`
(404) are setup faults the owner has to fix, and a silent exit 3 hides them. A
400 `invalid_request_error` means a bad judge file, not a bad key.

Normalized answers keep the gateway fields, including `confidence` on `choice`
and `score`. `min_confidence` compares against the top choice's probability, as
the table says, not against `confidence`; the two were equal in the verified
call but nothing documents that they always are.

### 5.3 Judge files

`ext/judge/judges/<name>.json`, overridden by
`${XDG_CONFIG_HOME:-~/.config}/vaultmem/judges/<name>.json`:

```json
{
  "version": 1,
  "description": "Triage one cold or stale session.",
  "max_state_bytes": 24000,
  "questions": { "...": "gateway question objects, verbatim" },
  "thresholds": { "work_complete": { "yes": 0.85, "no": 0.15 }, "recommendation": { "min_confidence": 0.6 } }
}
```

The extension truncates state to `max_state_bytes` (tail-biased for transcripts,
head-biased for notes; the judge file says which via `"truncate": "head"|"tail"`)
and records `truncated: true` in the log. Writing rules for questions: one
atomic question each, positive phrasing, no double negatives, explicit
`criteria`, no arithmetic or date reasoning, keep state small and relevant.

## 6. Configuration

```toml
[ext.judge]
enabled = true                      # default false. Master switch.
model = "typesafe-ai/jev"
base_url = "https://ai-gateway.vercel.sh"
zdr = true                          # default true. Sends zeroDataRetention. Never auto-downgraded. Hobby plan: 403.
timeout_ms = 1500                   # curl --max-time, whole request
key_file = "~/.config/vaultmem/ai-gateway.key"   # used when AI_GATEWAY_API_KEY is unset
log = true
rerank = false                      # search reranks by default only when true
hook_judges = "nudge"               # comma list: judges allowed to run inside hooks

[vault.personal]
judge = true                        # default false. Egress consent, per vault.

[vault.work]
judge = false
```

- Core lint validates `[ext.<name>]` values for **shape only** (the restricted
  TOML subset). Key names inside `[ext.judge]` are validated by
  `vaultmem judge doctor`, which `vaultmem doctor` runs when the extension is
  installed and folds into its exit code as a config error.
- Key lookup: `AI_GATEWAY_API_KEY`, else `key_file` (refuse if mode is wider
  than 600). No `key_cmd`: config must not become an exec surface. Hooks often
  run without the interactive shell's env, which is why `key_file` exists.
- The key is never logged, never echoed by `doctor`, never placed in argv (pass
  the header through `curl --config -` on stdin or `-H @file`).

## 7. Egress policy (the part that must not be wrong)

Vault content, session notes, and transcripts leave the machine. Rules:

1. Every call carries a vault id. Core passes it; standalone calls resolve it
   with `vaultmem which`. No vault id resolved: exit 3.
2. `judge = true` on that vault is required. Otherwise exit 3 **before** curl
   is invoked. A bats test asserts the curl shim was never executed.
3. State assembled from several vaults (cross-vault search) requires the flag
   on **every** contributing vault; candidates from non-consenting vaults are
   left out of the request and keep their ripgrep order below the reranked set.
4. `zdr = true` by default. A gateway refusal of the flag is "unavailable".
   Verified: Hobby plans are refused with 403 `permission_denied` before any
   provider is contacted.
5. The decision log stores a SHA-256 of the state, never the state.
6. Judged text is untrusted input. Notes and transcripts can contain text aimed
   at the model ("answer yes"). This is one reason for constraint 3.5: no
   judgment ever triggers a write or a move.

A work vault stays `judge = false` until its owner approves the vendor.

## 8. Integration points

Each is independently shippable, off unless enabled, and fail-open. "State"
lists what is sent. All state assembly uses existing primitives
(`cmd_bookmark`, `cat --section`, `--format json`).

### 8.1 `groom --judge` (first to build)

Problem: `groom` lists cold-parked and stale-active sessions; deciding each one
costs an agent a full read. Today that is a Sonnet subagent fan-out.

- One request per flagged session. State: frontmatter, `## Bookmark`,
  `## Pinned`, the `## Git state` table, the last ~40 lines of the work log, and
  the parent Project's `## Decisions` section.
- Judge `groom-triage`:
  - `work_complete` (boolean): the described work is finished.
  - `has_next_step` (boolean): the note names a concrete next action.
  - `blocked_external` (boolean): progress waits on a person, review, or deploy.
  - `undistilled` (boolean): the session holds a decision or root cause that
    the Project's Decisions section does not reflect.
  - `recommendation` (choice): `archive` | `park` | `keep-active` | `needs-human`.
- Output: one extra column on the existing groom report
  (`→ archive 0.91 · undistilled`). Low confidence prints `→ ?`. `--format json`
  carries the full answers. Nothing moves. `groom --judge --dry-run` is the same
  report, since the judged path never writes.

### 8.2 `nudge --judge` (Stop hook)

Today: "notes changed but no `_index.md` updated". That misses the common case
where durable knowledge appeared and nothing was written at all.

- State: the tail of the session text the harness supplies on hook stdin.
  **Verify the Stop-hook stdin schema for Claude Code and Codex before
  building**; update `docs/hooks.md` with what was confirmed. If the harness
  gives only a transcript path, read the tail of that file.
- Judge `capture-worthy`: `durable` (boolean: a decision, root cause, incident,
  or reusable pattern emerged), `kind` (choice: decision | root-cause | incident
  | pattern | milestone | none).
- Behavior: the existing heuristic runs first and is unchanged. The judge adds a
  second line only when `durable` is a confident yes and no note was touched.
- Must honor `timeout_ms` and stay silent on exit 3. Runs only if `nudge` is in
  `hook_judges`.

### 8.3 Search rerank: `--rerank`, `--min-score S`

- Candidates: the existing ripgrep result set, capped at `-n` (default 20).
  Curated index hits keep their place at the top; only content hits reorder.
- One request. State: the query plus, per candidate, `{id, title, frontmatter
  description, first 5 body lines, matched lines}`. One `score` question per
  candidate id (`c01`…`c20`), 4 levels: unrelated / mentions / relevant /
  answers-the-query. Questions share state and run in parallel.
- Budget: ~400 tokens per candidate keeps 20 candidates under 10k tokens.
- Order by score, ties keep ripgrep order. `--min-score` drops rows; without it
  nothing is dropped. `--format json` gains `score`. Exit 3: print ripgrep
  order, no warning on stdout (stderr note only with `-v`-style verbosity if one
  exists).
- Off by default. **Do not flip `rerank = true` as a default** until the bench
  (section 10) shows a real gain. At ~130 notes the calling agent already
  reranks cheaply; this feature may never earn its default.

### 8.4 Capture routing: `judge route`, `judge dupes`

Consumers are the `vault-capture` skill and scripts.

- `vaultmem judge route` (summary text on stdin): `vault` (choice over
  consenting vaults; criteria text from each vault's `label` plus a new optional
  `[vault.<id>] description` key), `category` (choice over the SCHEMA.md folder
  vocabulary), `moc` (choice over `vaultmem mocs`). Emits JSON. Routing by
  `which` stays the default; this is for captures with no repo context.
- `vaultmem judge dupes` (summary on stdin): run the normal search for
  candidates, then one boolean per top-5 candidate: "this note already covers
  the summary". Emits paths with probabilities, so the skill updates a note
  instead of creating a duplicate.

### 8.5 `doctor --judge`: semantic index drift

Today `STALE` is a string heuristic. Add `DRIFT`: the Agent-Index row no longer
describes the note.

- Batch ≤5 rows per request (irrelevant context hurts accuracy). State: row
  text plus note title, frontmatter, and first 30 lines. One boolean per row:
  "the row accurately describes this note".
- Findings are informational, printed under their own heading, and **do not
  change `doctor`'s exit code** (a probabilistic lint must not break CI or
  hooks). Not run by base `doctor` or `groom`.

### 8.6 Recall reflex gate: `judge prompt`

For a `UserPromptSubmit`-style hook. State: the prompt text. Boolean
`asks_why`: the prompt asks about a past decision, a root cause, or why
something is built the way it is. Confident yes prints the recall directive;
anything else prints nothing. Every prompt leaves the machine, so it needs its
own entry in `hook_judges` and the consenting-vault rule (vault = `which $PWD`).

### 8.7 Considered, not building

- Session picker suggestions: `vaultmem worktrees` already maps branch to
  session deterministically.
- Judging `frontier`: the score is arithmetic. Leave it alone.
- Auto-archive on high confidence: violates constraint 3.5.

## 9. Decision log

`${XDG_STATE_HOME:-~/.local/state}/vaultmem/judge.jsonl`, one object per call:

```json
{"id":"20260921T101500Z-4f2a","ts":"...","judge":"groom-triage","vault":"personal",
 "subject":"Sessions/foo/_index.md","model":"typesafe-ai/jev","state_sha256":"...",
 "truncated":false,"answers":{...},"input_tokens":1840,"cost":"0.0000773",
 "latency_ms":212,"http":200,"feedback":null}
```

`feedback right|wrong` appends a feedback row keyed by id (the log stays
append-only). `calibration` buckets judged probabilities against feedback. This
is the only evidence that vendor calibration holds for this data, so wire
`groom --judge` to print each row's id.

## 10. Bench

The roadmap already says any search-quality debate gets decided by a fixture,
not by feel. `vaultmem judge bench` makes that real:

- Fixture: a TSV of `query<TAB>relevant-note[,relevant-note…]` kept **outside
  the repo** (it names private notes); `tests/fixtures/` holds a synthetic one
  over the bats fixture vaults.
- Reports precision@5, recall@10, and MRR for plain ripgrep order versus
  reranked order, plus total tokens and cost.
- Doubles as the model-drift detector: rerun after a model change, compare.

## 11. Testing

- bats, same isolation pattern as today (`VAULTMEM_CONFIG` + fixture vaults
  under `$BATS_TEST_TMPDIR`). Put a fake `curl` first on `PATH` that records its
  invocation and replays a canned response or failure mode.
- Must-have cases:
  - extension not installed / `enabled = false`: every integrated command's
    output is byte-identical to the no-extension output.
  - `judge = false` vault: exit 3 and the curl shim was **not** invoked.
  - mixed-consent search: non-consenting vault's content absent from the
    recorded request body.
  - timeout, HTTP 4xx/5xx (canned bodies from section 4: 400, 401, 403, 404),
    malformed JSON, ZDR refusal: exit 3, caller output unchanged, nothing on
    stdout from hooks.
  - threshold mapping to exit 0 / 1 / 2.
  - request bodies match golden files per judge.
  - the key never appears in argv, stdout, stderr, or the log.
  - `BASH=/bin/bash bats …` passes; `bash32-lint.sh` covers `ext/`.
- A live smoke test (`judge doctor --live`) runs only when a key is present and
  never in CI.

## 12. Docs and skills

- New `docs/judge.md` (user reference). Update `docs/config.md`,
  `docs/hooks.md`, `README.md`, `AGENTS.md` (map + gotchas), `SCHEMA.md` only if
  the `description` vault key lands.
- `skills/*/SKILL.md` are generated from a private upstream. Skill changes that
  mention `vaultmem judge …` land upstream and sync in. `subcommand-lint.sh`
  fails if a skill references `judge` before the dispatch entry exists, so the
  core shim merges first.
- Conventional commits; release-please owns the version and changelog.

## 13. Build order

| Phase | Scope | Done when |
|---|---|---|
| 0 | Resolve section 4 unknowns with a throwaway curl. Record findings here. **Done 2026-09-21.** | ZDR behavior and model pinning are known facts |
| 1 | Core shim, config keys + lint, `_ext_exec`, `_judge`, extension skeleton, egress gate, exit codes, log, `doctor`, tests with curl shim, `install.sh --ext` | `vaultmem judge <name>` works end to end against the shim; all CI jobs green |
| 2 | `groom --judge` + `groom-triage` judge, `feedback`, `calibration` | owner runs it on a consenting vault for two weeks and reviews calibration |
| 3 | `nudge --judge`, `judge route`, `judge dupes` | hook stays silent and under `timeout_ms` in every failure mode |
| 4 | `bench`, then search `--rerank` | bench numbers exist; default stays off unless they justify it |
| 5 | `doctor --judge`, `judge prompt` | same fail-open tests as above |

One PR per phase. Phase 1 must not change any existing command's output.

## 14. Open questions for the owner

1. `[vault.<id>] description` as a new registry key for routing criteria: accept?
2. Should `hook_judges` default to empty (nothing runs in hooks until named)?
   This design assumes yes.
3. Decision-log retention: unbounded append, or rotate at a size?
4. **Now a real decision.** Verified: ZDR needs Pro or Enterprise; the owner's
   team is Hobby and gets 403. Either upgrade the team, or accept `zdr = false`
   for the personal vault. Until one happens the extension is unavailable with
   the default config. The model lists `"no_training":"all"`, which covers
   training but not retention.
5. Answered: the gateway needs a card on file even for free credits (403
   `customer_verification_required`). The owner added one on 2026-09-21.

## Sources

- https://vercel.com/docs/ai-gateway/modalities/evaluation
- https://vercel.com/docs/ai-gateway/sdks-and-apis/typesafe
- https://docs.typesafe.ai/models.md
- https://flaviocopes.com/jev/ (secondary; source of the ZDR plan claim)

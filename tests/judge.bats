#!/usr/bin/env bats

# Tests for the judge extension (ext/judge/vaultmem-judge).
# Run: bats tests/judge.bats
#
# Isolation: no network, no real vault, no real config. VAULTMEM_BIN is a stub
# that prints the `judge config` contract, and a fake `curl` sits first on PATH,
# records its argv + stdin + request body, and replays a canned response from
# tests/fixtures/judge/.
#
# bash 3.2: bash resets $BASH at startup, so `BASH=/bin/bash bats …` alone does
# not change the shell the extension runs under. Set VAULTMEM_TEST_BASH=/bin/bash
# (CI's bash32 job does) to run every extension call under that interpreter.

KEY_VALUE="vck_TESTKEY_never_print_me_0123456789"
STATE_TEXT="The build failed with exit code 1."

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  JUDGE="$ROOT/ext/judge/vaultmem-judge"
  FIX="$ROOT/tests/fixtures/judge"
  JUDGE_SH="${VAULTMEM_TEST_BASH:-bash}"

  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-config"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdg-state"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME/vaultmem/judges" "$BATS_TEST_TMPDIR/bin"
  LOG="$XDG_STATE_HOME/vaultmem/judge.jsonl"
  STDERR="$BATS_TEST_TMPDIR/stderr"
  unset VAULTMEM_JUDGE_LOG_MAX_BYTES

  export AI_GATEWAY_API_KEY="$KEY_VALUE"

  # Stub core: `judge config` prints the contract; `which` prints a vault id.
  # For route and dupes it also answers `vaults`, `--vault <id> mocs`,
  # `--vault <id> resolve <name>`, `--vault <id> --format json -n 5 <query>`,
  # and `cat <path> --lines N` from a fixture vault tree under $STUB_VAULTS.
  # With $STUB_SEARCH_DIR set (bench), search answers per query from that dir.
  export STUB_CONFIG="$BATS_TEST_TMPDIR/judge-config"
  export STUB_WHICH_ID="personal" STUB_WHICH_ERR=""
  export STUB_VAULTS="$BATS_TEST_TMPDIR/vaults"
  export STUB_SEARCH_JSON="$BATS_TEST_TMPDIR/search.json" STUB_REC="$BATS_TEST_TMPDIR/stub-rec"
  export VAULTMEM_BIN="$BATS_TEST_TMPDIR/bin/vaultmem-stub"
  printf '[]\n' >"$STUB_SEARCH_JSON"
  cat >"$VAULTMEM_BIN" <<'EOF'
#!/usr/bin/env bash
case "$1" in
judge) [ "${2:-}" = config ] && cat "$STUB_CONFIG" || exit 64 ;;
which)
  printf '%s\n' "$STUB_WHICH_ID"
  [ -z "$STUB_WHICH_ERR" ] || printf '%s\n' "$STUB_WHICH_ERR" >&2
  ;;
vaults)
  for d in "$STUB_VAULTS"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    printf '%s\t%s\tSessions\tHome.md\tdefault\n' "${d##*/}" "$d"
  done
  ;;
cat)
  [ "${3:-}" = "--lines" ] || exit 64
  printf '%s\n' "$2" >>"$STUB_REC.cat"
  awk -v n="$4" 'NR <= n { printf "%6d\t%s\n", NR, $0 }' "$2"
  ;;
--vault)
  id="$2"
  shift 2
  case "$1" in
  mocs)
    # `mocs` lists the primary vault's hubs, whatever --vault says.
    for f in "$STUB_VAULTS/${STUB_PRIMARY:-$id}/MOCs"/*.md; do
      [ -f "$f" ] || continue
      n="${f##*/}"
      printf '%s\n' "${n%.md}"
      awk '/^> /{ sub(/^> +/, ""); print "    " $0; exit }' "$f"
    done
    ;;
  resolve)
    f="$STUB_VAULTS/$id/MOCs/$2.md"
    if [ -f "$f" ]; then printf '%s\n' "$f"; else printf 'DANGLING\n'; exit 1; fi
    ;;
  --format)
    printf '%s\n' "$id $*" >>"$STUB_REC.search"
    if [ -n "${STUB_SEARCH_DIR:-}" ]; then
      # bench: one canned answer per query (the last argument).
      for q; do :; done
      f="$STUB_SEARCH_DIR/$(printf '%s' "$q" | tr ' ' '_').json"
      if [ -f "$f" ]; then cat "$f"; else printf '[]\n'; fi
    else
      cat "$STUB_SEARCH_JSON"
    fi
    ;;
  *) exit 64 ;;
  esac
  ;;
*) exit 64 ;;
esac
EOF
  chmod +x "$VAULTMEM_BIN"
  write_config

  # Fake curl, first on PATH.
  export CURL_REC="$BATS_TEST_TMPDIR/curl-rec"
  export FAKE_CURL_RESPONSE="$FIX/boolean-yes.json" FAKE_CURL_HTTP=200 FAKE_CURL_EXIT=0
  cat >"$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$CURL_REC"
printf 'x\n' >>"$CURL_REC/calls"
n=$(wc -l <"$CURL_REC/calls" | tr -d ' ')
eval "resp=\${FAKE_CURL_RESPONSE_$n:-\$FAKE_CURL_RESPONSE}"
printf '%s\n' "$@" >"$CURL_REC/argv"
cat >"$CURL_REC/stdin"
out=""
prev=""
for a in "$@"; do
  case "$prev" in
  --output) out="$a" ;;
  --data-binary)
    cp "${a#@}" "$CURL_REC/body"
    cp "${a#@}" "$CURL_REC/body.$n"
    ;;
  esac
  prev="$a"
done
if [ "$FAKE_CURL_EXIT" -ne 0 ]; then
  exit "$FAKE_CURL_EXIT"
fi
[ -n "$out" ] && cp "$resp" "$out"
printf '%s 0.212' "$FAKE_CURL_HTTP"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# write_config [key=value …]: the core contract, with per-test overrides.
write_config() {
  local enabled=true zdr=true log=true timeout_ms=1500 personal=true work=false side=false nodesc=false
  local base_url="https://ai-gateway.vercel.sh" key_file="$HOME/.config/vaultmem/ai-gateway.key" extra="" hook_judges=""
  local kv
  for kv in "$@"; do
    case "$kv" in
    extra=*) extra="${kv#extra=}" ;;
    *) eval "${kv%%=*}=\"\${kv#*=}\"" ;;
    esac
  done
  {
    printf 'ext.judge.enabled=%s\n' "$enabled"
    printf 'ext.judge.model=typesafe-ai/jev\n'
    printf 'ext.judge.base_url=%s\n' "$base_url"
    printf 'ext.judge.zdr=%s\n' "$zdr"
    printf 'ext.judge.timeout_ms=%s\n' "$timeout_ms"
    printf 'ext.judge.key_file=%s\n' "$key_file"
    printf 'ext.judge.log=%s\n' "$log"
    printf 'ext.judge.rerank=false\n'
    printf 'ext.judge.hook_judges=%s\n' "$hook_judges"
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf 'vault.personal.judge=%s\n' "$personal"
    printf 'vault.work.judge=%s\n' "$work"
    printf 'vault.side.judge=%s\n' "$side"
    # Contract 1 (Phase 3): label and description per vault, after every other
    # line. nodesc=true drops the description lines, as an older core would.
    printf 'vault.personal.label=Personal\n'
    [ "$nodesc" = true ] || printf 'vault.personal.description=Engineering notes, tooling, agent memory, and home projects.\n'
    printf 'vault.work.label=AcmeCorp Work\n'
    [ "$nodesc" = true ] || printf 'vault.work.description=AcmeCorp Secret Roadmap and customer incidents.\n'
    printf 'vault.side.label=Side Projects\n'
    [ "$nodesc" = true ] || printf 'vault.side.description=\n'
  } >"$STUB_CONFIG"
}

# judge_in <state> <args…>: state on stdin; stdout only in $output, stderr in $STDERR.
judge_in() {
  local state="$1"
  shift
  printf '%s' "$state" | "$JUDGE_SH" "$JUDGE" "$@" 2>"$STDERR"
}

judge_cmd() { "$JUDGE_SH" "$JUDGE" "$@" 2>"$STDERR" </dev/null; }

curl_not_invoked() { [ ! -e "$CURL_REC/calls" ]; }

use_outcome_judge() { cp "$FIX/outcome-judge.json" "$XDG_CONFIG_HOME/vaultmem/judges/outcome.json"; }

# --- thresholds → exit codes ----------------------------------------------------

@test "gate: confident yes exits 0" {
  run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.gate.verdict')" = "yes" ]
  [ "$(printf '%s' "$output" | jq -r '.answers.failed.probability')" = "0.99" ]
}

@test "gate: confident no exits 1" {
  FAKE_CURL_RESPONSE="$FIX/boolean-no.json" run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.gate.verdict')" = "no" ]
}

@test "gate: between thresholds abstains with exit 2" {
  FAKE_CURL_RESPONSE="$FIX/boolean-abstain.json" run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.gate.verdict')" = "abstain" ]
}

@test "gate: thresholds come from the judge file, not a constant" {
  # outcome-judge sets yes=0.9; a 0.87 answer would pass the 0.85 default.
  use_outcome_judge
  jq '.answers.failed.probability = 0.87' "$FIX/boolean-yes.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" run judge_in "$STATE_TEXT" outcome --vault personal --gate failed
  [ "$status" -eq 2 ]
}

@test "gate on a choice: top probability below min_confidence exits 2" {
  use_outcome_judge
  FAKE_CURL_RESPONSE="$FIX/choice-low.json" run judge_in "$STATE_TEXT" outcome --vault personal --gate outcome
  [ "$status" -eq 2 ]
}

@test "gate on a choice: confident top choice exits 0" {
  use_outcome_judge
  jq '{model, answers: {outcome: .answers.outcome}}' "$FIX/mixed.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" run judge_in "$STATE_TEXT" outcome --vault personal --gate outcome
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.answers.outcome.choice')" = "failed" ]
}

@test "without --gate: exit 0 and the answers JSON keeps gateway fields" {
  use_outcome_judge
  FAKE_CURL_RESPONSE="$FIX/mixed.json" run judge_in "$STATE_TEXT" outcome --vault personal
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.answers.severity.confidence')" = "0.99" ]
  [ "$(printf '%s' "$output" | jq -r '.judge')" = "outcome" ]
  [ "$(printf '%s' "$output" | jq 'has("gate")')" = "false" ]
  printf '%s' "$output" | jq -e '.id | test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$")'
}

@test "without --gate: a low probability is still exit 0" {
  FAKE_CURL_RESPONSE="$FIX/boolean-no.json" run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
}

@test "--format tsv prints one row per question" {
  use_outcome_judge
  FAKE_CURL_RESPONSE="$FIX/mixed.json" run judge_in "$STATE_TEXT" outcome --vault personal --format tsv
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  printf '%s\n' "$output" | grep -q "^failed	boolean	yes	0.99$"
  printf '%s\n' "$output" | grep -q "^outcome	choice	failed	1$"
  printf '%s\n' "$output" | grep -q "^severity	score	1.99	$"
}

# --- egress gate: exit 3 BEFORE any network call ---------------------------------

@test "egress: enabled=false exits 3 and curl is never invoked" {
  write_config enabled=false
  run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
}

@test "egress: a judge=false vault exits 3 and curl is never invoked" {
  run judge_in "$STATE_TEXT" smoke --vault work --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
}

@test "egress: a vault missing from the config exits 3 and curl is never invoked" {
  run judge_in "$STATE_TEXT" smoke --vault nosuch --gate failed
  [ "$status" -eq 3 ]
  curl_not_invoked
}

@test "egress: no vault id resolved exits 3 and curl is never invoked" {
  # `which` fell back to the default vault: a low-confidence guess is not consent.
  STUB_WHICH_ERR="vaultmem: low-confidence guess (no match signal) → personal" \
    run judge_in "$STATE_TEXT" smoke --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
}

@test "egress: without --vault a confident \`which\` to a consenting vault proceeds" {
  run judge_in "$STATE_TEXT" smoke --gate failed
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$LOG" | jq -r '.vault')" = "personal" ]
}

@test "egress: without --vault a confident \`which\` to a non-consenting vault exits 3" {
  STUB_WHICH_ID=work run judge_in "$STATE_TEXT" smoke --gate failed
  [ "$status" -eq 3 ]
  curl_not_invoked
}

@test "egress: config unavailable exits 3 and curl is never invoked" {
  VAULTMEM_BIN="$BATS_TEST_TMPDIR/bin/does-not-exist" run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  curl_not_invoked
}

@test "egress: a plain-http base_url exits 3 and curl is never invoked" {
  write_config base_url=http://gateway.example.com
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  curl_not_invoked
}

@test "an invalid judge file exits 3 and curl is never invoked" {
  printf '{"version":1,"questions":{"q":{"type":"noul"}}}' >"$XDG_CONFIG_HOME/vaultmem/judges/bad.json"
  run judge_in "$STATE_TEXT" bad --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
}

# --- failure modes: exit 3, empty stdout -------------------------------------------

@test "timeout exits 3 with empty stdout, and --max-time comes from timeout_ms" {
  write_config timeout_ms=2500
  FAKE_CURL_EXIT=28 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -A1 -x -- '--max-time' "$CURL_REC/argv" | grep -qx '2.500'
  grep -q 'timeout' "$STDERR"
}

@test "HTTP 400 exits 3 with empty stdout" {
  FAKE_CURL_RESPONSE="$FIX/error-400.json" FAKE_CURL_HTTP=400 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -q 'invalid_request_error' "$STDERR"
}

@test "HTTP 401 exits 3 with empty stdout and names the error type" {
  FAKE_CURL_RESPONSE="$FIX/error-401.json" FAKE_CURL_HTTP=401 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -q 'authentication_error' "$STDERR"
  [ "$(tail -n 1 "$LOG" | jq -r '"\(.http) \(.error.type) \(.answers)"')" = "401 authentication_error null" ]
}

@test "HTTP 404 exits 3 with empty stdout" {
  FAKE_CURL_RESPONSE="$FIX/error-404.json" FAKE_CURL_HTTP=404 run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -q 'model_not_found' "$STDERR"
}

@test "HTTP 500 exits 3 with empty stdout" {
  FAKE_CURL_RESPONSE="$FIX/error-500.json" FAKE_CURL_HTTP=500 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "HTTP 502 with a non-JSON error body exits 3 with empty stdout" {
  FAKE_CURL_RESPONSE="$FIX/malformed.txt" FAKE_CURL_HTTP=502 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "malformed JSON on a 200 exits 3 with empty stdout" {
  FAKE_CURL_RESPONSE="$FIX/malformed.txt" run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$(tail -n 1 "$LOG" | jq -r '.error.type')" = "bad_response" ]
}

@test "a 200 with no usable answers exits 3 with empty stdout" {
  FAKE_CURL_RESPONSE="$FIX/empty-answers.json" run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "a 200 missing the gated question exits 3" {
  use_outcome_judge
  FAKE_CURL_RESPONSE="$FIX/boolean-yes.json" run judge_in "$STATE_TEXT" outcome --vault personal --gate outcome
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "ZDR refusal exits 3, empty stdout, and is never retried without the flag" {
  FAKE_CURL_RESPONSE="$FIX/error-403-zdr.json" FAKE_CURL_HTTP=403 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$(wc -l <"$CURL_REC/calls" | tr -d ' ')" -eq 1 ]
  jq -e '.providerOptions.gateway.zeroDataRetention == true' "$CURL_REC/body"
  grep -q 'zero data retention' "$STDERR"
  # The extension never suggests the downgrade at runtime.
  ! grep -q 'zdr = false' "$STDERR" || false
}

# --- request body -------------------------------------------------------------------

@test "request body matches the golden file under zdr=true" {
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/smoke-body-zdr.json")
}

@test "request body matches the golden file under zdr=false: no zeroDataRetention" {
  write_config zdr=false
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/smoke-body-nozdr.json")
  ! grep -q 'zeroDataRetention' "$CURL_REC/body" || false
}

@test "request goes to POST {base_url}/v1/evaluate" {
  write_config base_url=https://gw.example.test/
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  grep -qx 'https://gw.example.test/v1/evaluate' "$CURL_REC/argv"
  grep -A1 -x -- '--request' "$CURL_REC/argv" | grep -qx 'POST'
}

@test "state with quotes, backslashes, and newlines survives as one JSON string" {
  local tricky
  tricky=$(printf 'say "yes"\\n\nline2 \\ end\t{"a":1}')
  run judge_in "$tricky" smoke --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' "$CURL_REC/body")" = "$tricky" ]
}

@test "--gate still sends every question, so a gated caller can read the others" {
  use_outcome_judge
  FAKE_CURL_RESPONSE="$FIX/mixed.json" run judge_in "$STATE_TEXT" outcome --vault personal --gate failed
  [ "$status" -eq 0 ]
  [ "$(jq -c '.questions | keys' "$CURL_REC/body")" = '["failed","outcome","severity"]' ]
  [ "$(printf '%s' "$output" | jq -r '.answers.outcome.choice')" = "failed" ]
}

@test "state is truncated to max_state_bytes, tail-biased, and logged as truncated" {
  use_outcome_judge
  FAKE_CURL_RESPONSE="$FIX/mixed.json" run judge_in "0123456789ABCDEFGHIJ" outcome --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' "$CURL_REC/body")" = "ABCDEFGHIJ" ]
  [ "$(tail -n 1 "$LOG" | jq -r '.truncated')" = "true" ]
}

@test "head-biased truncation keeps the start of the state" {
  jq '.truncate = "head"' "$FIX/outcome-judge.json" >"$XDG_CONFIG_HOME/vaultmem/judges/outcome.json"
  FAKE_CURL_RESPONSE="$FIX/mixed.json" run judge_in "0123456789ABCDEFGHIJ" outcome --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' "$CURL_REC/body")" = "0123456789" ]
}

@test "a user judge file overrides the shipped one of the same name" {
  jq '.questions.failed.instructions = "USER OVERRIDE"' "$ROOT/ext/judge/judges/smoke.json" \
    >"$XDG_CONFIG_HOME/vaultmem/judges/smoke.json"
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.questions.failed.instructions' "$CURL_REC/body")" = "USER OVERRIDE" ]
}

# --- the key ------------------------------------------------------------------------

@test "key from the environment never reaches argv, stdout, stderr, or the log" {
  run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 0 ]
  ! grep -q "$KEY_VALUE" "$CURL_REC/argv" || false
  ! grep -q -- 'Authorization' "$CURL_REC/argv" || false
  [[ "$output" != *"$KEY_VALUE"* ]]
  ! grep -q "$KEY_VALUE" "$STDERR" || false
  ! grep -q "$KEY_VALUE" "$LOG" || false
  ! grep -q "$KEY_VALUE" "$CURL_REC/body" || false
  # It travels on curl's stdin (--config -), and only there.
  grep -qx -- '-' <(grep -A1 -x -- '--config' "$CURL_REC/argv" | tail -n 1)
  grep -q "Authorization: Bearer $KEY_VALUE" "$CURL_REC/stdin"
}

@test "key stays secret on the failure path, even if the gateway echoes it" {
  jq --arg k "$KEY_VALUE" '.error.message = "bad key " + $k' "$FIX/error-401.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" FAKE_CURL_HTTP=401 run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  ! grep -q "$KEY_VALUE" "$CURL_REC/argv" || false
  [ -z "$output" ]
  ! grep -q "$KEY_VALUE" "$STDERR" || false
  ! grep -q "$KEY_VALUE" "$LOG" || false
  grep -q 'redacted' "$LOG"
}

@test "key_file with mode 600 is used when AI_GATEWAY_API_KEY is unset" {
  unset AI_GATEWAY_API_KEY
  mkdir -p "$HOME/.config/vaultmem"
  printf '%s\n' "$KEY_VALUE" >"$HOME/.config/vaultmem/ai-gateway.key"
  chmod 600 "$HOME/.config/vaultmem/ai-gateway.key"
  run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 0 ]
  grep -q "Authorization: Bearer $KEY_VALUE" "$CURL_REC/stdin"
  ! grep -q "$KEY_VALUE" "$CURL_REC/argv" || false
  ! grep -q "$KEY_VALUE" "$LOG" || false
}

@test "key_file given with a leading ~ is expanded" {
  unset AI_GATEWAY_API_KEY
  write_config 'key_file=~/k/gw.key'
  mkdir -p "$HOME/k"
  printf '%s\n' "$KEY_VALUE" >"$HOME/k/gw.key"
  chmod 600 "$HOME/k/gw.key"
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
}

@test "key_file wider than 600 is refused: exit 3, curl never invoked" {
  unset AI_GATEWAY_API_KEY
  mkdir -p "$HOME/.config/vaultmem"
  printf '%s\n' "$KEY_VALUE" >"$HOME/.config/vaultmem/ai-gateway.key"
  chmod 640 "$HOME/.config/vaultmem/ai-gateway.key"
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
  ! grep -q "$KEY_VALUE" "$STDERR" || false
}

@test "no key at all exits 3 and curl is never invoked" {
  unset AI_GATEWAY_API_KEY
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  curl_not_invoked
}

# --- decision log -------------------------------------------------------------------

@test "log row matches the design shape and holds no state text" {
  run judge_in "$STATE_TEXT" smoke --vault personal --subject "Sessions/foo/_index.md"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 1 ]
  [ "$(jq -c 'keys' "$LOG")" = '["answers","cost","feedback","http","id","input_tokens","judge","latency_ms","market_cost","model","state_sha256","subject","truncated","ts","vault"]' ]
  local want
  want=$(printf '%s' "$STATE_TEXT" | shasum -a 256 2>/dev/null | awk '{print $1}')
  [ -n "$want" ] || want=$(printf '%s' "$STATE_TEXT" | sha256sum | awk '{print $1}')
  [ "$(jq -r '.state_sha256' "$LOG")" = "$want" ]
  [ "$(jq -r '[.judge, .vault, .subject, .model, .truncated, .http, .input_tokens, .cost, .market_cost, .latency_ms, .feedback] | @tsv' "$LOG")" = \
    "smoke	personal	Sessions/foo/_index.md	typesafe-ai/jev	false	200	304	0	0.000012768	212	" ]
  [ "$(jq -r '.answers.failed.probability' "$LOG")" = "0.99" ]
  jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$LOG"
  ! grep -q 'build failed' "$LOG" || false
  # The id on stdout is the id in the log, so feedback can key on it later.
  [ "$(printf '%s' "$output" | jq -r '.id')" = "$(jq -r '.id' "$LOG")" ]
}

@test "log=false writes nothing" {
  write_config log=false
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
}

@test "an egress-denied call writes no log row" {
  run judge_in "$STATE_TEXT" smoke --vault work
  [ "$status" -eq 3 ]
  [ ! -e "$LOG" ]
}

@test "rotation: the live file moves to .1, an older .1 is replaced, log -n spans both" {
  mkdir -p "$(dirname "$LOG")"
  printf '{"id":"ancient"}\n' >"$LOG.1"
  printf '{"id":"old-1"}\n{"id":"old-2"}\n' >"$LOG"
  VAULTMEM_JUDGE_LOG_MAX_BYTES=10 run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' "$LOG.1" | tr '\n' ' ')" = "old-1 old-2 " ]
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 1 ]
  [ "$(jq -r '.judge' "$LOG")" = "smoke" ]
  ! grep -q ancient "$LOG" "$LOG.1" || false

  run judge_cmd log -n 2
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(printf '%s\n' "${lines[0]}" | jq -r '.id')" = "old-2" ]
  [ "$(printf '%s\n' "${lines[1]}" | jq -r '.judge')" = "smoke" ]
}

@test "rotation: below the limit nothing moves" {
  mkdir -p "$(dirname "$LOG")"
  printf '{"id":"old-1"}\n' >"$LOG"
  VAULTMEM_JUDGE_LOG_MAX_BYTES=100000 run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  [ ! -e "$LOG.1" ]
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 2 ]
}

@test "rotation failure never fails the call: the log write is skipped" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  mkdir -p "$(dirname "$LOG")"
  printf '{"id":"old-1"}\n' >"$LOG"
  chmod 555 "$(dirname "$LOG")"
  VAULTMEM_JUDGE_LOG_MAX_BYTES=10 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  chmod 755 "$(dirname "$LOG")"
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG")" = '{"id":"old-1"}' ]
  [ ! -e "$LOG.1" ]
}

@test "log: -n limits rows, no log file prints nothing" {
  run judge_cmd log
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  mkdir -p "$(dirname "$LOG")"
  printf '{"id":"a"}\n{"id":"b"}\n{"id":"c"}\n' >"$LOG"
  run judge_cmd log -n 1
  [ "$output" = '{"id":"c"}' ]
  run judge_cmd log
  [ "${#lines[@]}" -eq 3 ]
  run judge_cmd log -n x
  [ "$status" -eq 64 ]
}

# --- usage errors --------------------------------------------------------------------

@test "usage errors exit 64 and never invoke curl" {
  run judge_cmd
  [ "$status" -eq 64 ]
  run judge_in "$STATE_TEXT" smoke --vault personal --format xml
  [ "$status" -eq 64 ]
  run judge_in "$STATE_TEXT" smoke --bogus
  [ "$status" -eq 64 ]
  run judge_in "$STATE_TEXT" smoke --vault
  [ "$status" -eq 64 ]
  run judge_in "$STATE_TEXT" nosuchjudge --vault personal
  [ "$status" -eq 64 ]
  run judge_in "$STATE_TEXT" ../smoke --vault personal
  [ "$status" -eq 64 ]
  run judge_in "$STATE_TEXT" smoke --vault personal --gate nosuchquestion
  [ "$status" -eq 64 ]
  curl_not_invoked
}

@test "--gate on a score question is a usage error" {
  use_outcome_judge
  run judge_in "$STATE_TEXT" outcome --vault personal --gate severity
  [ "$status" -eq 64 ]
  curl_not_invoked
}

@test "bench with no fixture at the default path is a usage error" {
  run judge_cmd bench --vault personal
  [ "$status" -eq 64 ]
  grep -q 'no fixture at .*/vaultmem/bench.tsv' "$STDERR"
  curl_not_invoked
}

@test "feedback and calibration usage errors exit 64" {
  run judge_cmd feedback
  [ "$status" -eq 64 ]
  run judge_cmd feedback only-an-id
  [ "$status" -eq 64 ]
  run judge_cmd feedback an-id maybe
  [ "$status" -eq 64 ]
  run judge_cmd calibration --format xml
  [ "$status" -eq 64 ]
  run judge_cmd calibration --bogus
  [ "$status" -eq 64 ]
  run judge_cmd calibration --judge
  [ "$status" -eq 64 ]
  curl_not_invoked
}

# --- list ---------------------------------------------------------------------------

@test "list shows shipped judges, and a user file wins over a shipped one" {
  run judge_cmd list
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^smoke	shipped	"
  use_outcome_judge
  cp "$ROOT/ext/judge/judges/smoke.json" "$XDG_CONFIG_HOME/vaultmem/judges/smoke.json"
  run judge_cmd list
  printf '%s\n' "$output" | grep -q "^smoke	user	"
  printf '%s\n' "$output" | grep -q "^outcome	user	"
  [ "$(printf '%s\n' "$output" | grep -c '^smoke	')" -eq 1 ]
}

# --- doctor -------------------------------------------------------------------------

@test "doctor: a healthy setup exits 0 and never prints the key" {
  run judge_cmd doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"key present"* ]]
  [[ "$output" == *"judges/smoke.json"* ]]
  [[ "$output" != *"$KEY_VALUE"* ]]
  ! grep -q "$KEY_VALUE" "$STDERR" || false
  curl_not_invoked
}

@test "doctor: an unknown [ext.judge] key is an error" {
  write_config extra=ext.judge.key_cmd=/bin/evil
  run judge_cmd doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown key: key_cmd"* ]]
}

@test "doctor: bad value shapes are errors" {
  write_config enabled=yes timeout_ms=fast base_url=http://gateway.example.com
  run judge_cmd doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"enabled must be true or false"* ]]
  [[ "$output" == *"timeout_ms must be a positive integer"* ]]
  [[ "$output" == *"base_url must be https"* ]]
}

@test "doctor: a key_file wider than 600 is an error and the key is not printed" {
  unset AI_GATEWAY_API_KEY
  mkdir -p "$HOME/.config/vaultmem"
  printf '%s\n' "$KEY_VALUE" >"$HOME/.config/vaultmem/ai-gateway.key"
  chmod 644 "$HOME/.config/vaultmem/ai-gateway.key"
  run judge_cmd doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"wider than 600"* ]]
  [[ "$output" != *"$KEY_VALUE"* ]]
}

@test "doctor: a missing key is an error when enabled, a note when disabled" {
  unset AI_GATEWAY_API_KEY
  run judge_cmd doctor
  [ "$status" -eq 1 ]
  write_config enabled=false
  run judge_cmd doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"note"*"no key"* ]]
}

@test "doctor: a judge file that does not parse, or has a bad type, is an error" {
  printf '{not json' >"$XDG_CONFIG_HOME/vaultmem/judges/broken.json"
  printf '{"version":1,"questions":{"q":{"type":"noul"}},"thresholds":{"zz":{"yes":2}}}' \
    >"$XDG_CONFIG_HOME/vaultmem/judges/badtype.json"
  run judge_cmd doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"broken.json: not valid JSON"* ]]
  [[ "$output" == *"badtype.json: question q: type must be boolean, choice, or score"* ]]
  [[ "$output" == *"badtype.json: thresholds.zz: no such question"* ]]
}

@test "doctor: config unavailable is an error" {
  VAULTMEM_BIN="$BATS_TEST_TMPDIR/bin/does-not-exist" run judge_cmd doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"config not available"* ]]
}

@test "doctor --live: prints the gateway error type and message, never the key" {
  FAKE_CURL_RESPONSE="$FIX/error-401.json" FAKE_CURL_HTTP=401 run judge_cmd doctor --live
  [ "$status" -eq 1 ]
  [[ "$output" == *"authentication_error: Authentication failed"* ]]
  [[ "$output" != *"$KEY_VALUE"* ]]
}

@test "doctor --live: refuses when the extension is disabled" {
  write_config enabled=false
  run judge_cmd doctor --live
  [ "$status" -eq 1 ]
  curl_not_invoked
}

# --- the groom-triage judge -----------------------------------------------------------

# The state a real `groom --judge` call sends: frontmatter, bookmark, pinned,
# git state, work-log tail, and the parent Project's decisions. Ages and counts
# arrive as plain text; the model never computes them.
groom_state() { cat "$FIX/groom-triage-state.txt"; }

@test "groom-triage: the request body matches the golden file" {
  FAKE_CURL_RESPONSE="$FIX/groom-triage-response.json" \
    run judge_in "$(groom_state)" groom-triage --vault personal --subject "Sessions/ad707-athlete-prepare/_index.md"
  [ "$status" -eq 0 ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/groom-triage-body.json")
  # The state fits the budget, so nothing was cut.
  [ "$(tail -n 1 "$LOG" | jq -r '.truncated')" = "false" ]
}

@test "groom-triage: the judge file ships with the four booleans and the choice" {
  run judge_cmd list
  printf '%s\n' "$output" | grep -q "^groom-triage	shipped	"
  local j="$ROOT/ext/judge/judges/groom-triage.json"
  [ "$(jq -r '[.questions | to_entries[] | select(.value.type == "boolean") | .key] | sort | join(",")' "$j")" = \
    "blocked_external,has_next_step,undistilled,work_complete" ]
  [ "$(jq -r '.questions.recommendation.type' "$j")" = "choice" ]
  [ "$(jq -r '[.questions.recommendation.criteria | keys[]] | sort | join(",")' "$j")" = \
    "archive,keep-active,needs-human,park" ]
  [ "$(jq -r '.truncate' "$j")" = "tail" ]
  [ "$(jq -r '.max_state_bytes' "$j")" = "24000" ]
  [ "$(jq -r '.thresholds.recommendation.min_confidence' "$j")" = "0.6" ]
  [ "$(jq -r '[.questions | to_entries[] | select(.value.type == "boolean")
               | "\(.value.criteria | has("true")) \(.value.criteria | has("false"))"] | unique | join("")' "$j")" = \
    "true true" ]
  # Every boolean is gated at the documented thresholds.
  [ "$(jq -r '[.thresholds | to_entries[] | select(.value | has("yes"))
               | "\(.value.yes)/\(.value.no)"] | unique | join(",")' "$j")" = "0.85/0.15" ]
}

@test "groom-triage: a canned response maps to the documented answer fields" {
  FAKE_CURL_RESPONSE="$FIX/groom-triage-response.json" \
    run judge_in "$(groom_state)" groom-triage --vault personal
  [ "$status" -eq 0 ]
  # The four booleans core reads by probability.
  [ "$(printf '%s' "$output" | jq -r '.answers.work_complete.probability')" = "0.04" ]
  [ "$(printf '%s' "$output" | jq -r '.answers.has_next_step.probability')" = "0.93" ]
  [ "$(printf '%s' "$output" | jq -r '.answers.blocked_external.probability')" = "0.88" ]
  [ "$(printf '%s' "$output" | jq -r '.answers.undistilled.probability')" = "0.91" ]
  # The choice core reads by .choice and .probabilities.<choice>.
  [ "$(printf '%s' "$output" | jq -r '.answers.recommendation.choice')" = "park" ]
  [ "$(printf '%s' "$output" | jq -r '.answers.recommendation.probabilities.park')" = "0.81" ]
  [ "$(printf '%s' "$output" | jq -r '.judge')" = "groom-triage" ]
  # The id on stdout keys `judge feedback` later.
  [ "$(printf '%s' "$output" | jq -r '.id')" = "$(jq -r '.id' "$LOG")" ]
}

@test "groom-triage: gating the recommendation maps confidence to exit codes" {
  FAKE_CURL_RESPONSE="$FIX/groom-triage-response.json" \
    run judge_in "$(groom_state)" groom-triage --vault personal --gate recommendation
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.gate.verdict')" = "yes" ]
  # Below min_confidence = 0.6 the caller gets "no opinion".
  FAKE_CURL_RESPONSE="$FIX/groom-triage-response-lowconf.json" \
    run judge_in "$(groom_state)" groom-triage --vault personal --gate recommendation
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.gate.verdict')" = "abstain" ]
}

@test "groom-triage: state over max_state_bytes is cut tail-biased" {
  local big
  big="$(groom_state)$(printf 'x%.0s' $(seq 1 24000))TAIL-MARKER"
  FAKE_CURL_RESPONSE="$FIX/groom-triage-response.json" \
    run judge_in "$big" groom-triage --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state | length' "$CURL_REC/body")" -eq 24000 ]
  # tail-biased: the end survives, the head is gone.
  jq -r '.state' "$CURL_REC/body" | grep -q 'TAIL-MARKER'
  ! jq -r '.state' "$CURL_REC/body" | grep -q 'ad707-athlete-prepare' || false
  [ "$(tail -n 1 "$LOG" | jq -r '.truncated')" = "true" ]
}

# --- feedback ---------------------------------------------------------------------------

# seed_log <file> <line…>: write rows to the live log or the rotated generation.
seed_log() {
  local target="$1"
  shift
  mkdir -p "$(dirname "$LOG")"
  printf '%s\n' "$@" >"$target"
}

DEC_A='{"id":"dec-a","ts":"2026-09-20T10:00:00Z","judge":"groom-triage","vault":"personal","answers":{"recommendation":{"type":"choice","choice":"archive","probabilities":{"archive":0.91,"park":0.09}}},"feedback":null}'
DEC_B='{"id":"dec-b","ts":"2026-09-20T11:00:00Z","judge":"groom-triage","vault":"personal","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.72,"archive":0.28}}},"feedback":null}'
DEC_C='{"id":"dec-c","ts":"2026-09-20T12:00:00Z","judge":"smoke","vault":"personal","answers":{"failed":{"type":"boolean","probability":0.88}},"feedback":null}'

@test "feedback: appends a row and never rewrites the existing ones" {
  seed_log "$LOG" "$DEC_A" "$DEC_B"
  local before
  before=$(cat "$LOG")
  run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # The original rows are byte-identical; the new row is appended after them.
  [ "$(head -n 2 "$LOG")" = "$before" ]
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 3 ]
  [ "$(tail -n 1 "$LOG" | jq -r '[.id, .feedback] | @tsv')" = "dec-a	right" ]
  tail -n 1 "$LOG" | jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")'
  # A feedback row carries no judge field, so it is never itself a decision.
  [ "$(tail -n 1 "$LOG" | jq -r 'has("judge")')" = "false" ]
  curl_not_invoked
}

@test "feedback: an unknown id exits 64 with one stderr line and appends nothing" {
  seed_log "$LOG" "$DEC_A"
  run judge_cmd feedback nosuch-id right
  [ "$status" -eq 64 ]
  [ -z "$output" ]
  [ "$(wc -l <"$STDERR" | tr -d ' ')" -eq 1 ]
  grep -q 'no decision row with id nosuch-id' "$STDERR"
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 1 ]
  curl_not_invoked
}

@test "feedback: an id only in judge.jsonl.1 is found, and .1 is not rewritten" {
  seed_log "$LOG.1" "$DEC_A"
  seed_log "$LOG" "$DEC_B"
  local rotated_before
  rotated_before=$(cat "$LOG.1")
  run judge_cmd feedback dec-a wrong
  [ "$status" -eq 0 ]
  # The rotated file is untouched; the feedback row lands in the live file.
  [ "$(cat "$LOG.1")" = "$rotated_before" ]
  [ "$(tail -n 1 "$LOG" | jq -r '[.id, .feedback] | @tsv')" = "dec-a	wrong" ]
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 2 ]
}

@test "feedback: feedback on a row that already has feedback appends again" {
  seed_log "$LOG" "$DEC_A"
  run judge_cmd feedback dec-a wrong
  [ "$status" -eq 0 ]
  run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 3 ]
  [ "$(jq -r 'select(has("judge") | not) | .feedback' "$LOG" | tr '\n' ' ')" = "wrong right " ]
  # The latest wins at read time: one row, counted right.
  run judge_cmd calibration
  printf '%s\n' "$output" | grep -q "^0.9-1.0	1	1	1$"
}

@test "feedback: a feedback row is not itself a feedbackable decision" {
  seed_log "$LOG" "$DEC_A"
  run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  # dec-a now has a feedback row; feedback on it still resolves to the decision.
  run judge_cmd feedback dec-a wrong
  [ "$status" -eq 0 ]
  # An id that exists only as a feedback row is still unknown.
  run judge_cmd feedback nosuch right
  [ "$status" -eq 64 ]
}

@test "feedback: works with enabled=false and never invokes curl" {
  write_config enabled=false
  seed_log "$LOG" "$DEC_A"
  run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$LOG" | jq -r '.feedback')" = "right" ]
  curl_not_invoked
}

@test "feedback: needs no config at all (the log is local data)" {
  seed_log "$LOG" "$DEC_A"
  VAULTMEM_BIN="$BATS_TEST_TMPDIR/bin/does-not-exist" run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$LOG" | jq -r '.feedback')" = "right" ]
  curl_not_invoked
}

@test "feedback: a rotation during the append is survived without failing" {
  seed_log "$LOG" "$DEC_A"
  VAULTMEM_JUDGE_LOG_MAX_BYTES=10 run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  # The decision row rotated out; the feedback row is alone in the live file.
  [ "$(jq -r '.id' "$LOG.1")" = "dec-a" ]
  [ "$(tail -n 1 "$LOG" | jq -r '[.id, .feedback] | @tsv')" = "dec-a	right" ]
  # Both sides still join: the pair survives the rotation boundary.
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^0.9-1.0	1	1	1$"
}

# --- calibration --------------------------------------------------------------------------

@test "calibration: buckets a synthetic log by judged probability" {
  # One row per bucket, plus a second 0.9-1.0 row marked wrong so accuracy != 1.
  seed_log "$LOG" \
    '{"id":"p55","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.55}}}}' \
    '{"id":"p65","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.65}}}}' \
    '{"id":"p75","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.75}}}}' \
    '{"id":"p85","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.85}}}}' \
    '{"id":"p95","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.95}}}}' \
    '{"id":"p97","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.97}}}}'
  for id in p55 p65 p75 p85 p95; do
    run judge_cmd feedback "$id" right
    [ "$status" -eq 0 ]
  done
  run judge_cmd feedback p97 wrong
  [ "$status" -eq 0 ]

  run judge_cmd calibration
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "bucket	n	right	accuracy" ]
  [ "${lines[1]}" = "0.5-0.6	1	1	1" ]
  [ "${lines[2]}" = "0.6-0.7	1	1	1" ]
  [ "${lines[3]}" = "0.7-0.8	1	1	1" ]
  [ "${lines[4]}" = "0.8-0.9	1	1	1" ]
  [ "${lines[5]}" = "0.9-1.0	2	1	0.5" ]
  [ "${#lines[@]}" -eq 6 ]
  curl_not_invoked
}

@test "calibration: a decision with no feedback is not counted" {
  seed_log "$LOG" "$DEC_A" "$DEC_B"
  run judge_cmd feedback dec-a right
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  # Only dec-a (0.91) appears. dec-b (0.72) has no feedback.
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "0.9-1.0	1	1	1" ]
}

@test "calibration: --judge filters to one judge" {
  seed_log "$LOG" "$DEC_A" "$DEC_C"
  run judge_cmd feedback dec-a right
  run judge_cmd feedback dec-c right
  run judge_cmd calibration
  [ "${#lines[@]}" -eq 3 ]
  run judge_cmd calibration --judge groom-triage
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "0.9-1.0	1	1	1" ]
  run judge_cmd calibration --judge smoke
  [ "${#lines[@]}" -eq 2 ]
  # dec-c is a boolean judge: its probability is the one that gets bucketed.
  [ "${lines[1]}" = "0.8-0.9	1	1	1" ]
  run judge_cmd calibration --judge nosuchjudge
  [ "$status" -eq 0 ]
  [[ "$output" == *"no feedback rows yet"* ]]
}

@test "calibration: joins feedback to decisions across a rotation boundary" {
  seed_log "$LOG.1" "$DEC_A"
  seed_log "$LOG" "$DEC_B"
  run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  run judge_cmd feedback dec-b wrong
  [ "$status" -eq 0 ]
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  # dec-a is in .1 at 0.91, dec-b is live at 0.72. Both join.
  [ "${lines[1]}" = "0.7-0.8	1	0	0" ]
  [ "${lines[2]}" = "0.9-1.0	1	1	1" ]
}

@test "calibration: no feedback rows prints one line and exits 0" {
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"no feedback rows yet"* ]]
  seed_log "$LOG" "$DEC_A"
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"no feedback rows yet"* ]]
  curl_not_invoked
}

@test "calibration: a probability below 0.5 falls in no bucket" {
  seed_log "$LOG" \
    '{"id":"low","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.35}}}}'
  run judge_cmd feedback low right
  [ "$status" -eq 0 ]
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  [[ "$output" == *"no feedback rows yet"* ]]
}

@test "calibration: --format json emits one object per bucket" {
  seed_log "$LOG" "$DEC_A" "$DEC_B"
  run judge_cmd feedback dec-a right
  run judge_cmd feedback dec-b wrong
  run judge_cmd calibration --format json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c 'map(.bucket)')" = '["0.7-0.8","0.9-1.0"]' ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.bucket == "0.9-1.0") | [.n, .right, .accuracy] | @tsv')" = "1	1	1" ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.bucket == "0.7-0.8") | [.n, .right, .accuracy] | @tsv')" = "1	0	0" ]
}

@test "calibration: works with enabled=false and with no config at all" {
  seed_log "$LOG" "$DEC_A"
  run judge_cmd feedback dec-a right
  write_config enabled=false
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "0.9-1.0	1	1	1" ]
  VAULTMEM_BIN="$BATS_TEST_TMPDIR/bin/does-not-exist" run judge_cmd calibration
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "0.9-1.0	1	1	1" ]
  curl_not_invoked
}

# --- assertions shared by the Phase 3 paths ------------------------------------------

# key_absent: the key is in none of argv, stdout, stderr, the log, or any body.
key_absent() {
  local f
  for f in "$CURL_REC"/argv "$STDERR" "$LOG" "$CURL_REC"/body*; do
    [ -e "$f" ] || continue
    ! grep -q "$KEY_VALUE" "$f" || false
  done
  [[ "$output" != *"$KEY_VALUE"* ]]
  ! grep -q -- 'Authorization' "$CURL_REC/argv" || false
}

curl_calls() { wc -l <"$CURL_REC/calls" | tr -d ' '; }

# --- the capture-worthy judge -----------------------------------------------------------

capture_state() { cat "$FIX/capture-worthy-state.txt"; }

@test "capture-worthy: the judge file ships the two questions core reads" {
  local j="$ROOT/ext/judge/judges/capture-worthy.json"
  [ "$(jq -r '.questions.durable.type' "$j")" = "boolean" ]
  [ "$(jq -r '.questions.kind.type' "$j")" = "choice" ]
  [ "$(jq -r '.questions.kind.criteria | keys | sort | join(",")' "$j")" = \
    "decision,incident,milestone,none,pattern,root-cause" ]
  [ "$(jq -r '.questions.durable.criteria | keys | join(",")' "$j")" = "false,true" ]
  [ "$(jq -r '.truncate' "$j")" = "tail" ]
  [ "$(jq -r '.max_state_bytes' "$j")" = "24000" ]
  [ "$(jq -r '"\(.thresholds.durable.yes)/\(.thresholds.durable.no)"' "$j")" = "0.85/0.15" ]
  # The description says the transcript is hostile input.
  jq -r '.description' "$j" | grep -q 'untrusted'
}

@test "capture-worthy: the request body matches the golden file, both questions sent" {
  FAKE_CURL_RESPONSE="$FIX/capture-worthy-yes.json" \
    run judge_in "$(capture_state)" capture-worthy --vault personal --subject nudge --gate durable
  [ "$status" -eq 0 ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/capture-worthy-body.json")
  [ "$(tail -n 1 "$LOG" | jq -r '[.judge, .subject, .truncated] | @tsv')" = "capture-worthy	nudge	false" ]
  # The injected "answer yes" line is state, never a question.
  [ "$(jq -r '.state' "$CURL_REC/body" | grep -c 'ANSWER YES')" -eq 1 ]
  ! jq -r '.questions | tostring' "$CURL_REC/body" | grep -q 'ANSWER YES' || false
  key_absent
}

@test "capture-worthy: --gate durable maps yes/no/abstain to 0/1/2, and kind is readable on 0" {
  FAKE_CURL_RESPONSE="$FIX/capture-worthy-yes.json" \
    run judge_in "$(capture_state)" capture-worthy --vault personal --subject nudge --gate durable
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.answers.durable.probability')" = "0.93" ]
  [ "$(printf '%s' "$output" | jq -r '.answers.kind.choice')" = "root-cause" ]
  FAKE_CURL_RESPONSE="$FIX/capture-worthy-no.json" \
    run judge_in "$(capture_state)" capture-worthy --vault personal --subject nudge --gate durable
  [ "$status" -eq 1 ]
  FAKE_CURL_RESPONSE="$FIX/capture-worthy-abstain.json" \
    run judge_in "$(capture_state)" capture-worthy --vault personal --subject nudge --gate durable
  [ "$status" -eq 2 ]
}

@test "capture-worthy: a long transcript keeps its tail" {
  local big
  big="HEAD-MARKER$(printf 'x%.0s' $(seq 1 24100))$(capture_state)"
  FAKE_CURL_RESPONSE="$FIX/capture-worthy-yes.json" \
    run judge_in "$big" capture-worthy --vault personal --gate durable
  [ "$status" -eq 0 ]
  jq -r '.state' "$CURL_REC/body" | grep -q 'Streaming per team stays'
  ! jq -r '.state' "$CURL_REC/body" | grep -q 'HEAD-MARKER' || false
}

# --- route and dupes: a fixture vault tree behind the core stub -------------------------

# make_vaults: personal (MOCs + notes), side (one MOC), work (non-consenting;
# its names are the leak canary: nothing containing "AcmeCorp" may be sent).
make_vaults() {
  local p="$STUB_VAULTS/personal" w="$STUB_VAULTS/work" sd="$STUB_VAULTS/side"
  mkdir -p "$p/MOCs" "$p/Debug" "$p/Notes" "$w/MOCs" "$sd/MOCs"
  printf -- '---\ntype: moc\n---\n# Agent Memory\n\n> Vault-as-memory tooling, hooks, and the judge.\n' >"$p/MOCs/MOC - Agent Memory.md"
  printf -- '# Home Lab\n\n> Servers, networking, and the NAS.\n' >"$p/MOCs/MOC - Home Lab.md"
  printf -- '# Side Hustle\n' >"$sd/MOCs/MOC - Side Hustle.md"
  printf -- '# AcmeCorp Secret Roadmap\n\n> AcmeCorp internal.\n' >"$w/MOCs/MOC - AcmeCorp Secret Roadmap.md"
  printf -- '---\nupdated: 2026-09-01\n---\n# Athlete rebuild OOM\n\nThe fan-out held every team profile at once.\n' >"$p/Debug/Athlete rebuild OOM.md"
  printf -- '# Streaming patterns\n\nStream per item when the item count is unbounded.\n' >"$p/Notes/Streaming patterns.md"
  printf -- 'No heading in this one.\nIt mentions a nightly rebuild.\n' >"$p/Notes/rebuild log.md"
  printf -- '# AcmeCorp incident\n\nAcmeCorp content.\n' >"$w/AcmeCorp incident.md"
}

# search_hits <file>...: the stub's `--format json` answer, two match lines per
# file so the extension has to dedupe.
search_hits() {
  local f
  for f in "$@"; do
    printf '{"file":"%s","line":1,"text":"a"}\n{"file":"%s","line":3,"text":"b"}\n' "$f" "$f"
  done | jq -s . >"$STUB_SEARCH_JSON"
}

summary() { cat "$FIX/capture-summary.txt"; }

# --- route ----------------------------------------------------------------------------

@test "route: one consenting vault is one request, no vault question, documented JSON" {
  make_vaults
  FAKE_CURL_RESPONSE="$FIX/route-one-response.json" run judge_in "$(summary)" route --subject capture
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 1 ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/route-one-body.json")
  [ "$(printf '%s' "$output" | jq -c 'del(.id)')" = \
    '{"vault":"personal","category":"root","moc":"MOC - Agent Memory","probabilities":{"vault":1,"category":0.88,"moc":0.79}}' ]
  [ "$(printf '%s' "$output" | jq -r '.id')" = "$(jq -r '.id' "$LOG")" ]
  [ "$(jq -r '[.judge, .vault, .subject] | @tsv' "$LOG")" = "route	personal	capture" ]
  key_absent
}

@test "route: two consenting vaults are two requests; the moc request follows the chosen vault" {
  make_vaults
  write_config side=true
  FAKE_CURL_RESPONSE_1="$FIX/route-two-response-1.json" FAKE_CURL_RESPONSE_2="$FIX/route-two-response-2.json" \
    run judge_in "$(summary)" route
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 2 ]
  diff <(jq -S . "$CURL_REC/body.1") <(jq -S . "$FIX/route-two-body-1.json")
  diff <(jq -S . "$CURL_REC/body.2") <(jq -S . "$FIX/route-two-body-2.json")
  [ "$(printf '%s' "$output" | jq -c 'del(.id, .moc_id)')" = \
    '{"vault":"personal","category":"root","moc":"MOC - Agent Memory","probabilities":{"vault":0.91,"category":0.88,"moc":0.79}}' ]
  # Both rows are logged under the chosen vault; stdout names both ids.
  [ "$(jq -r '.vault' "$LOG" | tr '\n' ' ')" = "personal personal " ]
  [ "$(printf '%s' "$output" | jq -r '"\(.id) \(.moc_id)"')" = "$(jq -r '.id' "$LOG" | tr '\n' ' ' | sed 's/ $//')" ]
  key_absent
}

@test "route: no consenting vault exits 3 and curl is never invoked" {
  make_vaults
  write_config personal=false
  run judge_in "$(summary)" route
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
  [ ! -e "$LOG" ]
}

@test "route: enabled=false exits 3 and curl is never invoked" {
  make_vaults
  write_config enabled=false side=true
  run judge_in "$(summary)" route
  [ "$status" -eq 3 ]
  curl_not_invoked
}

@test "route: a non-consenting vault's label, description, and MOCs are in no request" {
  make_vaults
  write_config side=true
  # Core's `mocs` lists the primary vault's hubs whatever --vault says. Make the
  # primary the non-consenting vault to prove those names are filtered out.
  export STUB_PRIMARY=work
  FAKE_CURL_RESPONSE_1="$FIX/route-two-response-1.json" FAKE_CURL_RESPONSE_2="$FIX/route-two-response-2.json" \
    run judge_in "$(summary)" route
  [ "$status" -eq 0 ]
  ls "$CURL_REC"/body.* >/dev/null
  ! grep -l 'AcmeCorp' "$CURL_REC"/body* || false
  ! grep -q '"work"' "$CURL_REC"/body.1 || false
  # No MOC of the chosen vault survived the filter, so no moc request was sent.
  [ "$(curl_calls)" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.moc')" = "null" ]

  # Same with a single consenting vault.
  rm -r "$CURL_REC"
  write_config
  jq 'del(.answers.moc)' "$FIX/route-one-response.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" run judge_in "$(summary)" route
  [ "$status" -eq 0 ]
  ! grep -q 'AcmeCorp' "$CURL_REC/body" || false
  [ "$(jq -c '.questions | keys' "$CURL_REC/body")" = '["category"]' ]
}

@test "route: a top vault below min_confidence exits 2 and sends nothing more" {
  make_vaults
  write_config side=true
  FAKE_CURL_RESPONSE="$FIX/route-lowconf.json" run judge_in "$(summary)" route
  [ "$status" -eq 2 ]
  [ "$(curl_calls)" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -c '[.vault, .moc, .probabilities.vault]')" = '["personal",null,0.52]' ]
}

@test "route: a vault the gateway was not offered is a bad response, exit 3" {
  make_vaults
  write_config side=true
  jq '.answers.vault.choice = "work" | .answers.vault.probabilities = {"work": 0.99}' \
    "$FIX/route-two-response-1.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" run judge_in "$(summary)" route
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$(curl_calls)" -eq 1 ]
}

@test "route: a missing description line (older core) reads as empty" {
  make_vaults
  write_config side=true nodesc=true
  FAKE_CURL_RESPONSE_1="$FIX/route-two-response-1.json" FAKE_CURL_RESPONSE_2="$FIX/route-two-response-2.json" \
    run judge_in "$(summary)" route
  [ "$status" -eq 0 ]
  [ "$(jq -c '.questions.vault.criteria' "$CURL_REC/body.1")" = '{"personal":"Personal","side":"Side Projects"}' ]
}

@test "route: a vault with no MOCs omits the moc question" {
  make_vaults
  rm -r "$STUB_VAULTS/personal/MOCs"
  jq 'del(.answers.moc)' "$FIX/route-one-response.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" run judge_in "$(summary)" route
  [ "$status" -eq 0 ]
  [ "$(jq -c '.questions | keys' "$CURL_REC/body")" = '["category"]' ]
  [ "$(printf '%s' "$output" | jq -c '[.moc, .probabilities.moc]')" = '[null,null]' ]
}

@test "route: a failure on either request exits 3 with empty stdout, key unseen" {
  make_vaults
  write_config side=true
  jq --arg k "$KEY_VALUE" '.error.message = "bad key " + $k' "$FIX/error-401.json" >"$BATS_TEST_TMPDIR/err.json"
  # The second request gets an error body on a 200: a bad response.
  FAKE_CURL_RESPONSE_1="$FIX/route-two-response-1.json" FAKE_CURL_RESPONSE_2="$BATS_TEST_TMPDIR/err.json" \
    run judge_in "$(summary)" route
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  # The first request gets a 401 that echoes the key.
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/err.json" FAKE_CURL_HTTP=401 run judge_in "$(summary)" route
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  key_absent
}

# --- dupes ----------------------------------------------------------------------------

@test "dupes: candidates are judged one boolean each and come back sorted" {
  make_vaults
  local p="$STUB_VAULTS/personal"
  # Duplicates and a path outside the vault root must not become candidates.
  search_hits "$p/Debug/Athlete rebuild OOM.md" "$p/Notes/Streaming patterns.md" \
    "$STUB_VAULTS/work/AcmeCorp incident.md" "$p/Notes/rebuild log.md"
  FAKE_CURL_RESPONSE="$FIX/dupes-response.json" run judge_in "$(summary)" dupes --vault personal --subject capture
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 1 ]
  [ "$(cat "$STUB_REC.search")" = "personal --format json -n 5 Nightly athlete rebuild OOM stream per team" ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/dupes-body.json")
  [ "$(printf '%s' "$output" | jq -r '.[] | "\(.probability) \(.path)"')" = \
    "$(printf '0.94 %s\n0.21 %s\n0.07 %s' "$p/Notes/Streaming patterns.md" "$p/Debug/Athlete rebuild OOM.md" "$p/Notes/rebuild log.md")" ]
  ! grep -q 'AcmeCorp' "$CURL_REC/body" || false
  [ "$(jq -r '[.judge, .vault, .subject] | @tsv' "$LOG")" = "dupes	personal	capture" ]
  key_absent
}

@test "dupes: zero candidates prints [] and never invokes curl" {
  make_vaults
  run judge_in "$(summary)" dupes --vault personal
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  curl_not_invoked
  # Hits only in another vault are still zero candidates.
  search_hits "$STUB_VAULTS/work/AcmeCorp incident.md"
  run judge_in "$(summary)" dupes --vault personal
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  curl_not_invoked
}

@test "dupes: a non-consenting vault exits 3 before search or curl" {
  make_vaults
  search_hits "$STUB_VAULTS/work/AcmeCorp incident.md"
  run judge_in "$(summary)" dupes --vault work
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
  [ ! -e "$STUB_REC.search" ]
}

@test "dupes: without --vault a confident which is used; a guess is not consent" {
  make_vaults
  search_hits "$STUB_VAULTS/personal/Notes/Streaming patterns.md"
  jq '{model, answers: {c1: .answers.c2}}' "$FIX/dupes-response.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" run judge_in "$(summary)" dupes
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c 'map(.probability)')" = '[0.94]' ]
  rm -r "$CURL_REC"
  STUB_WHICH_ERR="vaultmem: low-confidence guess (no match signal) → personal" run judge_in "$(summary)" dupes
  [ "$status" -eq 3 ]
  curl_not_invoked
}

@test "dupes: every candidate keeps a share of the state budget" {
  make_vaults
  local p="$STUB_VAULTS/personal"
  jq '.max_state_bytes = 2000' "$ROOT/ext/judge/judges/dupes.json" >"$XDG_CONFIG_HOME/vaultmem/judges/dupes.json"
  printf '# Huge\n%s\n' "$(printf 'y%.0s' $(seq 1 3000))" >"$p/Notes/Huge.md"
  search_hits "$p/Notes/Huge.md" "$p/Notes/Streaming patterns.md"
  jq '{model, answers: {c1: .answers.c1, c2: .answers.c2}}' "$FIX/dupes-response.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" run judge_in "$(summary)" dupes --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state | utf8bytelength' "$CURL_REC/body")" -le 2000 ]
  jq -r '.state' "$CURL_REC/body" | grep -q 'Candidate c2'
  jq -r '.state' "$CURL_REC/body" | grep -q 'Stream per item'
  [ "$(tail -n 1 "$LOG" | jq -r '.truncated')" = "true" ]
}

@test "route and dupes usage errors exit 64 and never invoke curl" {
  run judge_in "x" route --bogus
  [ "$status" -eq 64 ]
  run judge_in "x" route --subject
  [ "$status" -eq 64 ]
  run judge_in "x" dupes --vault
  [ "$status" -eq 64 ]
  run judge_in "x" dupes personal
  [ "$status" -eq 64 ]
  curl_not_invoked
}

# --- rerank ---------------------------------------------------------------------------

rerank_in() {
  local input="$1"
  shift
  "$JUDGE_SH" "$JUDGE" rerank "$@" <"$input" 2>"$STDERR"
}

@test "rerank: the request body matches the golden file; a non-consenting candidate is absent" {
  write_config side=true
  FAKE_CURL_RESPONSE="$FIX/rerank-response.json" \
    run rerank_in "$FIX/rerank-input.json" --vault personal --vault side --vault work
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 1 ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/rerank-body.json")
  # c02 is the work vault's: no trace of it in the request, and no score for it.
  ! grep -q 'AcmeCorp' "$CURL_REC/body" || false
  ! grep -q 'c02' "$CURL_REC/body" || false
  [ "$(jq -c '.questions | keys' "$CURL_REC/body")" = '["c01","c03","c04"]' ]
  # Paths are never sent.
  ! grep -q '/vaults/' "$CURL_REC/body" || false
  [ "$(printf '%s' "$output" | jq -c '.scores')" = '{"c01":2.87,"c03":0.4,"c04":1.95}' ]
  [ "$(printf '%s' "$output" | jq -r '.id')" = "$(jq -r '.id' "$LOG")" ]
  [ "$(jq -r '[.judge, .vault, .truncated] | @tsv' "$LOG")" = "rerank	personal,side	false" ]
  key_absent
}

@test "rerank: scores are the gateway's score per candidate id, in candidate order" {
  jq -c '{query, candidates: [.candidates[] | select(.vault == "personal")]}' "$FIX/rerank-input.json" >"$BATS_TEST_TMPDIR/in.json"
  jq '.answers |= { c04: .c04, c01: .c01 }' "$FIX/rerank-response.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" run rerank_in "$BATS_TEST_TMPDIR/in.json" --vault personal
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.scores')" = '{"c01":2.87,"c04":1.95}' ]
  [ "$(printf '%s' "$output" | jq -c 'keys')" = '["id","scores"]' ]
  # Each question is a 4-level score over the rerank.json template.
  [ "$(jq -r '.questions.c01.type' "$CURL_REC/body")" = "score" ]
  [ "$(jq '.questions.c04.criteria | length' "$CURL_REC/body")" -eq 4 ]
  jq -r '.questions.c04.instructions' "$CURL_REC/body" | grep -q 'candidate c04 answers'
}

@test "rerank: a response missing a candidate's score is a bad response, exit 3" {
  jq -c '{query, candidates: [.candidates[] | select(.vault == "personal")]}' "$FIX/rerank-input.json" >"$BATS_TEST_TMPDIR/in.json"
  jq '.answers |= { c01: .c01 }' "$FIX/rerank-response.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" run rerank_in "$BATS_TEST_TMPDIR/in.json" --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "rerank: zero candidates, or none from a consenting vault, exits 3 and never invokes curl" {
  printf '{"query":"x","candidates":[]}' >"$BATS_TEST_TMPDIR/empty.json"
  run rerank_in "$BATS_TEST_TMPDIR/empty.json" --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
  jq -c '{query, candidates: [.candidates[] | select(.vault == "work")]}' "$FIX/rerank-input.json" >"$BATS_TEST_TMPDIR/work.json"
  run rerank_in "$BATS_TEST_TMPDIR/work.json" --vault personal --vault work
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
  [ ! -e "$LOG" ]
}

@test "rerank: no consenting --vault, or enabled=false, exits 3 and never invokes curl" {
  run rerank_in "$FIX/rerank-input.json" --vault work
  [ "$status" -eq 3 ]
  grep -q 'no --vault has consented' "$STDERR"
  write_config enabled=false
  run rerank_in "$FIX/rerank-input.json" --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
}

@test "rerank: malformed stdin or missing --vault exits 64 and never invokes curl" {
  printf 'not json' >"$BATS_TEST_TMPDIR/bad.json"
  run rerank_in "$BATS_TEST_TMPDIR/bad.json" --vault personal
  [ "$status" -eq 64 ]
  jq '.candidates[1].id = "c01"' "$FIX/rerank-input.json" >"$BATS_TEST_TMPDIR/dup.json"
  run rerank_in "$BATS_TEST_TMPDIR/dup.json" --vault personal
  [ "$status" -eq 64 ]
  jq 'del(.candidates[0].vault)' "$FIX/rerank-input.json" >"$BATS_TEST_TMPDIR/novault.json"
  run rerank_in "$BATS_TEST_TMPDIR/novault.json" --vault personal
  [ "$status" -eq 64 ]
  jq '.candidates = [range(21) | {id: "c\(.)", vault: "personal", title: "t"}]' "$FIX/rerank-input.json" >"$BATS_TEST_TMPDIR/many.json"
  run rerank_in "$BATS_TEST_TMPDIR/many.json" --vault personal
  [ "$status" -eq 64 ]
  jq 'del(.query)' "$FIX/rerank-input.json" >"$BATS_TEST_TMPDIR/noquery.json"
  run rerank_in "$BATS_TEST_TMPDIR/noquery.json" --vault personal
  [ "$status" -eq 64 ]
  run rerank_in "$FIX/rerank-input.json"
  [ "$status" -eq 64 ]
  run rerank_in "$FIX/rerank-input.json" --vault
  [ "$status" -eq 64 ]
  curl_not_invoked
}

# big_candidates <n>: n personal candidates, each with a long head and long
# matched lines, and a HEADEND marker at the end of every head.
big_candidates() {
  jq -n --argjson n "$1" '{ query: "athlete rebuild OOM", candidates: [range(1; $n + 1) as $i
    | { id: "c\(if $i < 10 then "0" else "" end)\($i)", vault: "personal", path: "/p/\($i).md",
        title: "Note \($i)", description: "Description \($i)",
        head: ("h" * 200 + " HEADEND\($i)"),
        matches: ["MATCH\($i) " + ("m" * 300), "MATCH\($i)b"] }] }'
}

@test "rerank: over max_state_bytes, matched lines go first, then heads are cut to a share" {
  big_candidates 3 >"$BATS_TEST_TMPDIR/in.json"
  local resp="$BATS_TEST_TMPDIR/resp.json"
  jq -n '{model: "typesafe-ai/jev", answers: {c01: {type: "score", score: 1}, c02: {type: "score", score: 2},
    c03: {type: "score", score: 3}}}' >"$resp"

  # Room for everything but the matched lines: they are dropped, heads survive.
  jq '.max_state_bytes = 1000' "$ROOT/ext/judge/judges/rerank.json" >"$XDG_CONFIG_HOME/vaultmem/judges/rerank.json"
  FAKE_CURL_RESPONSE="$resp" run rerank_in "$BATS_TEST_TMPDIR/in.json" --vault personal
  [ "$status" -eq 0 ]
  ! jq -r '.state' "$CURL_REC/body" | grep -q 'MATCH' || false
  [ "$(jq -r '.state' "$CURL_REC/body" | grep -c 'HEADEND')" -eq 3 ]
  [ "$(tail -n 1 "$LOG" | jq -r '.truncated')" = "true" ]

  # Tighter: heads are cut too, but every candidate keeps its block.
  jq '.max_state_bytes = 400' "$ROOT/ext/judge/judges/rerank.json" >"$XDG_CONFIG_HOME/vaultmem/judges/rerank.json"
  FAKE_CURL_RESPONSE="$resp" run rerank_in "$BATS_TEST_TMPDIR/in.json" --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state | utf8bytelength' "$CURL_REC/body")" -le 400 ]
  ! jq -r '.state' "$CURL_REC/body" | grep -q 'HEADEND' || false
  local c
  for c in c01 c02 c03; do jq -r '.state' "$CURL_REC/body" | grep -q "Candidate $c"; done
  jq -r '.state' "$CURL_REC/body" | grep -q 'Title: Note 3'
  [ "$(tail -n 1 "$LOG" | jq -r '.truncated')" = "true" ]

  # Under budget: nothing is cut and truncated stays false.
  rm "$XDG_CONFIG_HOME/vaultmem/judges/rerank.json"
  FAKE_CURL_RESPONSE="$resp" run rerank_in "$BATS_TEST_TMPDIR/in.json" --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' "$CURL_REC/body" | grep -c 'MATCH')" -eq 6 ]
  [ "$(tail -n 1 "$LOG" | jq -r '.truncated')" = "false" ]
}

@test "rerank: a failed request exits 3 with empty stdout, key unseen" {
  jq --arg k "$KEY_VALUE" '.error.message = "bad key " + $k' "$FIX/error-401.json" >"$BATS_TEST_TMPDIR/err.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/err.json" FAKE_CURL_HTTP=401 \
    run rerank_in "$FIX/rerank-input.json" --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$(jq -r '.error.type' "$LOG")" = "authentication_error" ]
  key_absent
}

# --- bench ----------------------------------------------------------------------------

# make_bench: the synthetic bench vault as the personal vault, and one canned
# `--format json` answer per query from bench-search.tsv (two match lines per
# file, so bench has to dedupe), plus one canned rerank response per query.
make_bench() {
  mkdir -p "$STUB_VAULTS" "$BATS_TEST_TMPDIR/search"
  ln -s "$FIX/bench-vault" "$STUB_VAULTS/personal"
  export STUB_SEARCH_DIR="$BATS_TEST_TMPDIR/search"
  local q rels
  while IFS=$'\t' read -r q rels; do
    case "$q" in "" | \#*) continue ;; esac
    jq -n --arg rels "$rels" --arg root "$STUB_VAULTS/personal" '
      [$rels | split(",")[] | $root + "/" + . | {file: ., line: 1, text: "match one"}, {file: ., line: 3, text: "match two"}]' \
      >"$STUB_SEARCH_DIR/$(printf '%s' "$q" | tr ' ' '_').json"
  done <"$FIX/bench-search.tsv"
  local i
  for i in 1 2 3 4 5; do export "FAKE_CURL_RESPONSE_$i=$FIX/bench-response-$i.json"; done
}

# Expected numbers, by hand, from bench.tsv (relevant sets), bench-search.tsv
# (baseline order), and bench-response-N.json (scores). P@5 divides by 5,
# R@10 by the relevant count, MRR is 1/rank of the first relevant hit.
#
#   rebuild: baseline Rebuild log, nightly-rebuild, Grocery, Ripgrep, Hooks
#     overview, Athlete OOM (relevant: Athlete OOM, Streaming; Streaming never
#     retrieved). Baseline P@5 0/5 = 0, R@10 1/2 = 0.5, MRR 1/6 = 0.1667.
#     Scores 1.2 1.0 0.1 0.3 0.2 2.9 put Athlete OOM first: P@5 1/5 = 0.2,
#     R@10 0.5, MRR 1.
#   search ranking: Ripgrep, Search ranking (relevant: Search ranking).
#     Baseline 0.2, 1, 1/2 = 0.5. Scores 1.0 2.8: 0.2, 1, 1.
#   hook timeout: Hooks overview, Hook timeout, Egress (both Hooks notes
#     relevant). Baseline 2/5 = 0.4, 1, 1. Scores 2.0 2.9 0.2: 0.4, 1, 1.
#   egress consent: Egress only (relevant: Egress, Hooks overview). Baseline
#     0.2, 1/2 = 0.5, 1. Score 2.5: unchanged.
#   nightly: nightly-rebuild, Rebuild log, Grocery (relevant: Rebuild log).
#     Baseline 0.2, 1, 0.5. Scores 1.5 1.5 3.0: Grocery first, the tie keeps
#     nightly-rebuild ahead of Rebuild log, so MRR 1/3 = 0.3333.
#   overall (mean of five): baseline P@5 1.0/5 = 0.2, R@10 4/5 = 0.8,
#     MRR (1/6 + 0.5 + 1 + 1 + 0.5)/5 = 0.6333; reranked P@5 1.2/5 = 0.24,
#     R@10 0.8, MRR (1 + 1 + 1 + 1 + 1/3)/5 = 0.8667.
#   tokens 1200 + 400 + 600 + 250 + 550 = 3000; market cost 0.000048 +
#     0.000016 + 0.000024 + 0.00001 + 0.000022 = 0.00012; cost "0" each.
@test "bench: precision@5, recall@10, MRR, tokens, cost, and model on the synthetic fixture" {
  make_bench
  run judge_cmd bench --fixture "$FIX/bench.tsv" --vault personal
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 5 ]
  diff <(printf '%s\n' "$output") - <<'TSV'
# model: typesafe-ai/jev  vault: personal  n: 20
query	candidates	relevant	base_p@5	base_r@10	base_mrr	rerank_p@5	rerank_r@10	rerank_mrr	input_tokens	cost	market_cost
rebuild	6	2	0.0000	0.5000	0.1667	0.2000	0.5000	1.0000	1200	0.00000000	0.00004800
search ranking	2	1	0.2000	1.0000	0.5000	0.2000	1.0000	1.0000	400	0.00000000	0.00001600
hook timeout	3	2	0.4000	1.0000	1.0000	0.4000	1.0000	1.0000	600	0.00000000	0.00002400
egress consent	1	2	0.2000	0.5000	1.0000	0.2000	0.5000	1.0000	250	0.00000000	0.00001000
nightly	3	1	0.2000	1.0000	0.5000	0.2000	1.0000	0.3333	550	0.00000000	0.00002200
(all)	15	8	0.2000	0.8000	0.6333	0.2400	0.8000	0.8667	3000	0.00000000	0.00012000
TSV
  # Baseline came from search with -n, deduped; one rerank row per query.
  grep -q '^personal --format json -n 20 rebuild$' "$STUB_REC.search"
  [ "$(jq -s 'map(select(.judge == "rerank")) | length' "$LOG")" -eq 5 ]
  key_absent
}

@test "bench: --format json carries the same numbers" {
  make_bench
  run judge_cmd bench --fixture "$FIX/bench.tsv" --vault personal --format json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.model, .vault, .n, .overall.queries, .overall.input_tokens, .overall.market_cost]')" = \
    '["typesafe-ai/jev","personal",20,5,3000,0.00012]' ]
  [ "$(printf '%s' "$output" | jq -c '.overall | [.baseline.p_at_5, .baseline.r_at_10, .baseline.mrr, .reranked.p_at_5, .reranked.r_at_10, .reranked.mrr]')" = \
    '[0.2,0.8,0.6333,0.24,0.8,0.8667]' ]
  [ "$(printf '%s' "$output" | jq -c '.queries[0] | [.query, .relevant, .baseline.mrr, .reranked.mrr]')" = \
    '["rebuild",["Debug/Athlete rebuild OOM.md","Notes/Streaming patterns.md"],0.1667,1]' ]
  [ "$(printf '%s' "$output" | jq -c '.queries[2].relevant')" = '["Debug/Hook timeout.md","Notes/Hooks overview.md"]' ]
}

@test "bench: candidates carry title, frontmatter description, and first lines; paths are not sent" {
  make_bench
  run judge_cmd bench --fixture "$FIX/bench.tsv" --vault personal
  [ "$status" -eq 0 ]
  local s
  s=$(jq -r '.state' "$CURL_REC/body.1")
  [[ "$s" == "Query: rebuild"* ]]
  [[ "$s" == *$'Candidate c06\nTitle: Athlete rebuild OOM\nDescription: Root cause of the nightly athlete rebuild running out of memory.\nFirst lines:\nThe nightly rebuild held every team profile in memory at once.'* ]]
  [[ "$s" == *$'Candidate c01\nTitle: Rebuild log\nFirst lines:\n2026-08-30'* ]]
  [[ "$s" == *$'Matched lines:\n- match one\n- match two'* ]]
  [[ "$s" != *"type: debug"* ]]
  [[ "$s" != *"$STUB_VAULTS"* ]]
  [ "$(jq -c '.questions | keys' "$CURL_REC/body.1")" = '["c01","c02","c03","c04","c05","c06"]' ]
}

@test "bench: the default fixture is XDG_CONFIG_HOME/vaultmem/bench.tsv; -n reaches search" {
  make_bench
  cp "$FIX/bench.tsv" "$XDG_CONFIG_HOME/vaultmem/bench.tsv"
  run judge_cmd bench --vault personal -n 10
  [ "$status" -eq 0 ]
  grep -q '^personal --format json -n 10 nightly$' "$STUB_REC.search"
  [ "$(printf '%s\n' "$output" | tail -n 1 | cut -f 1)" = "(all)" ]
}

@test "bench: a query with no hits scores zero and sends nothing for it" {
  make_bench
  printf 'no such thing\tNotes/Grocery list.md\nsearch ranking\tArchitecture/Search ranking.md\n' >"$BATS_TEST_TMPDIR/b.tsv"
  FAKE_CURL_RESPONSE_1="$FIX/bench-response-2.json" run judge_cmd bench --fixture "$BATS_TEST_TMPDIR/b.tsv" --vault personal
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 1 ]
  [ "$(printf '%s\n' "$output" | sed -n 3p)" = "no such thing	0	1	0.0000	0.0000	0.0000	0.0000	0.0000	0.0000	0	0.00000000	0.00000000" ]
}

@test "bench: unavailable exits 3 with nothing on stdout" {
  make_bench
  write_config enabled=false
  run judge_cmd bench --fixture "$FIX/bench.tsv" --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
  write_config
  run judge_cmd bench --fixture "$FIX/bench.tsv" --vault work
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
  [ ! -e "$STUB_REC.search" ]
  # A gateway failure part-way through: rows already scored are not printed.
  jq --arg k "$KEY_VALUE" '.error.message = "bad key " + $k' "$FIX/error-401.json" >"$BATS_TEST_TMPDIR/err.json"
  FAKE_CURL_RESPONSE_2="$BATS_TEST_TMPDIR/err.json" FAKE_CURL_HTTP=401 \
    run judge_cmd bench --fixture "$FIX/bench.tsv" --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  key_absent
}

@test "bench usage errors exit 64 and never invoke curl" {
  make_bench
  run judge_cmd bench --fixture "$BATS_TEST_TMPDIR/missing.tsv" --vault personal
  [ "$status" -eq 64 ]
  run judge_cmd bench --fixture "$FIX/bench.tsv" --vault personal -n 21
  [ "$status" -eq 64 ]
  run judge_cmd bench --fixture "$FIX/bench.tsv" --vault personal -n 0
  [ "$status" -eq 64 ]
  run judge_cmd bench --fixture "$FIX/bench.tsv" --vault personal --format xml
  [ "$status" -eq 64 ]
  printf 'a query with no paths\n' >"$BATS_TEST_TMPDIR/bad.tsv"
  run judge_cmd bench --fixture "$BATS_TEST_TMPDIR/bad.tsv" --vault personal
  [ "$status" -eq 64 ]
  [ -z "$output" ]
  printf '# only a comment\n' >"$BATS_TEST_TMPDIR/empty.tsv"
  run judge_cmd bench --fixture "$BATS_TEST_TMPDIR/empty.tsv" --vault personal
  [ "$status" -eq 64 ]
  curl_not_invoked
}

# --- index-drift ------------------------------------------------------------------------

drift_in() {
  local input="$1"
  shift
  "$JUDGE_SH" "$JUDGE" index-drift "$@" <"$input" 2>"$STDERR"
}

@test "index-drift: the judge file ships the accurate template with 0.85/0.15" {
  local j="$ROOT/ext/judge/judges/index-drift.json"
  [ "$(jq -r '.questions.accurate.type' "$j")" = "boolean" ]
  [ "$(jq -c '.thresholds.accurate' "$j")" = '{"yes":0.85,"no":0.15}' ]
  jq -r '.questions.accurate.instructions' "$j" | grep -q '{row}'
}

@test "index-drift: the request body matches the golden file, one question per row" {
  FAKE_CURL_RESPONSE="$FIX/index-drift-response.json" run drift_in "$FIX/index-drift-input.json" --vault personal
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 1 ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/index-drift-body.json")
  [ "$(jq -c '.questions | keys' "$CURL_REC/body")" = '["r1","r2","r3"]' ]
  jq -r '.questions.r2.instructions' "$CURL_REC/body" | grep -q '^Index row r2 accurately describes'
  key_absent
}

@test "index-drift: answers map to {id, answers: {row: {probability}}}" {
  FAKE_CURL_RESPONSE="$FIX/index-drift-response.json" run drift_in "$FIX/index-drift-input.json" --vault personal
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.answers')" = '{"r1":{"probability":0.97},"r2":{"probability":0.04},"r3":{"probability":0.5}}' ]
  [ "$(printf '%s' "$output" | jq -c 'keys')" = '["answers","id"]' ]
  [ "$(printf '%s' "$output" | jq -r '.id')" = "$(jq -r '.id' "$LOG")" ]
  [ "$(jq -r '[.judge, .vault, .truncated] | @tsv' "$LOG")" = "index-drift	personal	false" ]
}

@test "index-drift: more than 5 rows, zero rows, or malformed stdin exits 64 and never invokes curl" {
  jq '.rows = [range(6) | {id: "r\(.)", row: "row \(.)"}]' "$FIX/index-drift-input.json" >"$BATS_TEST_TMPDIR/six.json"
  run drift_in "$BATS_TEST_TMPDIR/six.json" --vault personal
  [ "$status" -eq 64 ]
  [ -z "$output" ]
  jq '.rows = [range(5) | {id: "r\(.)", row: "row \(.)"}]' "$FIX/index-drift-input.json" >"$BATS_TEST_TMPDIR/five.json"
  jq '.rows = []' "$FIX/index-drift-input.json" >"$BATS_TEST_TMPDIR/zero.json"
  run drift_in "$BATS_TEST_TMPDIR/zero.json" --vault personal
  [ "$status" -eq 64 ]
  printf 'not json' >"$BATS_TEST_TMPDIR/bad.json"
  run drift_in "$BATS_TEST_TMPDIR/bad.json" --vault personal
  [ "$status" -eq 64 ]
  jq '.rows[1].id = "r1"' "$FIX/index-drift-input.json" >"$BATS_TEST_TMPDIR/dup.json"
  run drift_in "$BATS_TEST_TMPDIR/dup.json" --vault personal
  [ "$status" -eq 64 ]
  jq 'del(.rows[0].row)' "$FIX/index-drift-input.json" >"$BATS_TEST_TMPDIR/norow.json"
  run drift_in "$BATS_TEST_TMPDIR/norow.json" --vault personal
  [ "$status" -eq 64 ]
  run drift_in "$FIX/index-drift-input.json" --vault
  [ "$status" -eq 64 ]
  curl_not_invoked
  # Exactly 5 is allowed.
  jq -n '{model: "typesafe-ai/jev", answers: ([range(5) | {("r\(.)"): {type: "boolean", probability: 0.9}}] | add)}' >"$BATS_TEST_TMPDIR/resp5.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp5.json" run drift_in "$BATS_TEST_TMPDIR/five.json" --vault personal
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.answers | length')" -eq 5 ]
}

@test "index-drift: a non-consenting vault, or enabled=false, exits 3 and never invokes curl" {
  run drift_in "$FIX/index-drift-input.json" --vault work
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  write_config enabled=false
  run drift_in "$FIX/index-drift-input.json" --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
  [ ! -e "$LOG" ]
}

@test "index-drift: a response missing a row is a bad response, exit 3" {
  jq '.answers |= { r1: .r1, r2: .r2 }' "$FIX/index-drift-response.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" run drift_in "$FIX/index-drift-input.json" --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "index-drift: over max_state_bytes every row keeps its block" {
  jq '.rows |= map(.head = ("h" * 400 + " HEADEND"))' "$FIX/index-drift-input.json" >"$BATS_TEST_TMPDIR/big.json"
  jq '.max_state_bytes = 600' "$ROOT/ext/judge/judges/index-drift.json" >"$XDG_CONFIG_HOME/vaultmem/judges/index-drift.json"
  FAKE_CURL_RESPONSE="$FIX/index-drift-response.json" run drift_in "$BATS_TEST_TMPDIR/big.json" --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state | utf8bytelength' "$CURL_REC/body")" -le 600 ]
  local r
  for r in r1 r2 r3; do jq -r '.state' "$CURL_REC/body" | grep -q "^Row $r$"; done
  ! jq -r '.state' "$CURL_REC/body" | grep -q 'HEADEND' || false
  [ "$(jq -r '.truncated' "$LOG")" = "true" ]
}

@test "index-drift: a failed request exits 3 with empty stdout, key unseen" {
  jq --arg k "$KEY_VALUE" '.error.message = "bad key " + $k' "$FIX/error-401.json" >"$BATS_TEST_TMPDIR/err.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/err.json" FAKE_CURL_HTTP=401 \
    run drift_in "$FIX/index-drift-input.json" --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$(jq -r '.error.type' "$LOG")" = "authentication_error" ]
  key_absent
}

# --- prompt (UserPromptSubmit) -------------------------------------------------------------

PROMPT_LINE='vaultmem: this looks like a "why" question; run `vaultmem <query>` before re-deriving.'
HOOK_JSON='{"session_id":"abc123","prompt_id":"p-1","transcript_path":"/home/u/t.jsonl","cwd":"/home/u/proj","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"Why did we pick ripgrep over grep?"}'

prompt_in() { printf '%s' "$1" | "$JUDGE_SH" "$JUDGE" prompt 2>"$STDERR"; }

@test "prompt: a confident yes prints exactly the one line and exits 0" {
  write_config hook_judges=nudge,prompt
  FAKE_CURL_RESPONSE="$FIX/prompt-yes.json" run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROMPT_LINE" ]
  [ "${#lines[@]}" -eq 1 ]
  [ ! -s "$STDERR" ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/prompt-body.json")
  [ "$(jq -r '[.judge, .vault, .subject] | @tsv' "$LOG")" = "prompt	personal	prompt" ]
  key_absent
}

@test "prompt: JSON stdin sends only the prompt field; raw text is sent as is" {
  write_config hook_judges=prompt
  FAKE_CURL_RESPONSE="$FIX/prompt-yes.json" run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' "$CURL_REC/body")" = "Why did we pick ripgrep over grep?" ]
  ! grep -q 'abc123\|transcript_path\|/home/u' "$CURL_REC/body" || false
  FAKE_CURL_RESPONSE="$FIX/prompt-yes.json" run prompt_in "why is the cache keyed by vault id?"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROMPT_LINE" ]
  [ "$(jq -r '.state' "$CURL_REC/body")" = "why is the cache keyed by vault id?" ]
}

@test "prompt: a JSON object without a prompt field, or an empty prompt, sends nothing" {
  write_config hook_judges=prompt
  run prompt_in '{"session_id":"abc123","cwd":"/home/u/proj"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run prompt_in '{"prompt":"   "}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run prompt_in ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  curl_not_invoked
  [ ! -s "$STDERR" ]
}

@test "prompt: no, abstain, and every unavailable answer print nothing and exit 0" {
  write_config hook_judges=prompt
  local r
  for r in prompt-no prompt-abstain empty-answers; do
    FAKE_CURL_RESPONSE="$FIX/$r.json" run prompt_in "$HOOK_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$STDERR" ]
  done
  FAKE_CURL_RESPONSE="$FIX/error-500.json" FAKE_CURL_HTTP=500 run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$STDERR" ]
  FAKE_CURL_EXIT=28 run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$STDERR" ]
  FAKE_CURL_RESPONSE="$FIX/malformed.txt" run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$STDERR" ]
}

@test "prompt: timeout_ms reaches curl as --max-time" {
  write_config hook_judges=prompt timeout_ms=800
  FAKE_CURL_RESPONSE="$FIX/prompt-yes.json" run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  grep -A1 -x -- '--max-time' "$CURL_REC/argv" | tail -n 1 | grep -qx '0.800'
}

@test "prompt: gated off prints nothing, exits 0, and never invokes curl" {
  # prompt absent from hook_judges (default empty, and a list naming only nudge).
  run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  write_config hook_judges=nudge
  run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # enabled=false.
  write_config hook_judges=prompt enabled=false
  run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # The vault for $PWD does not consent.
  write_config hook_judges=prompt
  STUB_WHICH_ID=work run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # which only guessed (the default-vault fallback): not consent.
  STUB_WHICH_ERR="vaultmem: low-confidence guess (no match signal) → personal" run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # No config at all.
  VAULTMEM_BIN="$BATS_TEST_TMPDIR/nonexistent" run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  curl_not_invoked
  [ ! -s "$STDERR" ]
  [ ! -e "$LOG" ]
}

@test "prompt: VAULTMEM_VERBOSE=1 names the reason on stderr; stdout stays empty" {
  VAULTMEM_VERBOSE=1 run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'prompt is not in \[ext.judge\] hook_judges' "$STDERR"
  write_config hook_judges=prompt
  FAKE_CURL_RESPONSE="$FIX/prompt-no.json" VAULTMEM_VERBOSE=1 run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'no confident yes (exit 1)' "$STDERR"
}

@test "prompt: a failed request leaves the key out of stdout, stderr, argv, body, and log" {
  write_config hook_judges=prompt
  jq --arg k "$KEY_VALUE" '.error.message = "bad key " + $k' "$FIX/error-401.json" >"$BATS_TEST_TMPDIR/err.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/err.json" FAKE_CURL_HTTP=401 VAULTMEM_VERBOSE=1 run prompt_in "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'unavailable' "$STDERR"
  key_absent
}

@test "prompt: arguments are a usage error, exit 64" {
  run judge_cmd prompt --vault personal
  [ "$status" -eq 64 ]
  curl_not_invoked
}

# --- the shell floor -----------------------------------------------------------------

@test "the extension runs under /bin/bash when that is bash 3.2" {
  /bin/bash --version 2>/dev/null | head -n 1 | grep -q 'version 3\.2' || skip "/bin/bash is not 3.2 here"
  JUDGE_SH=/bin/bash
  run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 0 ]
  [ ! -s "$STDERR" ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/smoke-body-zdr.json")
}

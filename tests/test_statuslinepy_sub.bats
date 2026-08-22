#!/usr/bin/env bats

load test_helper

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STATUSLINEPY_SUB="$REPO_ROOT/statuslinepy-sub"
    RUNTIME_SITE="$(python3 -c 'import os, humanize, rich; print(os.pathsep.join({os.path.dirname(os.path.dirname(humanize.__file__)), os.path.dirname(os.path.dirname(rich.__file__))}))')"
}

@test "statuslinepy-sub renders single task JSON with single-row format" {
    json="{\"tasks\":[{\"id\":\"task-1\",\"name\":\"Generalist subagent\",\"model\":\"Claude 3.5 Sonnet\",\"effort\":\"high\",\"cwd\":\"$REPO_ROOT\"}]}"
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"id":"task-1"'
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    assert_contains "$content" 'Generalist subagent'
    assert_contains "$content" 'Claude 3.5 Sonnet'
    assert_contains "$content" 'high'
    # Single row: no newline in content
    [ "$(printf '%s' "$content" | wc -l)" -eq 0 ]
}

@test "statuslinepy-sub handles thinking flag and effort styles" {
    json='{"id":"t-99","name":"Explore","model":"Claude 3 Opus","effort":"medium","thinking":true,"cwd":""}'
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"id":"t-99"'
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    assert_contains "$content" '✦ med'
}

@test "statuslinepy-sub shows only token count and drops context limit and percentage" {
    json='{"id":"t-1m","name":"Agent","model":"Fable (1M context)","tokenCount":150000,"contextWindowSize":200000,"cwd":""}'
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    assert_contains "$content" '150k'
    refute_contains "$content" '/1M'
    refute_contains "$content" '%'
}

@test "statuslinepy-sub preserves whitespace in opaque IDs" {
    json='{"id":" spaced-id ","name":"Agent","model":"Claude","cwd":""}'
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"id":" spaced-id "'
}

@test "statuslinepy-sub measures CJK character cell widths correctly" {
    json='{"columns":20,"tasks":[{"id":"t-cjk","name":"日本語テストエージェント","model":"Claude","cwd":""}]}'
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    content="$(printf '%s' "$output" | jq -r '.content')"
    # Single row; strip ANSI and measure
    line="$(printf '%s' "$content" | strip_ansi)"
    cell_w="$(python3 -c "from rich.cells import cell_len; print(cell_len('''$line'''))")"
    [ "$cell_w" -le 20 ]
}

@test "statuslinepy-sub validates tasks independently when surrogate is present" {
    json='{"tasks":[{"id":"t-ok","name":"Good Task","model":"Claude"},{"id":"t-bad","name":"\ud800Task","model":"Claude"}]}'
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"id":"t-ok"'
    refute_contains "$output" '"id":"t-bad"'
}

@test "statuslinepy-sub sanitizes external control and OSC sequences" {
    json='{"id":"t-osc","name":"\u001b]8;;https://malicious.com\u001b\\Agent\u001b]8;;\u001b\\","model":"Claude","cwd":""}'
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    refute_contains "$output" 'https://malicious.com'
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    assert_contains "$content" 'Agent'
}

@test "statuslinepy-sub skips tasks without an id" {
    json='{"tasks":[{"name":"No ID Agent","model":"Claude"}]}'
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "statuslinepy-sub handles empty and malformed JSON stdin gracefully" {
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]

    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "{invalid json"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]

    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< '{"tasks": "not a list"}'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "statuslinepy-sub handles oversized 102-digit tokenCount without crashing" {
    huge_tokens="1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    json="{\"tasks\":[{\"id\":\"t-huge\",\"name\":\"Agent\",\"model\":\"Claude\",\"tokenCount\":$huge_tokens,\"cwd\":\"\"}]}"
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"id":"t-huge"'
}

@test "statuslinepy-sub handles deeply nested task payloads without crashing" {
    nested_json="$(python3 -c '
nested = {"id": "t-deep", "name": "Agent", "model": "Claude"}
curr = nested
for _ in range(900):
    curr["extra"] = {}
    curr = curr["extra"]
import json
print(json.dumps({"tasks": [nested]}))
')"
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$nested_json"
    [ "$status" -eq 0 ]
}

@test "statuslinepy-sub renders elapsed time from startTime" {
    # startTime ~1 minute ago (epoch ms)
    start_ms="$(python3 -c 'import time; print(int((time.time() - 75) * 1000))')"
    json="{\"id\":\"t-elapsed\",\"name\":\"Agent\",\"model\":\"Claude\",\"startTime\":$start_ms,\"cwd\":\"\"}"
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    # Should contain a mm:ss elapsed like "1:15" or "1:16"
    [[ "$content" =~ [0-9]+:[0-9]{2} ]]
}

@test "statuslinepy-sub renders task status field" {
    json='{"id":"t-status","name":"Searcher","status":"running","model":"Claude","cwd":""}'
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    assert_contains "$content" 'Searcher/running'
}

@test "statuslinepy-sub aligns model effort elapsed and token columns across tasks" {
    now_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"
    long_start_ms="$((now_ms - 809000))"
    short_start_ms="$((now_ms - 185000))"
    json="{\"tasks\":[{\"id\":\"t-opus\",\"name\":\"Inspecting backup-restic.sh/running\",\"model\":\"claude-opus-5[1m]\",\"effort\":\"medium\",\"startTime\":$long_start_ms,\"tokenCount\":92000},{\"id\":\"t-sonnet\",\"name\":\"Adding changelog entry/running\",\"model\":\"claude-sonnet-5\",\"effort\":\"medium\",\"startTime\":$short_start_ms,\"tokenCount\":106000}]}"

    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"

    [ "$status" -eq 0 ]
    opus="$(printf '%s\n' "$output" | sed -n '1p' | jq -r '.content' | strip_ansi)"
    sonnet="$(printf '%s\n' "$output" | sed -n '2p' | jq -r '.content' | strip_ansi)"
    [[ "$opus" =~ ^opus-5\[1m\]\ med\ \|\ 13:[0-9]{2}\ \|\ \ 92k\ \|\  ]]
    [[ "$sonnet" =~ ^sonnet-5\ \ \ med\ \|\ \ 3:[0-9]{2}\ \|\ 106k\ \|\  ]]

    opus_pipes="$(awk -v text="$opus" 'BEGIN { for (i = 1; i <= length(text); i++) if (substr(text, i, 1) == "|") printf "%s%d", sep, i; sep="," }')"
    sonnet_pipes="$(awk -v text="$sonnet" 'BEGIN { for (i = 1; i <= length(text); i++) if (substr(text, i, 1) == "|") printf "%s%d", sep, i; sep="," }')"
    [ "$opus_pipes" = "$sonnet_pipes" ]
}

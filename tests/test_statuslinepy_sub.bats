#!/usr/bin/env bats

load test_helper

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STATUSLINEPY_SUB="$REPO_ROOT/statuslinepy-sub"
    RUNTIME_SITE="$(python3 -c 'import os, humanize, rich; print(os.pathsep.join({os.path.dirname(os.path.dirname(humanize.__file__)), os.path.dirname(os.path.dirname(rich.__file__))}))')"
}

@test "statuslinepy-sub renders single task JSON with 2-row grid and git branch" {
    json="{\"tasks\":[{\"id\":\"task-1\",\"name\":\"Generalist subagent\",\"model\":\"Claude 3.5 Sonnet\",\"effort\":\"high\",\"cwd\":\"$REPO_ROOT\"}]}"
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"id":"task-1"'
    assert_contains "$output" 'Claude 3.5 Sonnet'
    assert_contains "$output" 'high'
    assert_contains "$output" 'Generalist subagent'
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    assert_contains "$content" 'ClaudeCodeStatusLine@'
}

@test "statuslinepy-sub handles thinking flag and effort styles" {
    json='{"id":"t-99","name":"Explore","model":"Claude 3 Opus","effort":"medium","thinking":true,"cwd":""}'
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"id":"t-99"'
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    assert_contains "$content" '✦ med'
}

@test "statuslinepy-sub overrides 200k context denominator when model label specifies 1M" {
    json='{"id":"t-1m","name":"Agent","model":"Fable (1M context)","tokenCount":150000,"contextWindowSize":200000,"cwd":""}'
    run env PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"
    [ "$status" -eq 0 ]
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    assert_contains "$content" '150k/1M 15%'
    refute_contains "$content" '75%'
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
    line1="$(printf '%s' "$content" | head -n1 | strip_ansi)"
    line2="$(printf '%s' "$content" | tail -n1 | strip_ansi)"
    cell_w1="$(python3 -c "from rich.cells import cell_len; print(cell_len('''$line1'''))")"
    cell_w2="$(python3 -c "from rich.cells import cell_len; print(cell_len('''$line2'''))")"
    [ "$cell_w1" -le 20 ]
    [ "$cell_w2" -le 20 ]
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

#!/usr/bin/env bats

load test_helper

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STATUSLINEPY_SUB="$REPO_ROOT/statuslinepy-sub"
    RUNTIME_SITE="$(python3 -c 'import os, humanize, rich; print(os.pathsep.join([os.path.dirname(os.path.dirname(humanize.__file__)), os.path.dirname(os.path.dirname(rich.__file__))]))')"
}

run_sub() {
    run env -u COLUMNS -u CLAUDE_CODE_EFFORT_LEVEL \
        PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$1"
}

rich_pipe_positions() {
    python3 -c '
import sys
from rich.cells import cell_len

column = 0
positions = []
for character in sys.argv[1]:
    column += cell_len(character)
    if character == "|":
        positions.append(str(column))
print(" ".join(positions))
' "$1"
}

@test "statuslinepy-sub renders single task JSON with single-row format" {
    json="{\"tasks\":[{\"id\":\"task-1\",\"name\":\"Generalist subagent\",\"model\":\"Claude 3.5 Sonnet\",\"effort\":\"high\",\"cwd\":\"$REPO_ROOT\"}]}"
    run_sub "$json"
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
    run_sub "$json"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"id":"t-99"'
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    assert_contains "$content" '✦ med'
}

@test "statuslinepy-sub shows only token count and drops context limit and percentage" {
    json='{"id":"t-1m","name":"Agent","model":"Fable (1M context)","tokenCount":150000,"contextWindowSize":200000,"cwd":""}'
    run_sub "$json"
    [ "$status" -eq 0 ]
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    assert_contains "$content" 'Fable 1M'
    assert_contains "$content" '150k'
    refute_contains "$content" '/1M'
    refute_contains "$content" '%'
}

@test "statuslinepy-sub preserves whitespace in opaque IDs" {
    json='{"id":" spaced-id ","name":"Agent","model":"Claude","cwd":""}'
    run_sub "$json"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"id":" spaced-id "'
}

@test "statuslinepy-sub measures CJK character cell widths correctly" {
    json='{"columns":20,"tasks":[{"id":"t-cjk","name":"日本語テストエージェント","model":"Claude","cwd":""}]}'
    run_sub "$json"
    [ "$status" -eq 0 ]
    content="$(printf '%s' "$output" | jq -r '.content')"
    # Single row; strip ANSI and measure
    line="$(printf '%s' "$content" | strip_ansi)"
    cell_w="$(python3 -c "from rich.cells import cell_len; print(cell_len('''$line'''))")"
    [ "$cell_w" -le 20 ]
}

@test "statuslinepy-sub validates tasks independently when surrogate is present" {
    json='{"tasks":[{"id":"t-ok","name":"Good Task","model":"Claude"},{"id":"t-bad","name":"\ud800Task","model":"Claude"}]}'
    run_sub "$json"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"id":"t-ok"'
    refute_contains "$output" '"id":"t-bad"'
}

@test "statuslinepy-sub sanitizes external control and OSC sequences" {
    json='{"id":"t-osc","name":"\u001b]8;;https://malicious.com\u001b\\Agent\u001b]8;;\u001b\\","model":"Claude","cwd":""}'
    run_sub "$json"
    [ "$status" -eq 0 ]
    refute_contains "$output" 'https://malicious.com'
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    assert_contains "$content" 'Agent'
}

@test "statuslinepy-sub skips tasks without an id" {
    json='{"tasks":[{"name":"No ID Agent","model":"Claude"}]}'
    run_sub "$json"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "statuslinepy-sub handles empty and malformed JSON stdin gracefully" {
    run_sub ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]

    run_sub "{invalid json"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]

    run_sub '{"tasks": "not a list"}'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "statuslinepy-sub handles oversized 102-digit tokenCount without crashing" {
    huge_tokens="1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    json="{\"tasks\":[{\"id\":\"t-huge\",\"name\":\"Agent\",\"model\":\"Claude\",\"tokenCount\":$huge_tokens,\"cwd\":\"\"}]}"
    run_sub "$json"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"id":"t-huge"'
}

@test "statuslinepy-sub handles deeply nested task payloads without crashing" {
    depth="$(python3 -c 'import sys; print(max(32, sys.getrecursionlimit() - 100))')"
    nested_json="$(python3 -c '
nested = {"id": "t-deep", "name": "Agent", "model": "Claude"}
curr = nested
for _ in range(int(__import__("sys").argv[1])):
    curr["extra"] = {}
    curr = curr["extra"]
import json
print(json.dumps({"tasks": [nested]}))
' "$depth")"
    run_sub "$nested_json"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"id":"t-deep"'
}

@test "statuslinepy-sub renders elapsed time from startTime" {
    # startTime ~1 minute ago (epoch ms)
    start_ms="$(python3 -c 'import time; print(int((time.time() - 75) * 1000))')"
    json="{\"id\":\"t-elapsed\",\"name\":\"Agent\",\"model\":\"Claude\",\"startTime\":$start_ms,\"cwd\":\"\"}"
    run_sub "$json"
    [ "$status" -eq 0 ]
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    # Should contain a mm:ss elapsed like "1:15" or "1:16"
    [[ "$content" =~ [0-9]+:[0-9]{2} ]]
}

@test "statuslinepy-sub renders task status field" {
    json='{"id":"t-status","name":"Searcher","status":"running","model":"Claude","cwd":""}'
    run_sub "$json"
    [ "$status" -eq 0 ]
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    assert_contains "$content" 'Searcher/running'
}

@test "statuslinepy-sub aligns model effort elapsed and token columns across tasks" {
    now_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"
    long_start_ms="$((now_ms - 809000))"
    short_start_ms="$((now_ms - 185000))"
    json="{\"tasks\":[{\"id\":\"t-opus\",\"name\":\"Inspecting backup-restic.sh/running\",\"model\":\"claude-opus-5[1m]\",\"effort\":\"medium\",\"startTime\":$long_start_ms,\"tokenCount\":92000},{\"id\":\"t-sonnet\",\"name\":\"Adding changelog entry/running\",\"model\":\"claude-sonnet-5\",\"effort\":\"medium\",\"startTime\":$short_start_ms,\"tokenCount\":106000}]}"

    run_sub "$json"

    [ "$status" -eq 0 ]
    opus="$(printf '%s\n' "$output" | sed -n '1p' | jq -r '.content' | strip_ansi)"
    sonnet="$(printf '%s\n' "$output" | sed -n '2p' | jq -r '.content' | strip_ansi)"
    [[ "$opus" =~ ^opus-5\[1m\]\ med\ \|\ 13:[0-9]{2}\ \|\ \ 92k\ \|\  ]]
    [[ "$sonnet" =~ ^sonnet-5\ \ \ med\ \|\ \ 3:[0-9]{2}\ \|\ 106k\ \|\  ]]

    assert_pipes_aligned "$opus" "$sonnet"
}

@test "statuslinepy-sub validates object fields and normalizes model prefixes case-insensitively" {
    json='{"tasks":[{"id":"resolved","name":"Agent","model":{"display_name":"Claude-Opus-5"},"effort":{"level":"medium"}},{"id":"malformed","name":["not","text"],"model":{"id":"claude-opus-5"},"effort":{"unexpected":true}}]}'

    run_sub "$json"

    [ "$status" -eq 0 ]
    resolved="$(printf '%s\n' "$output" | sed -n '1p' | jq -r '.content' | strip_ansi)"
    malformed="$(printf '%s\n' "$output" | sed -n '2p' | jq -r '.content' | strip_ansi)"
    [[ "$resolved" == "Opus-5 med | Agent" ]]
    [[ "$malformed" == "Claude   - | agent" ]]
    refute_contains "$output" "{'"
}

@test "statuslinepy-sub never guesses missing task effort from the main session" {
    json='{"id":"missing-effort","name":"Agent","model":"claude-sonnet-5"}'

    run env -u COLUMNS CLAUDE_CODE_EFFORT_LEVEL=max \
        PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"

    [ "$status" -eq 0 ]
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    [[ "$content" == "sonnet-5 - | Agent" ]]
}

@test "statuslinepy-sub caps hostile shared widths without hiding sibling tasks" {
    wide_model="$(printf 'x%.0s' {1..100})"
    json="$(jq -nc --arg model "$wide_model" '{columns:60,tasks:[{id:"wide",name:"日本語の長い作業名",model:$model,effort:"medium"},{id:"normal",name:"Normal task",model:"claude-opus-5",effort:"medium"}]}')"

    run_sub "$json"

    [ "$status" -eq 0 ]
    wide="$(printf '%s\n' "$output" | sed -n '1p' | jq -r '.content' | strip_ansi)"
    normal="$(printf '%s\n' "$output" | sed -n '2p' | jq -r '.content' | strip_ansi)"
    assert_contains "$wide" '日本語'
    assert_contains "$normal" 'Normal task'
    [ "$(python3 -c 'import sys; from rich.cells import cell_len; print(cell_len(sys.argv[1]))' "$wide")" -le 60 ]
    [ "$(python3 -c 'import sys; from rich.cells import cell_len; print(cell_len(sys.argv[1]))' "$normal")" -le 60 ]
    [ "$(rich_pipe_positions "$wide")" = "$(rich_pipe_positions "$normal")" ]
}

@test "statuslinepy-sub bounds huge numeric strings and rejects second-based start times" {
    now_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"
    json="{\"tasks\":[{\"id\":\"bounded\",\"name\":\"Bounded\",\"model\":\"Claude\",\"startTime\":1787000000,\"tokenCount\":\"1E+9999999999\"},{\"id\":\"timed\",\"name\":\"Timed\",\"model\":\"Claude\",\"startTime\":$((now_ms - 75000)),\"tokenCount\":92000}]}"

    run_sub "$json"

    [ "$status" -eq 0 ]
    bounded="$(printf '%s\n' "$output" | sed -n '1p' | jq -r '.content' | strip_ansi)"
    timed="$(printf '%s\n' "$output" | sed -n '2p' | jq -r '.content' | strip_ansi)"
    assert_contains "$bounded" '999M+'
    refute_contains "$bounded" 'h'
    assert_contains "$timed" '1:'
    [ "$(rich_pipe_positions "$bounded")" = "$(rich_pipe_positions "$timed")" ]
}

@test "statuslinepy-sub keeps optional columns aligned when a sibling omits them" {
    now_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"
    json="{\"tasks\":[{\"id\":\"full\",\"name\":\"Full\",\"model\":\"Claude-Opus-5\",\"effort\":\"high\",\"startTime\":$((now_ms - 75000)),\"tokenCount\":92000},{\"id\":\"sparse\",\"name\":\"Sparse\",\"model\":\"claude-sonnet-5\"}]}"

    run_sub "$json"

    [ "$status" -eq 0 ]
    full="$(printf '%s\n' "$output" | sed -n '1p' | jq -r '.content' | strip_ansi)"
    sparse="$(printf '%s\n' "$output" | sed -n '2p' | jq -r '.content' | strip_ansi)"
    [ "$(rich_pipe_positions "$full")" = "$(rich_pipe_positions "$sparse")" ]
}

@test "statuslinepy-sub uses one truncation tier for short and long task names" {
    now_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"
    json="{\"columns\":45,\"tasks\":[{\"id\":\"short\",\"name\":\"Short\",\"model\":\"claude-opus-5[1m]\",\"effort\":\"medium\",\"startTime\":$((now_ms - 75000)),\"tokenCount\":92000},{\"id\":\"long\",\"name\":\"A much longer task name that must truncate\",\"model\":\"claude-sonnet-5\",\"effort\":\"medium\",\"startTime\":$((now_ms - 185000)),\"tokenCount\":106000}]}"

    run_sub "$json"

    [ "$status" -eq 0 ]
    short="$(printf '%s\n' "$output" | sed -n '1p' | jq -r '.content' | strip_ansi)"
    long="$(printf '%s\n' "$output" | sed -n '2p' | jq -r '.content' | strip_ansi)"
    [ "$(rich_pipe_positions "$short")" = "$(rich_pipe_positions "$long")" ]
    [ "$(python3 -c 'import sys; from rich.cells import cell_len; print(cell_len(sys.argv[1]))' "$short")" -le 45 ]
    [ "$(python3 -c 'import sys; from rich.cells import cell_len; print(cell_len(sys.argv[1]))' "$long")" -le 45 ]
    assert_contains "$long" '…'
}

@test "statuslinepy-sub honors COLUMNS for top-level task arrays" {
    json='[{"id":"array","name":"A very long array task name","model":"Claude"}]'

    run env -u CLAUDE_CODE_EFFORT_LEVEL COLUMNS=20 \
        PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"

    [ "$status" -eq 0 ]
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    [ "$(python3 -c 'import sys; from rich.cells import cell_len; print(cell_len(sys.argv[1]))' "$content")" -le 20 ]
}

@test "statuslinepy-sub renders name token and elapsed fallbacks" {
    start_ms="$(python3 -c 'import time; print(int((time.time() - 3660) * 1000))')"
    json="{\"tasks\":[{\"id\":\"label\",\"label\":\"Label fallback\",\"model\":\"Claude\",\"contextWindowSize\":200000},{\"id\":\"type\",\"type\":\"Type fallback\",\"model\":\"Claude\",\"startTime\":$start_ms}]}"

    run_sub "$json"

    [ "$status" -eq 0 ]
    label="$(printf '%s\n' "$output" | sed -n '1p' | jq -r '.content' | strip_ansi)"
    type="$(printf '%s\n' "$output" | sed -n '2p' | jq -r '.content' | strip_ansi)"
    assert_contains "$label" '0 | Label fallback'
    assert_contains "$type" '1:01h'
    assert_contains "$type" 'Type fallback'
}

@test "statuslinepy-sub bounds model normalization work and strips directional controls" {
    digits="$(printf '9%.0s' {1..100000})"
    json="$(jq -nc --arg model "($digits" '{tasks:[{id:"hostile",name:"report\u202egnp.exe\u200e\u200f\u061c",model:$model},{id:"sibling",name:"Sibling",model:"Claude"}]}')"

    run_sub "$json"

    [ "$status" -eq 0 ]
    assert_contains "$output" '"id":"hostile"'
    assert_contains "$output" '"id":"sibling"'
    hostile="$(printf '%s\n' "$output" | sed -n '1p' | jq -r '.content' | strip_ansi)"
    assert_contains "$hostile" 'reportgnp.exe'
    refute_contains "$hostile" $'\u202e'
    refute_contains "$hostile" $'\u200e'
    refute_contains "$hostile" $'\u200f'
    refute_contains "$hostile" $'\u061c'
}

@test "statuslinepy-sub falls back to COLUMNS when object columns is invalid" {
    json='{"id":"invalid-columns","name":"A very long task name that must truncate","model":"Claude","columns":"auto"}'

    run env -u CLAUDE_CODE_EFFORT_LEVEL COLUMNS=20 \
        PYTHONPATH="$RUNTIME_SITE" "$STATUSLINEPY_SUB" <<< "$json"

    [ "$status" -eq 0 ]
    content="$(printf '%s' "$output" | jq -r '.content' | strip_ansi)"
    [ "$(python3 -c 'import sys; from rich.cells import cell_len; print(cell_len(sys.argv[1]))' "$content")" -le 20 ]
}

@test "statuslinepy-sub degrades parser recursion limits without a traceback" {
    depth="$(python3 -c 'import sys; print(sys.getrecursionlimit() * 5)')"
    nested="$(python3 -c 'import sys; depth = int(sys.argv[1]); print("[" * depth + "0" + "]" * depth)' "$depth")"
    json="{\"tasks\":[{\"id\":\"valid\",\"name\":\"Valid\",\"model\":\"Claude\"},{\"id\":\"deep\",\"name\":\"Deep\",\"model\":\"Claude\",\"extra\":$nested}]}"

    run_sub "$json"

    [ "$status" -eq 0 ]
    refute_contains "$output" 'Traceback'
    refute_contains "$output" 'RecursionError'
    [ "$output" = "" ] || assert_contains "$output" '"id":"valid"'
}

@test "statuslinepy-sub exits cleanly when a downstream pipe closes" {
    for task_count in 1 10000; do
        run bash -o pipefail -c '
            python3 -c '\''import json, sys; print(json.dumps({"tasks": [{"id": str(i), "name": "Task", "model": "Claude"} for i in range(int(sys.argv[1]))]}))'\'' "$3" |
                env -u COLUMNS -u CLAUDE_CODE_EFFORT_LEVEL PYTHONPATH="$1" "$2" |
                head -n 0 >/dev/null
        ' _ "$RUNTIME_SITE" "$STATUSLINEPY_SUB" "$task_count"

        [ "$status" -eq 0 ]
        refute_contains "$output" 'BrokenPipeError'
    done
}

@test "statuslinepy-sub exercises dropped-column tiers and the hard width limit" {
    now_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"

    for columns in 30 20; do
        json="{\"columns\":$columns,\"tasks\":[{\"id\":\"short\",\"name\":\"Short\",\"model\":\"claude-opus-5[1m]\",\"effort\":\"medium\",\"startTime\":$((now_ms - 75000)),\"tokenCount\":92000},{\"id\":\"long\",\"name\":\"A much longer task name\",\"model\":\"claude-sonnet-5\",\"effort\":\"medium\",\"startTime\":$((now_ms - 185000)),\"tokenCount\":106000}]}"

        run_sub "$json"

        [ "$status" -eq 0 ]
        short="$(printf '%s\n' "$output" | sed -n '1p' | jq -r '.content' | strip_ansi)"
        long="$(printf '%s\n' "$output" | sed -n '2p' | jq -r '.content' | strip_ansi)"
        [ "$(rich_pipe_positions "$short")" = "$(rich_pipe_positions "$long")" ]
        [ "$(python3 -c 'import sys; from rich.cells import cell_len; print(cell_len(sys.argv[1]))' "$short")" -le "$columns" ]
        [ "$(python3 -c 'import sys; from rich.cells import cell_len; print(cell_len(sys.argv[1]))' "$long")" -le "$columns" ]
    done
}

@test "statuslinepy-sub covers alternate fields effort styles and malformed siblings" {
    json='{"tasks":["invalid",null,{"id":"alternate","name":"Alternate","model":"Claude","tokens":1500000,"context_window_size":2000000,"thinking":{"enabled":true},"effort":"low"},{"id":"carry","name":"Carry","model":"Claude","tokenCount":999500,"effort":"xhigh"},{"id":"maximum","name":"Maximum","model":"Claude","effort":"max"},{"id":"unknown","name":"Unknown","model":"Claude","effort":"custom"}]}'

    run_sub "$json"

    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 4 ]
    alternate="$(printf '%s\n' "$output" | sed -n '1p' | jq -r '.content' | strip_ansi)"
    carry="$(printf '%s\n' "$output" | sed -n '2p' | jq -r '.content' | strip_ansi)"
    maximum="$(printf '%s\n' "$output" | sed -n '3p' | jq -r '.content' | strip_ansi)"
    unknown="$(printf '%s\n' "$output" | sed -n '4p' | jq -r '.content' | strip_ansi)"
    assert_contains "$alternate" '✦ low'
    assert_contains "$alternate" '1.5M'
    assert_contains "$carry" 'xhigh'
    assert_contains "$carry" '1M'
    assert_contains "$maximum" 'max'
    assert_contains "$unknown" 'custom'
}

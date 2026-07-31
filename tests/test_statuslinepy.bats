#!/usr/bin/env bats

load test_helper

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STATUSLINEPY="$REPO_ROOT/statuslinepy"
    PAIR_ROOT="$BATS_TEST_TMPDIR/pair"
    RUNTIME_SITE="$(python3 -c 'import os, humanize, rich; print(os.pathsep.join({os.path.dirname(os.path.dirname(humanize.__file__)), os.path.dirname(os.path.dirname(rich.__file__))}))')"
    mkdir -p "$PAIR_ROOT"
}

make_sandbox() {
    local root="$1"
    mkdir -p "$root/home" "$root/config" "$root/run" "$root/bin"
    if [ "${RUN_BAD_CLAUDE:-}" = "true" ]; then
        printf '#!/bin/sh\nprintf "\\377"\n' >"$root/bin/claude"
    else
        printf '#!/bin/sh\nprintf "9.8.7 test\\n"\n' >"$root/bin/claude"
    fi
    printf '#!/bin/sh\nexit 1\n' >"$root/bin/security"
    printf '#!/bin/sh\nexit 1\n' >"$root/bin/secret-tool"
    cat >"$root/bin/curl" <<'EOF'
#!/bin/sh
cat >"$CURL_STDIN"
printf '%s\n' "$*" >>"$CURL_LOG"
[ -f "$CURL_RESPONSE" ] && cat "$CURL_RESPONSE"
EOF
    chmod +x "$root/bin/"*
}

run_impl() {
    local impl="$1" json="$2" root="$3" output="$4" config_value
    make_sandbox "$root"
    local -a command=("$impl")
    local -a effort_env=(-u CLAUDE_CODE_EFFORT_LEVEL)
    [ "$impl" = "$STATUSLINE_SH" ] && command=(bash "$impl")
    [ -n "${RUN_EFFORT:-}" ] && effort_env=("CLAUDE_CODE_EFFORT_LEVEL=$RUN_EFFORT")
    config_value="$root/config${RUN_CONFIG_SUFFIX:-}"

    printf '%s' "$json" | env \
        "${effort_env[@]}" \
        HOME="$root/home" \
        CLAUDE_CONFIG_DIR="$config_value" \
        XDG_RUNTIME_DIR="$root/run" \
        STATUSLINE_CHECK_UPDATES="${RUN_UPDATES:-false}" \
        CLAUDE_CODE_OAUTH_TOKEN="${RUN_TOKEN:-}" \
        CURL_LOG="$root/curl.log" \
        CURL_STDIN="$root/curl.stdin" \
        CURL_RESPONSE="$root/curl.response" \
        PYTHONPATH="$RUNTIME_SITE" \
        TZ="${RUN_TZ:-}" \
        PATH="$root/bin:$PATH" \
        "${command[@]}" >"$output"
}

compare_pair() {
    local json="$1" mode="${2:-raw}"
    run_impl "$STATUSLINE_SH" "$json" "$PAIR_ROOT/bash" "$PAIR_ROOT/bash.out"
    BASH_STATUS=$?
    run_impl "$STATUSLINEPY" "$json" "$PAIR_ROOT/python" "$PAIR_ROOT/python.out"
    PYTHON_STATUS=$?
    if [ "$mode" = "text" ]; then
        strip_ansi <"$PAIR_ROOT/bash.out" >"$PAIR_ROOT/bash.txt"
        strip_ansi <"$PAIR_ROOT/python.out" >"$PAIR_ROOT/python.txt"
        cmp "$PAIR_ROOT/bash.txt" "$PAIR_ROOT/python.txt"
    else
        cmp "$PAIR_ROOT/bash.out" "$PAIR_ROOT/python.out"
    fi
}

cache_path() {
    local root="$1" hash
    hash="$(printf '%s' "$root/config" | sha256sum | cut -c1-8)"
    printf '%s/run/claude/statusline-usage-cache-%s.json' "$root" "$hash"
}

seed_usage_cache() {
    local root="$1" json="$2" cache hash
    make_sandbox "$root"
    cache="$(cache_path "$root")"
    hash="$(printf '%s' "$root/config" | sha256sum | cut -c1-8)"
    mkdir -p "${cache%/*}"
    printf '%s' "$json" >"$cache"
    touch "${cache%/*}/statusline-usage-fetched-$hash"
}

@test "Python empty input matches Bash byte-for-byte" {
    compare_pair ""

    [ "$BASH_STATUS" -eq 0 ]
    [ "$PYTHON_STATUS" -eq 0 ]
    [ "$(od -An -tx1 "$PAIR_ROOT/python.out" | tr -d ' \n')" = "436c61756465" ]
}

@test "deterministic full grid matches raw ANSI output" {
    usage='{"limits":[{"scope":{"model":{"display_name":"Fable"}},"percent":49}],"extra_usage":null}'
    seed_usage_cache "$PAIR_ROOT/bash" "$usage"
    seed_usage_cache "$PAIR_ROOT/python" "$usage"
    json='{"model":{"display_name":"Opus 4.8 (1M context)"},"version":"2.3.4","effort":{"level":"high"},"thinking":{"enabled":true},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1499,"cache_creation_input_tokens":1001,"cache_read_input_tokens":0},"used_percentage":12.9},"rate_limits":{"five_hour":{"used_percentage":55.8},"seven_day":{"used_percentage":91.2}}}'

    compare_pair "$json"

    [ "$BASH_STATUS" -eq 0 ]
    [ "$PYTHON_STATUS" -eq 0 ]
    [ "$(wc -l <"$PAIR_ROOT/python.out")" -eq 1 ]
}

@test "minimal JSON preserves placeholders and alignment" {
    compare_pair '{}' text
    plain="$(strip_ansi <"$PAIR_ROOT/python.out")"

    [ "$BASH_STATUS" -eq 0 ]
    [ "$PYTHON_STATUS" -eq 0 ]
    assert_contains "$plain" "Claude"
    assert_contains "$plain" "Fable"
    assert_pipes_aligned "$(line_n "$plain" 1)" "$(line_n "$plain" 2)"
}

@test "Humanize token normalization matches every Bash half-up boundary" {
    for tokens in 999 1000 1499 1500 2500 999499 999500 1250000 2000000; do
        compare_pair "{\"context_window\":{\"context_window_size\":2000000,\"current_usage\":{\"input_tokens\":$tokens}}}" text
        [ "$PYTHON_STATUS" -eq 0 ]
    done
}

@test "stdin effort thinking model version and workspace cwd take precedence" {
    mkdir -p "$PAIR_ROOT/chosen" "$PAIR_ROOT/ignored"
    make_sandbox "$PAIR_ROOT/bash"
    make_sandbox "$PAIR_ROOT/python"
    printf '{"effortLevel":"low"}' >"$PAIR_ROOT/bash/config/settings.json"
    printf '{"effortLevel":"low"}' >"$PAIR_ROOT/python/config/settings.json"
    json="{\"model\":{\"display_name\":\" Sonnet (200k context) \"},\"version\":\"7.6.5\",\"effort\":{\"level\":\"XHIGH\"},\"thinking\":{\"enabled\":true},\"workspace\":{\"current_dir\":\"$PAIR_ROOT/chosen\"},\"cwd\":\"$PAIR_ROOT/ignored\"}"

    compare_pair "$json" text
    plain="$(strip_ansi <"$PAIR_ROOT/python.out")"

    assert_contains "$plain" "Sonnet 200k"
    assert_contains "$plain" "✦ xhigh"
    assert_contains "$plain" "v7.6.5"
    assert_contains "$plain" "chosen"
    refute_contains "$plain" "ignored"

    RUN_EFFORT=MAX
    compare_pair '{"version":"1.0.0"}' text
    assert_contains "$(strip_ansi <"$PAIR_ROOT/python.out")" 'max'
    unset RUN_EFFORT

    compare_pair '{"version":"1.0.0"}' text
    assert_contains "$(strip_ansi <"$PAIR_ROOT/python.out")" 'low'
    rm "$PAIR_ROOT/bash/config/settings.json" "$PAIR_ROOT/python/config/settings.json"
    compare_pair '{"version":"1.0.0"}' text
    assert_contains "$(strip_ansi <"$PAIR_ROOT/python.out")" 'med'
}

@test "CLI version cache honors the one-hour TTL" {
    for side in bash python; do
        root="$PAIR_ROOT/$side"
        make_sandbox "$root"
        mkdir -p "$root/run/claude"
        printf '4.5.6\n' >"$root/run/claude/statusline-cli-version"
    done

    compare_pair '{}' text
    assert_contains "$(strip_ansi <"$PAIR_ROOT/python.out")" 'v4.5.6'

    touch -d '2 hours ago' "$PAIR_ROOT/bash/run/claude/statusline-cli-version"
    touch -d '2 hours ago' "$PAIR_ROOT/python/run/claude/statusline-cli-version"
    compare_pair '{}' text
    assert_contains "$(strip_ansi <"$PAIR_ROOT/python.out")" 'v9.8.7'
}

@test "Fable presence and extra dollars match cached API data" {
    usage='{"five_hour":{"utilization":25},"seven_day":{"utilization":75},"limits":[{"scope":{"model":{"display_name":"Fable"}},"percent":49.9}],"extra_usage":{"is_enabled":true,"used_credits":350,"monthly_limit":2500,"utilization":14}}'
    seed_usage_cache "$PAIR_ROOT/bash" "$usage"
    seed_usage_cache "$PAIR_ROOT/python" "$usage"

    compare_pair '{"version":"2.3.4"}'
    plain="$(strip_ansi <"$PAIR_ROOT/python.out")"

    assert_contains "$plain" 'Fable 49%'
    assert_contains "$plain" '$3.50/$25'
}

@test "all-zero builtin without resets falls back to cache" {
    usage='{"five_hour":{"utilization":42},"seven_day":{"utilization":67},"limits":null,"extra_usage":null}'
    seed_usage_cache "$PAIR_ROOT/bash" "$usage"
    seed_usage_cache "$PAIR_ROOT/python" "$usage"

    compare_pair '{"rate_limits":{"five_hour":{"used_percentage":0},"seven_day":{"used_percentage":0}}}' text
    plain="$(strip_ansi <"$PAIR_ROOT/python.out")"

    assert_contains "$plain" '5h 42%'
    assert_contains "$plain" '7d 67%'
}

@test "clean dirty Git and worktree rendering match" {
    git_dir="$PAIR_ROOT/repository"
    mkdir -p "$git_dir"
    git -C "$git_dir" init -q -b trunk
    git -C "$git_dir" config user.email 168346341+chrisdpurcell@users.noreply.github.com
    git -C "$git_dir" config user.name Test
    printf 'one\ntwo\n' >"$git_dir/file"
    git -C "$git_dir" add file
    git -C "$git_dir" -c core.hooksPath=/dev/null commit -q -m seed
    json="{\"cwd\":\"$git_dir\",\"worktree\":{\"name\":\"feat-x\"}}"
    compare_pair "$json" text
    plain="$(strip_ansi <"$PAIR_ROOT/python.out")"
    assert_contains "$plain" 'repository@trunk:feat-x'
    refute_contains "$plain" '+0'

    printf 'three\n' >>"$git_dir/file"
    compare_pair "$json" text
    plain="$(strip_ansi <"$PAIR_ROOT/python.out")"
    assert_contains "$plain" '+1'
    assert_contains "$plain" '-0'
}

@test "fetch stamp throttles curl and builtin rewrite retains limits and extra usage" {
    usage='{"five_hour":{"utilization":1},"seven_day":{"utilization":2},"limits":[{"scope":{"model":{"display_name":"Fable"}},"percent":33}],"extra_usage":{"is_enabled":true,"used_credits":100,"monthly_limit":500,"utilization":20}}'
    for side in bash python; do
        root="$PAIR_ROOT/$side"
        seed_usage_cache "$root" "$usage"
        rm -f "$root/run/claude/statusline-usage-fetched-"*
        printf '{"five_hour":null}' >"$root/curl.response"
    done
    RUN_TOKEN=token
    json='{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1893456000},"seven_day":{"used_percentage":20,"resets_at":1893542400}}}'

    compare_pair "$json"
    compare_pair "$json"

    [ "$(wc -l <"$PAIR_ROOT/bash/curl.log")" -eq 1 ]
    [ "$(wc -l <"$PAIR_ROOT/python/curl.log")" -eq 1 ]
    refute_contains "$(cat "$PAIR_ROOT/python/curl.log")" 'token'
    assert_contains "$(cat "$PAIR_ROOT/python/curl.stdin")" 'Authorization: Bearer token'
    jq -e '.limits[0].percent == 33 and .extra_usage.used_credits == 100' "$(cache_path "$PAIR_ROOT/python")"
}

@test "literal backslashes survive and poisoned update tags are sanitized" {
    for side in bash python; do
        root="$PAIR_ROOT/$side"
        make_sandbox "$root"
        mkdir -p "$root/run/claude"
        printf '{"tag_name":"v9.9.9\\u001b[31mPWN"}' >"$root/run/claude/statusline-version-cache.json"
    done
    RUN_UPDATES=true

    compare_pair '{"model":{"display_name":"A\\nB"},"version":"1.0.0"}' text
    plain="$(strip_ansi <"$PAIR_ROOT/python.out")"

    assert_contains "$plain" 'A\nB'
    refute_contains "$plain" 'PWN'
    assert_contains "$plain" 'Update available:'
}

@test "non-UTF-8 usage cache degrades without changing Bash output" {
    for side in bash python; do
        root="$PAIR_ROOT/$side"
        make_sandbox "$root"
        cache="$(cache_path "$root")"
        hash="$(printf '%s' "$root/config" | sha256sum | cut -c1-8)"
        mkdir -p "${cache%/*}"
        printf '\377' >"$cache"
        touch "${cache%/*}/statusline-usage-fetched-$hash"
    done

    compare_pair '{}' raw
    [ "$BASH_STATUS" -eq 0 ]
    [ "$PYTHON_STATUS" -eq 0 ]
}

@test "non-UTF-8 CLI cache matches Bash raw bytes" {
    for side in bash python; do
        root="$PAIR_ROOT/$side"
        make_sandbox "$root"
        mkdir -p "$root/run/claude"
        printf '\377' >"$root/run/claude/statusline-cli-version"
    done
    compare_pair '{}' raw
    [ "$BASH_STATUS" -eq 0 ]
    [ "$PYTHON_STATUS" -eq 0 ]
}

@test "non-UTF-8 CLI subprocess output matches Bash raw bytes" {
    RUN_BAD_CLAUDE=true
    compare_pair '{}' raw
    [ "$BASH_STATUS" -eq 0 ]
    [ "$PYTHON_STATUS" -eq 0 ]
}

@test "config directory hash preserves an explicit trailing slash" {
    RUN_CONFIG_SUFFIX=/
    usage='{"five_hour":{"utilization":42},"seven_day":{"utilization":67}}'
    for side in bash python; do
        root="$PAIR_ROOT/$side"
        make_sandbox "$root"
        hash="$(printf '%s' "$root/config/" | sha256sum | cut -c1-8)"
        mkdir -p "$root/run/claude"
        printf '%s' "$usage" >"$root/run/claude/statusline-usage-cache-$hash.json"
        touch "$root/run/claude/statusline-usage-fetched-$hash"
    done

    compare_pair '{}' text
    assert_contains "$(strip_ansi <"$PAIR_ROOT/python.out")" '5h 42%'
}

@test "root cwd retains Bash empty-basename trailing cells" {
    compare_pair '{"cwd":"/","version":"1.0.0"}' raw
}

@test "unborn Git branch retains HEAD stdout despite nonzero status" {
    repo="$PAIR_ROOT/unborn"
    mkdir -p "$repo"
    git -C "$repo" init -q -b trunk

    compare_pair "{\"cwd\":\"$repo\",\"version\":\"1.0.0\"}" raw
    assert_contains "$(strip_ansi <"$PAIR_ROOT/python.out")" '@HEAD'
}

@test "billion-token counts remain in the Bash M unit contract" {
    compare_pair '{"context_window":{"context_window_size":1000000000,"current_usage":{"input_tokens":1000000000}}}' text
    assert_contains "$(strip_ansi <"$PAIR_ROOT/python.out")" '1000M/1000M'
}

@test "naive cached ISO timestamps are interpreted as local time" {
    RUN_TZ=America/New_York
    usage='{"five_hour":{"utilization":25,"resets_at":"2026-01-15T12:00:00"},"seven_day":{"utilization":50,"resets_at":"2026-01-16T12:00:00"}}'
    seed_usage_cache "$PAIR_ROOT/bash" "$usage"
    seed_usage_cache "$PAIR_ROOT/python" "$usage"

    compare_pair '{"version":"1.0.0"}' text
    assert_contains "$(strip_ansi <"$PAIR_ROOT/python.out")" '@12:00'
}

@test "malformed JSON follows jq empty extraction behavior" {
    compare_pair '{not-json' raw
}

@test "non-object JSON follows jq extraction behavior while null uses defaults" {
    compare_pair '[1,2,3]' raw
    compare_pair '"value"' raw
    compare_pair 'null' raw
}

@test "empty runtime environment values use Bash fallback paths" {
    run env -u CLAUDE_CONFIG_DIR HOME= XDG_RUNTIME_DIR= PYTHONPATH="$RUNTIME_SITE" \
        python3 -c 'import runpy,sys; m=runpy.run_path(sys.argv[1]); print("|".join(map(str,m["resolve_runtime_paths"]())))' \
        "$STATUSLINEPY"

    [ "$status" -eq 0 ]
    [ "$output" = '/.claude|/tmp/claude' ]
}

@test "usage response accepts numeric-zero five_hour like jq -e" {
    RUN_TOKEN=token
    for side in bash python; do
        root="$PAIR_ROOT/$side"
        make_sandbox "$root"
        printf '{"five_hour":0}' >"$root/curl.response"
    done

    compare_pair '{}' text
    [ "$(jq -r '.five_hour' "$(cache_path "$PAIR_ROOT/bash")")" = 0 ]
    [ "$(jq -r '.five_hour' "$(cache_path "$PAIR_ROOT/python")")" = 0 ]
}

@test "update response rejects null tag but accepts numeric zero" {
    RUN_UPDATES=true
    for side in bash python; do
        root="$PAIR_ROOT/$side"
        make_sandbox "$root"
        for rejected in null false; do
            printf '{"tag_name":%s}' "$rejected" >"$root/curl.response"
            run_impl "$([ "$side" = bash ] && printf '%s' "$STATUSLINE_SH" || printf '%s' "$STATUSLINEPY")" \
                '{}' "$root" "$root/rejected.out"
            [ ! -e "$root/run/claude/statusline-version-cache.json" ]
        done

        printf '{"tag_name":0}' >"$root/curl.response"
        run_impl "$([ "$side" = bash ] && printf '%s' "$STATUSLINE_SH" || printf '%s' "$STATUSLINEPY")" \
            '{}' "$root" "$root/zero.out"
        [ "$(jq -r '.tag_name' "$root/run/claude/statusline-version-cache.json")" = 0 ]

        find "$root/run/claude" -maxdepth 1 -name statusline-version-cache.json -delete
        printf '{"tag_name":""}' >"$root/curl.response"
        run_impl "$([ "$side" = bash ] && printf '%s' "$STATUSLINE_SH" || printf '%s' "$STATUSLINEPY")" \
            '{}' "$root" "$root/empty.out"
        [ "$(jq -r '.tag_name' "$root/run/claude/statusline-version-cache.json")" = '' ]
    done
}

@test "JSON-derived control bytes match Bash raw output" {
    json='{"model":{"display_name":"A\u0007B\rC\bD\tE\u001b[31mF\u001b]0;X\u0007G"},"version":"1.0.0"}'
    compare_pair "$json" raw
}

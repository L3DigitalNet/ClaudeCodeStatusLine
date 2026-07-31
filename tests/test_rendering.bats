#!/usr/bin/env bats
# Concern: rendering — how statusline.sh humanises tokens and assembles the
# single output line (block order, model-name collapse, effort, cwd/git,
# token count + percentage). UNIT cases lift format_tokens via load_fn; the
# rest are hermetic whole-line render() runs asserted on ANSI-stripped output.
load test_helper

# ---------------------------------------------------------------------------
# format_tokens — UNIT (statusline.sh:29-38)
# ---------------------------------------------------------------------------

@test "format_tokens: sub-1000 prints raw integer" {
    load_fn format_tokens
    [ "$(format_tokens 999)" = "999" ]
}

@test "format_tokens: zero" {
    load_fn format_tokens
    [ "$(format_tokens 0)" = "0" ]
}

@test "format_tokens: 1000 boundary -> k" {
    load_fn format_tokens
    [ "$(format_tokens 1000)" = "1k" ]
}

@test "format_tokens: 50000 -> 50k" {
    load_fn format_tokens
    [ "$(format_tokens 50000)" = "50k" ]
}

@test "format_tokens: rounds to nearest k" {
    # 134.938 -> %.0fk -> 135k (rounds up; awk sprintf half-to-even is not in
    # play here since .938 is unambiguously nearer 135).
    load_fn format_tokens
    [ "$(format_tokens 134938)" = "135k" ]
}

@test "format_tokens: 999999 promotes to 1M (rollover)" {
    # Rounds up out of the k range -> promoted to 1M, not an out-of-range '1000k'.
    load_fn format_tokens
    [ "$(format_tokens 999999)" = "1M" ]
}

@test "format_tokens: 1000000 -> 1M (integer collapses)" {
    load_fn format_tokens
    [ "$(format_tokens 1000000)" = "1M" ]
}

@test "format_tokens: 1500000 -> 1.5M" {
    load_fn format_tokens
    [ "$(format_tokens 1500000)" = "1.5M" ]
}

# ---------------------------------------------------------------------------
# Model name — INTEGRATION (statusline.sh:75-76, 138)
# ---------------------------------------------------------------------------

@test "render: model '(1M context)' suffix collapses to '1M'" {
    # Row 1 order: model+effort (fused) | tokens | 5h | cwd. The fused cell is 15
    # visible chars here (wider than row 2's stub version), so no padding follows
    # it and the '| tokens' adjacency is exact.
    out="$(render '{"model":{"display_name":"Opus 4.8 (1M context)"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":5000,"cache_read_input_tokens":5000}},"cwd":"/nope/deep/myproject"}')"
    assert_contains "$(line_n "$out" 1)" "Opus 4.8 1M med | 50k/200k 25%"
}

@test "render: '(200K context)' preserves original K casing" {
    # Regex requires at least one digit plus exactly one k/K/m/M suffix; it keeps whatever
    # case the input used and strips only the ' context)' wrapper.
    out="$(render '{"model":{"display_name":"Sonnet 4.5 (200K context)"}}')"
    assert_contains "$out" "Sonnet 4.5 200K med |"
}

@test "render: '(200000 context)' with no unit suffix is left verbatim" {
    # The stricter regex (mirrors PowerShell) demands a k/K/m/M suffix, so a raw digit
    # count with no unit does NOT collapse — the '(200000 context)' text stays intact.
    out="$(render '{"model":{"display_name":"Opus (200000 context)"}}')"
    assert_contains "$out" "Opus (200000 context) med |"
}

@test "render: display_name with no context suffix is unchanged" {
    out="$(render '{"model":{"display_name":"Haiku 4"}}')"
    assert_contains "$out" "Haiku 4 med |"
}

@test "render: missing display_name falls back to 'Claude'" {
    # stdin is non-empty '{}', so this exercises the render path, NOT the
    # top-level empty-stdin 'Claude' early-exit.
    out="$(render '{}')"
    # Col 1 pads to row 2's stub version width and effort right-aligns to the edge, so
    # assert the 'Claude' prefix leads and 'med' sits flush at the ' | ', plus tokens.
    case "$(line_n "$out" 1)" in
        "Claude "*"med |"*) ;;
        *) echo "line1: $(line_n "$out" 1)" >&2; return 1 ;;
    esac
    assert_contains "$(line_n "$out" 1)" "| 0/200k 0%"
}

# ---------------------------------------------------------------------------
# Effort — INTEGRATION. Effort is fused into row 1, column 1 ('X … <effort>') and
# right-aligns to the column's edge, so the effort word sits flush against the first
# ' | ' separator with any padding BETWEEN 'X' and the effort.
# render() unsets CLAUDE_CODE_EFFORT_LEVEL and uses a fresh CLAUDE_CONFIG_DIR
# with no settings.json, so the default 'medium' path is deterministic.
# ---------------------------------------------------------------------------

# Assert row 1's col-1 leads with 'X' and ends the effort word flush at the ' | ' edge.
assert_row1_effort() {
    local out="$1" want="$2"
    case "$(line_n "$out" 1)" in
        "X "*"${want} |"*) ;;
        *) echo "line1 col-1 does not right-align '${want}' to the edge: $(line_n "$out" 1)" >&2; return 1 ;;
    esac
}

@test "render: effort defaults to medium->'med' when absent" {
    out="$(render '{"model":{"display_name":"X"}}')"
    assert_row1_effort "$out" "med"
}

@test "render: effort 'low' renders raw word" {
    out="$(render '{"model":{"display_name":"X"},"effort":{"level":"low"}}')"
    assert_row1_effort "$out" "low"
}

@test "render: effort 'high' renders 'high'" {
    out="$(render '{"model":{"display_name":"X"},"effort":{"level":"high"}}')"
    assert_row1_effort "$out" "high"
}

@test "render: effort 'xhigh' renders 'xhigh'" {
    out="$(render '{"model":{"display_name":"X"},"effort":{"level":"xhigh"}}')"
    assert_row1_effort "$out" "xhigh"
}

@test "render: effort 'max' renders 'max'" {
    out="$(render '{"model":{"display_name":"X"},"effort":{"level":"max"}}')"
    assert_row1_effort "$out" "max"
}

@test "render: unknown effort renders raw word verbatim" {
    # case *) branch. Only 'medium' is remapped to 'med'; everything else
    # (including unknown words) renders the raw level string.
    out="$(render '{"model":{"display_name":"X"},"effort":{"level":"turbo"}}')"
    assert_row1_effort "$out" "turbo"
}

# ---------------------------------------------------------------------------
# Token count + percentage — INTEGRATION (statusline.sh:82-96, 165-166)
# ---------------------------------------------------------------------------

@test "render: token count sums input+cache_creation+cache_read, pct from size" {
    # current = 40000+5000+5000 = 50000; pct = 50000*100/200000 = 25.
    out="$(render '{"model":{"display_name":"X"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":5000,"cache_read_input_tokens":5000}}}')"
    assert_contains "$out" "50k/200k 25%"
}

@test "render: pct uses integer floor division" {
    # current = 134938; 134938*100/200000 = 67.469 -> floored to 67 (bash
    # integer arithmetic truncates, it does not round).
    out="$(render '{"model":{"display_name":"X"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":100000,"cache_creation_input_tokens":20000,"cache_read_input_tokens":14938}}}')"
    assert_contains "$out" "135k/200k 67%"
}

@test "render: context_window_size=0 falls back to 200000" {
    # statusline.sh:80 forces size=200000 when 0; pct = 10000*100/200000 = 5.
    out="$(render '{"model":{"display_name":"X"},"context_window":{"context_window_size":0,"current_usage":{"input_tokens":10000}}}')"
    assert_contains "$out" "10k/200k 5%"
}

@test "render: missing current_usage -> 0 tokens, 0%" {
    out="$(render '{"model":{"display_name":"X"},"context_window":{"context_window_size":200000}}')"
    assert_contains "$out" "0/200k 0%"
}

@test "render: 1M context total renders uppercase '1M'" {
    # Token millions use uppercase 'M' (SI), matching a model name '(1M context)' —
    # consistent casing for the same magnitude on the same line.
    out="$(render '{"model":{"display_name":"X"},"context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":250000}}}')"
    assert_contains "$out" "250k/1M 25%"
}

# --- context_window.used_percentage precedence (Claude Code ships it precomputed) ---

@test "render: prefers context_window.used_percentage over manual math" {
    # used_percentage=42 is authoritative; the token sum (10k) would compute 5% manually.
    # The precomputed field wins, so pct shows 42% even though the count stays 10k/200k.
    out="$(render '{"model":{"display_name":"X"},"context_window":{"context_window_size":200000,"used_percentage":42,"current_usage":{"input_tokens":10000}}}')"
    assert_contains "$out" "10k/200k 42%"
}

@test "render: used_percentage float is floored to an integer" {
    # 67.9 -> floor -> 67 (awk printf %d truncates), matching the manual path's floor.
    out="$(render '{"model":{"display_name":"X"},"context_window":{"context_window_size":200000,"used_percentage":67.9,"current_usage":{"input_tokens":10000}}}')"
    assert_contains "$out" "67%"
}

@test "render: used_percentage=0 is honored, not treated as absent" {
    # jq '// empty' keeps a literal 0, so the stdin path is taken and shows 0% even though
    # the token sum is non-zero — the classic 0-vs-missing jq footgun, guarded here.
    out="$(render '{"model":{"display_name":"X"},"context_window":{"context_window_size":200000,"used_percentage":0,"current_usage":{"input_tokens":50000}}}')"
    assert_contains "$out" "50k/200k 0%"
}

@test "render: falls back to manual pct when used_percentage absent" {
    # No used_percentage field -> manual floor(50000*100/200000)=25 (existing behavior).
    out="$(render '{"model":{"display_name":"X"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}')"
    assert_contains "$out" "50k/200k 25%"
}

# ---------------------------------------------------------------------------
# cwd / git branch — INTEGRATION (statusline.sh:151-163)
# ---------------------------------------------------------------------------

@test "render: cwd shows basename only" {
    # display_dir=${cwd##*/}. The path need not exist; a non-existent path
    # makes git -C fail, so no '@branch' segment is appended — deterministic.
    # The cwd cell is row 1's trailing cell.
    out="$(render '{"model":{"display_name":"X"},"cwd":"/nope/deep/myproject"}')"
    case "$(line_n "$out" 1)" in
        *"| myproject") ;;
        *) echo "row 1 does not end with the cwd cell: $(line_n "$out" 1)" >&2; return 1 ;;
    esac
}

@test "render: cwd omitted entirely when .cwd empty/missing" {
    # With no cwd cell, row 1 ends after the 5h cell. Exact-line equality proves
    # the omission AND the grid padding (col 1 pads to the stub version's width).
    out="$(render '{"model":{"display_name":"X"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}')"
    [ "$(line_n "$out" 1)" = "X       med | 50k/200k 25% | 5h -" ]
}

@test "render: git branch segment appended as basename@branch" {
    local repo="$BATS_TEST_TMPDIR/coolrepo"
    mk_git_repo "$repo"
    out="$(render "{\"model\":{\"display_name\":\"X\"},\"cwd\":\"$repo\"}")"
    assert_contains "$(line_n "$out" 1)" "| coolrepo@trunk"
}

@test "render: dirty tree inserts the stacked +added/-removed column pair" {
    local repo="$BATS_TEST_TMPDIR/coolrepo"
    mk_git_repo "$repo"
    # Replace the committed single line with two different lines: git numstat
    # reports +2 -1, rendered as '+2' (row 1) stacked over '-1' (row 2), with
    # cwd@branch and worktree shifted to the next column.
    printf 'changed1\nchanged2\n' > "$repo/f.txt"
    out="$(render "{\"model\":{\"display_name\":\"X\"},\"cwd\":\"$repo\"}")"
    l1="$(line_n "$out" 1)"
    l2="$(line_n "$out" 2)"
    assert_contains "$l1" "| +2 | coolrepo@trunk"
    assert_contains "$l2" "| -1 | "
    refute_contains "$l1" "(+2 -1)"
    assert_pipes_aligned "$l1" "$l2"
}

@test "render: clean tree has no +/- column (cwd directly after 5h)" {
    local repo="$BATS_TEST_TMPDIR/coolrepo"
    mk_git_repo "$repo"
    out="$(render "{\"model\":{\"display_name\":\"X\"},\"cwd\":\"$repo\"}")"
    l1="$(line_n "$out" 1)"
    assert_contains "$l1" "| 5h - | coolrepo@trunk"
    assert_pipes_aligned "$l1" "$(line_n "$out" 2)"
}

# ---------------------------------------------------------------------------
# Local helper: initialise a git repo whose HEAD resolves to branch 'trunk'
# with one committed file. core.hooksPath=/dev/null and --no-verify bypass the
# user's global pre-commit hook, which would otherwise block the commit and
# leave HEAD unborn (git rev-parse --abbrev-ref would then not yield 'trunk').
# ---------------------------------------------------------------------------
mk_git_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -b trunk -q
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name Tester
    printf 'original\n' > "$repo/f.txt"
    git -C "$repo" add f.txt
    git -C "$repo" -c core.hooksPath=/dev/null commit -q --no-verify -m init
}

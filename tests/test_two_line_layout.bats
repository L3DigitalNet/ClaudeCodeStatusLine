#!/usr/bin/env bats
# Concern: the two-line grid — pipe alignment across rows, column-3 %/@
# sub-alignment, positional '-' placeholders, the shared trailing cwd column (row 1
# basename@branch[:worktree] / row 2 full path, both omit together), the fused
# model/✦/effort cell with effort right-aligned to the column edge, and the worktree
# suffix on row 1's branch. All INTEGRATION (hermetic render).
# The statusline.ps1 mirror is intentionally UNTESTED here (no pwsh on this host).
load test_helper

# Full-feature stdin: fused col-1 with thinking on, version, cwd (non-existent ->
# no @branch, so the worktree suffix is also absent), 1M context at 44%, builtin rate
# limits with deterministic local reset times. No API data -> the extra cell is its '-'
# placeholder. Row 2's trailing cell is the full (non-collapsed) path.
full_json() {
    local r5 r7
    r5="$(mk_epoch '2099-01-01 16:40')"
    r7="$(mk_epoch '2099-01-03 19:00')"
    printf '{"model":{"display_name":"Sonnet 5"},"effort":{"level":"high"},"thinking":{"enabled":true},"version":"9.9.9","cwd":"/nope/deep/proj","worktree":{"name":"wt"},"context_window":{"context_window_size":1000000,"used_percentage":44,"current_usage":{"input_tokens":435000}},"rate_limits":{"five_hour":{"used_percentage":4,"resets_at":%s},"seven_day":{"used_percentage":12,"resets_at":%s}}}' "$r5" "$r7"
}

@test "layout: output is exactly two lines" {
    out="$(render "$(full_json)")"
    [ "$(printf '%s\n' "$out" | wc -l)" -eq 2 ]
}

@test "layout: golden render matches the agreed example byte-for-byte" {
    # Weekday abbreviation computed, not hardcoded (LC_ALL=C -> 3 chars, capitalized).
    # Doubles as the plain-space-padding proof: colored padding would survive
    # strip_ansi as extra visible bytes and break the equality.
    wd="$(LC_ALL=C date -d '2099-01-03' +%a)"
    out="$(render "$(full_json)")"
    [ "$(line_n "$out" 1)" = "Sonnet 5 ✦ high | 435k/1M 44% | 5h  4%    @16:40 | proj" ]
    [ "$(line_n "$out" 2)" = "v9.9.9          | Fable    😢 | 7d 12% ${wd}@19:00 | /nope/deep/proj" ]
}

@test "layout: pipes align vertically across the two lines" {
    out="$(render "$(full_json)")"
    assert_pipes_aligned "$(line_n "$out" 1)" "$(line_n "$out" 2)"
}

@test "layout: last % and last @ of each line share a column" {
    out="$(render "$(full_json)")"
    l1="$(line_n "$out" 1)"
    l2="$(line_n "$out" 2)"
    [ "$(last_index "$l1" '%')" -eq "$(last_index "$l2" '%')" ]
    [ "$(last_index "$l1" '@')" -eq "$(last_index "$l2" '@')" ]
}

@test "layout: minimal stdin renders the exact placeholder grid" {
    # No cwd -> BOTH rows end after their usage cells (the trailing cwd column omits in
    # both). Effort 'med' right-aligns to col 1's edge under the wider version stub.
    out="$(render '{"model":{"display_name":"X"}}')"
    [ "$(line_n "$out" 1)" = "X       med | 0/200k 0% | 5h -" ]
    # No API data -> Fable weekly is unavailable, so col 2 holds the 😢 (label stays), never
    # a dim '-'. The 😢 is display-width 2, so 'Fable  😢' is 9 wide, matching '0/200k 0%'.
    [ "$(line_n "$out" 2)" = "v0.0.0-test | Fable  😢 | 7d -" ]
}

@test "layout: unknown CLI version renders a dim '-' placeholder cell" {
    out="$(RENDER_CLAUDE_STUB=fail render '{"model":{"display_name":"X"}}')"
    l2="$(line_n "$out" 2)"
    case "$l2" in
        "- "*) ;;
        *) echo "line2 does not start with the '-' version placeholder: $l2" >&2; return 1 ;;
    esac
    refute_contains "$l2" "v0.0.0-test"
    assert_pipes_aligned "$(line_n "$out" 1)" "$l2"
}

@test "layout: partial builtin data placeholders the other usage cell" {
    # Only five_hour present -> the 7d cell is '-' right-aligned under the %
    # column (pct field width = len('42%') = 3).
    json="{\"model\":{\"display_name\":\"X\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":42,\"resets_at\":$(mk_epoch '2099-01-01 11:30')}}}"
    out="$(render "$json")"
    assert_contains "$(line_n "$out" 1)" "5h 42% @11:30"
    assert_contains "$(line_n "$out" 2)" "7d   -"
    assert_pipes_aligned "$(line_n "$out" 1)" "$(line_n "$out" 2)"
}

@test "layout: cwd cell is the trailing cell of row 1" {
    out="$(render '{"model":{"display_name":"X"},"cwd":"/nope/deep/myproject"}')"
    case "$(line_n "$out" 1)" in
        *"| myproject") ;;
        *) echo "row 1 does not end with the cwd cell: $(line_n "$out" 1)" >&2; return 1 ;;
    esac
}

@test "layout: worktree name rides on row 1's branch as ':name'" {
    # Worktree now appends to the branch in row 1 (basename@branch:name), not its own
    # row-2 cell. Needs a real git repo so a branch exists to hang the ':name' onto.
    local repo="$BATS_TEST_TMPDIR/wtrepo"
    mk_git_repo "$repo"
    out="$(render "{\"model\":{\"display_name\":\"X\"},\"cwd\":\"$repo\",\"worktree\":{\"name\":\"feat-x\"}}")"
    case "$(line_n "$out" 1)" in
        *"| wtrepo@trunk:feat-x") ;;
        *) echo "row 1 does not end with cwd@branch:worktree: $(line_n "$out" 1)" >&2; return 1 ;;
    esac
    # The colon+name hide when no worktree is present, even in the same repo.
    out="$(render "{\"model\":{\"display_name\":\"X\"},\"cwd\":\"$repo\"}")"
    refute_contains "$(line_n "$out" 1)" ":feat-x"
    refute_contains "$(line_n "$out" 1)" "trunk:"
}

@test "layout: row 2's trailing cell is the full cwd path" {
    local repo="$BATS_TEST_TMPDIR/pathrepo"
    mk_git_repo "$repo"
    out="$(render "{\"model\":{\"display_name\":\"X\"},\"cwd\":\"$repo\"}")"
    case "$(line_n "$out" 2)" in
        *"| $repo") ;;
        *) echo "row 2 does not end with the full cwd path: $(line_n "$out" 2)" >&2; return 1 ;;
    esac
}

@test "layout: thinking marker sits between model and effort" {
    out="$(render '{"model":{"display_name":"X"},"effort":{"level":"high"},"thinking":{"enabled":true}}')"
    # ✦ joins the right-aligned effort group; padding stays between model and marker.
    assert_contains "$(line_n "$out" 1)" "X"
    assert_contains "$(line_n "$out" 1)" "✦ high |"
}

@test "layout: effort right-aligns flush to column 1's edge" {
    # The version stub 'v0.0.0-test' (11) is wider than 'X med' (5), so the effort word is
    # pushed right to sit flush against the first ' | ' — stacking under the version cell's
    # right edge. This is the fix for high extra-usage dollars shoving 'effort' off the pipe.
    out="$(render '{"model":{"display_name":"X"}}')"
    assert_contains "$(line_n "$out" 1)" "med |"
    # Padding lands BETWEEN 'X' and 'med' (right-alignment), never after 'med'.
    refute_contains "$(line_n "$out" 1)" "X med"
}

# mk_git_repo — local copy of the test_rendering.bats helper: a repo on branch 'trunk'
# with one committed file, hooks bypassed so the commit lands and HEAD resolves.
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

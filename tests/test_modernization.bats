#!/usr/bin/env bats
# Concern: the modernizations that consume newer Claude Code stdin fields — the stdin
# .version display source and workspace.current_dir cwd preference (both invisible to the
# layout), plus the one visible addition kept by request: the ✦ thinking marker on the
# effort word. (The session_name / output_style / cost blocks were reverted — unrequested.)
# All INTEGRATION (hermetic whole-line render).
load test_helper

# ---------------------------------------------------------------------------
# thinking.enabled — ✦ marker fused onto the effort word (the only kept visible block)
# ---------------------------------------------------------------------------

@test "render: thinking.enabled=true puts ✦ between model and effort" {
    # ✦ joins the effort group, so alignment slack lands between the model and
    # marker while `✦ med` stays flush against the column edge.
    out="$(render '{"model":{"display_name":"X"},"thinking":{"enabled":true}}')"
    assert_contains "$(line_n "$out" 1)" "X"
    assert_contains "$(line_n "$out" 1)" "✦ med |"
}

@test "render: thinking marker rides whatever effort level is set" {
    out="$(render '{"model":{"display_name":"X"},"effort":{"level":"high"},"thinking":{"enabled":true}}')"
    assert_contains "$(line_n "$out" 1)" "X"
    assert_contains "$(line_n "$out" 1)" "✦ high |"
}

@test "render: thinking.enabled=false shows no marker" {
    out="$(render '{"model":{"display_name":"X"},"thinking":{"enabled":false}}')"
    refute_contains "$out" "✦"
}

@test "render: absent thinking shows no marker" {
    out="$(render '{"model":{"display_name":"X"}}')"
    refute_contains "$out" "✦"
}

# ---------------------------------------------------------------------------
# version — prefer stdin .version, fall back to the cached CLI shell-out
# ---------------------------------------------------------------------------

@test "render: version comes from stdin .version when present" {
    # 9.9.9 can only come from stdin; the stubbed `claude --version` yields 0.0.0-test.
    out="$(render '{"model":{"display_name":"X"},"version":"9.9.9"}')"
    assert_contains "$out" "v9.9.9"
    refute_contains "$out" "0.0.0-test"
}

@test "render: version falls back to the CLI source when stdin omits it" {
    # No .version -> the CLI path still yields a version cell (row 2, column 1).
    # We assert a version prefix is present, NOT its exact value: render() sandboxes
    # the version cache under a per-test XDG_RUNTIME_DIR, so on this cache-miss run
    # it resolves to the stubbed 0.0.0-test. Presence proves the fallback fired.
    out="$(render '{"model":{"display_name":"X"}}')"
    case "$(line_n "$out" 2)" in
        v*) ;;
        *) echo "line2 does not start with a version cell: $(line_n "$out" 2)" >&2; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# cwd — workspace.current_dir preferred over top-level .cwd (same value, no layout change)
# ---------------------------------------------------------------------------

@test "render: workspace.current_dir is preferred over .cwd" {
    # Non-existent paths so git -C fails and no @branch is appended (deterministic).
    out="$(render '{"model":{"display_name":"X"},"workspace":{"current_dir":"/nope/deep/wsdir"},"cwd":"/nope/deep/cwddir"}')"
    assert_contains "$out" "wsdir"
    refute_contains "$out" "cwddir"
}

@test "render: falls back to .cwd when workspace.current_dir absent" {
    out="$(render '{"model":{"display_name":"X"},"cwd":"/nope/deep/myproject"}')"
    assert_contains "$out" "myproject"
}

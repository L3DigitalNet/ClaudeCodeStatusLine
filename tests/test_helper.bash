# Shared bats helper for the statusline.sh test suite.
# Every .bats file must `load test_helper`. bats-core only — do NOT assume
# bats-assert / bats-support are installed.
#
# Public API (relied on by the four .bats authors — names are a contract):
#   STATUSLINE_SH                 absolute path to statusline.sh
#   load_fn NAME...               extract+eval named functions into the shell
#   strip_ansi                    stdin filter removing ANSI escape codes
#   render JSON                   hermetic whole-line run, ANSI-stripped
#                                 (RENDER_CLAUDE_STUB=fail -> `claude` stub fails)
#   mk_epoch 'YYYY-MM-DD HH:MM'   local epoch seconds via GNU date
#   assert_contains H N / refute_contains H N   assertions w/ diff + return 1
#   line_n STR N                  Nth line (1-based) of a multi-line string
#   pipe_positions STR            space-terminated 1-based '|' indices
#   last_index STR CHAR           1-based index of last CHAR occurrence (0 if none)
#   assert_pipes_aligned L1 L2    shorter pipe list must prefix the longer

# Absolute path to the script under test, derived from this helper's location.
# BATS_TEST_DIRNAME is the directory of the running .bats file (tests/).
STATUSLINE_SH="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/statusline.sh"
export STATUSLINE_SH

# Extract one or more pure functions by name from statusline.sh and eval them
# into the current shell. statusline.sh is NOT sourceable (it reads stdin and
# exits at the top before any function is defined), so we lift functions out
# textually with the sed range '/^NAME()/,/^}/p' — this relies on each target
# function opening with `NAME() {` in column 0 and closing with `}` in column 0,
# which is the house style in statusline.sh.
#
# Fails loudly (returns 1, prints to stderr) if a function can't be extracted or
# doesn't eval cleanly — a silent no-op here would make dependent tests pass for
# the wrong reason.
load_fn() {
    local name body
    for name in "$@"; do
        body="$(sed -n "/^${name}()/,/^}/p" "$STATUSLINE_SH")"
        if [ -z "$body" ]; then
            printf 'load_fn: could not extract function %q from %s\n' \
                "$name" "$STATUSLINE_SH" >&2
            return 1
        fi
        # A correctly extracted function ends with a line that is exactly '}'.
        if [ "$(printf '%s\n' "$body" | tail -n1)" != "}" ]; then
            printf 'load_fn: extraction of %q looks truncated (no closing brace):\n%s\n' \
                "$name" "$body" >&2
            return 1
        fi
        if ! eval "$body"; then
            printf 'load_fn: eval of %q failed\n' "$name" >&2
            return 1
        fi
    done
}

# Remove ANSI SGR escape sequences (colors) from stdin. Assertions run against
# the plain text so color codes never break string matches.
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# Run statusline.sh hermetically on the given JSON and echo the single output
# line with ANSI stripped. Guarantees NO network call and NO real-credential
# access, which on this host requires more than a fresh HOME:
#   * secret-tool / security exist -> get_oauth_token could pull a real keyring
#     token and then curl the usage API. We shadow them (and curl itself) with
#     stubs that exit 1, so token resolution yields empty and no fetch happens.
#   * STATUSLINE_CHECK_UPDATES gate is `!= "false"` (statusline.sh line ~480),
#     so it must be the literal string "false" to skip the GitHub update curl;
#     "0" would NOT disable it.
#   * A unique CLAUDE_CONFIG_DIR gives a unique usage-cache hash, so the run
#     takes the (stubbed, network-free) refresh path deterministically.
# Rate limits are supplied INLINE via the JSON `.rate_limits` object, so the
# "builtin" render path is exercised without any API.
#
# The version block comes from `claude --version`. statusline.sh caches all on-disk state
# under ${XDG_RUNTIME_DIR:-/tmp}/claude, so we pin XDG_RUNTIME_DIR into the sandbox: every
# cache (CLI version, usage, update check) then lands inside the per-test dir and is torn
# down with it — fully hermetic, no shared /tmp/claude leakage between runs. On a cache miss
# the stubbed `claude` yields a deterministic version; we still do not assert exact version
# equality in tests.
render() {
    local json="$1"
    local sandbox home cfg stubbin runtime
    sandbox="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/statusline.XXXXXX")"
    home="$sandbox/home"
    cfg="$sandbox/config"
    stubbin="$sandbox/bin"
    runtime="$sandbox/run"
    mkdir -p "$home" "$cfg" "$stubbin" "$runtime"

    # Network / credential stubs shadow real binaries via PATH prefix.
    local s
    for s in curl secret-tool security; do
        printf '#!/bin/sh\nexit 1\n' > "$stubbin/$s"
        chmod +x "$stubbin/$s"
    done
    # Deterministic CLI version on cache miss (no real `claude` subprocess).
    # RENDER_CLAUDE_STUB=fail makes the stub fail instead, so tests can exercise
    # the version-unknown '-' placeholder cell.
    if [ "${RENDER_CLAUDE_STUB:-}" = "fail" ]; then
        printf '#!/bin/sh\nexit 1\n' > "$stubbin/claude"
    else
        printf '#!/bin/sh\necho "0.0.0-test"\n' > "$stubbin/claude"
    fi
    chmod +x "$stubbin/claude"

    printf '%s' "$json" | env \
        -u CLAUDE_CODE_OAUTH_TOKEN \
        -u CLAUDE_CODE_EFFORT_LEVEL \
        HOME="$home" \
        CLAUDE_CONFIG_DIR="$cfg" \
        XDG_RUNTIME_DIR="$runtime" \
        STATUSLINE_CHECK_UPDATES=false \
        PATH="$stubbin:$PATH" \
        bash "$STATUSLINE_SH" 2>/dev/null | strip_ansi

    rm -rf "$sandbox"
}

# Echo local epoch seconds for 'YYYY-MM-DD HH:MM' using GNU date. Used to build
# `.rate_limits.*.resets_at` values (the builtin path treats resets_at as epoch
# integers). Fails loudly on a bad date string.
mk_epoch() {
    local out
    if ! out="$(date -d "$1" +%s 2>/dev/null)" || [ -z "$out" ]; then
        printf 'mk_epoch: could not parse date %q\n' "$1" >&2
        return 1
    fi
    printf '%s\n' "$out"
}

# assert_contains HAYSTACK NEEDLE — pass if NEEDLE is a substring of HAYSTACK.
assert_contains() {
    local haystack="$1" needle="$2"
    if [ "$haystack" = "${haystack/"$needle"/}" ]; then
        printf 'assert_contains failed:\n  expected substring: %s\n  in string:          %s\n' \
            "$needle" "$haystack" >&2
        return 1
    fi
}

# refute_contains HAYSTACK NEEDLE — pass if NEEDLE is NOT a substring of HAYSTACK.
refute_contains() {
    local haystack="$1" needle="$2"
    if [ "$haystack" != "${haystack/"$needle"/}" ]; then
        printf 'refute_contains failed:\n  unexpected substring: %s\n  in string:            %s\n' \
            "$needle" "$haystack" >&2
        return 1
    fi
}

# ---- Two-line grid helpers (layout tests) ----------------------------------

# Echo the Nth line (1-based) of a multi-line string.
line_n() {
    printf '%s\n' "$1" | sed -n "${2}p"
}

# Normalize display width for column math: 😢 is one code point but TWO terminal columns
# (matching visible_len's own swap), so replace it with two ASCII chars before indexing.
# Without this, a 😢 in row 2 (the Fable-unavailable cell) shifts every downstream '|'/'%'/'@'
# index one left of its display column, spuriously failing the alignment assertions.
_vwidth() {
    printf '%s' "${1//😢/..}"
}

# Space-terminated 1-based indices of every '|' in a plain-text line (display columns).
pipe_positions() {
    awk -v s="$(_vwidth "$1")" 'BEGIN { n = length(s)
        for (i = 1; i <= n; i++) if (substr(s, i, 1) == "|") printf "%d ", i }'
}

# 1-based index of the LAST occurrence of single char $2 in $1 (display columns); 0 when
# absent. Used for the %/@ column checks: line 1 also carries a '%' in the tokens cell,
# so only the last '%'/'@' per line is the column-3 one.
last_index() {
    awk -v s="$(_vwidth "$1")" -v c="$2" 'BEGIN { for (i = length(s); i >= 1; i--)
        if (substr(s, i, 1) == c) { print i; exit } print 0 }'
}

# Pass when the shorter row's pipe list is a prefix of the longer's: shared
# columns align; a longer row may legitimately carry extra trailing pipes.
assert_pipes_aligned() {
    local p1 p2
    p1="$(pipe_positions "$1")"
    p2="$(pipe_positions "$2")"
    if [ -z "$p1" ] || [ -z "$p2" ]; then
        printf 'assert_pipes_aligned: a line has no pipes\n  %s\n  %s\n' "$1" "$2" >&2
        return 1
    fi
    case "$p1" in "$p2"*) return 0 ;; esac
    case "$p2" in "$p1"*) return 0 ;; esac
    printf 'pipes misaligned:\n  [%s] %s\n  [%s] %s\n' "$p1" "$1" "$p2" "$2" >&2
    return 1
}

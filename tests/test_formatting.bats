#!/usr/bin/env bats
# Concern: formatting — pure formatting/comparison helpers in statusline.sh.
# All UNIT tests here lift a single function out of statusline.sh via load_fn
# (the script is not sourceable). No integration/render cases in this file.
load test_helper

# ---------------------------------------------------------------------------
# format_tokens — k/M humanisation of token counts (statusline.sh).
# Rounds half-UP; unit chosen from the rounded value (999500+ promote to 1M);
# SI casing (lowercase k, uppercase M).
# ---------------------------------------------------------------------------

@test "format_tokens zero" {
    load_fn format_tokens
    [ "$(format_tokens 0)" = "0" ]
}

@test "format_tokens small sub-1000" {
    load_fn format_tokens
    [ "$(format_tokens 500)" = "500" ]
}

@test "format_tokens boundary 999" {
    load_fn format_tokens
    [ "$(format_tokens 999)" = "999" ]
}

@test "format_tokens boundary 1000" {
    load_fn format_tokens
    [ "$(format_tokens 1000)" = "1k" ]
}

@test "format_tokens rounds half-up 1500" {
    # 1.5 -> half-up -> 2k.
    load_fn format_tokens
    [ "$(format_tokens 1500)" = "2k" ]
}

@test "format_tokens rounds half-up 2500" {
    # 2.5 -> half-up -> 3k (not banker's 2k).
    load_fn format_tokens
    [ "$(format_tokens 2500)" = "3k" ]
}

@test "format_tokens rounds down 1499" {
    load_fn format_tokens
    [ "$(format_tokens 1499)" = "1k" ]
}

@test "format_tokens typical 50000" {
    load_fn format_tokens
    [ "$(format_tokens 50000)" = "50k" ]
}

@test "format_tokens default context 200000" {
    load_fn format_tokens
    [ "$(format_tokens 200000)" = "200k" ]
}

@test "format_tokens rollover 999499 stays 999k" {
    # Just below the promotion point: rounds to 999k, still in the k range.
    load_fn format_tokens
    [ "$(format_tokens 999499)" = "999k" ]
}

@test "format_tokens rollover 999500 promotes to 1M" {
    # Rounds up out of the k range -> promoted to 1M (not the out-of-range '1000k').
    load_fn format_tokens
    [ "$(format_tokens 999500)" = "1M" ]
}

@test "format_tokens rollover 999999 promotes to 1M" {
    load_fn format_tokens
    [ "$(format_tokens 999999)" = "1M" ]
}

@test "format_tokens millions exact 1000000" {
    # Whole millions -> '1M' (uppercase, matching the model block's '1M').
    load_fn format_tokens
    [ "$(format_tokens 1000000)" = "1M" ]
}

@test "format_tokens millions fractional 1500000" {
    load_fn format_tokens
    [ "$(format_tokens 1500000)" = "1.5M" ]
}

@test "format_tokens millions whole 2000000" {
    load_fn format_tokens
    [ "$(format_tokens 2000000)" = "2M" ]
}

@test "format_tokens millions round half-up 1250000" {
    # 1.25 -> half-up -> 1.3M (not banker's 1.2M).
    load_fn format_tokens
    [ "$(format_tokens 1250000)" = "1.3M" ]
}

# ---------------------------------------------------------------------------
# usage_color — threshold -> color var (statusline.sh:47-54)
# The function echoes $red/$orange/$yellow/$green, so we seed those vars with
# sentinel strings and assert on which sentinel is returned.
# Boundaries: >=90 red, >=70 orange, >=50 yellow, else green.
# ---------------------------------------------------------------------------

@test "usage_color 0 green" {
    load_fn usage_color
    local red=RED orange=ORANGE yellow=YELLOW green=GREEN
    [ "$(usage_color 0)" = "GREEN" ]
}

@test "usage_color 49 green (below yellow boundary)" {
    load_fn usage_color
    local red=RED orange=ORANGE yellow=YELLOW green=GREEN
    [ "$(usage_color 49)" = "GREEN" ]
}

@test "usage_color 50 yellow (yellow boundary)" {
    load_fn usage_color
    local red=RED orange=ORANGE yellow=YELLOW green=GREEN
    [ "$(usage_color 50)" = "YELLOW" ]
}

@test "usage_color 69 yellow (below orange boundary)" {
    load_fn usage_color
    local red=RED orange=ORANGE yellow=YELLOW green=GREEN
    [ "$(usage_color 69)" = "YELLOW" ]
}

@test "usage_color 70 orange (orange boundary)" {
    load_fn usage_color
    local red=RED orange=ORANGE yellow=YELLOW green=GREEN
    [ "$(usage_color 70)" = "ORANGE" ]
}

@test "usage_color 89 orange (below red boundary)" {
    load_fn usage_color
    local red=RED orange=ORANGE yellow=YELLOW green=GREEN
    [ "$(usage_color 89)" = "ORANGE" ]
}

@test "usage_color 90 red (red boundary)" {
    load_fn usage_color
    local red=RED orange=ORANGE yellow=YELLOW green=GREEN
    [ "$(usage_color 90)" = "RED" ]
}

@test "usage_color 100 red" {
    load_fn usage_color
    local red=RED orange=ORANGE yellow=YELLOW green=GREEN
    [ "$(usage_color 100)" = "RED" ]
}

# ---------------------------------------------------------------------------
# version_gt — strict semantic-version greater-than (statusline.sh:60-73)
# Returns 0 (true) iff $1 > $2. Numeric per-component compare, strips leading v,
# missing components default to 0.
# ---------------------------------------------------------------------------

@test "version_gt patch greater true" {
    load_fn version_gt
    version_gt "1.4.5" "1.4.4"
}

@test "version_gt equal false" {
    load_fn version_gt
    ! version_gt "1.4.4" "1.4.4"
}

@test "version_gt patch lower false" {
    load_fn version_gt
    ! version_gt "1.4.3" "1.4.4"
}

@test "version_gt strips leading v" {
    load_fn version_gt
    version_gt "v1.5.0" "1.4.4"
}

@test "version_gt major dominates" {
    load_fn version_gt
    version_gt "2.0.0" "1.9.9"
}

@test "version_gt missing patch treated as 0 equal" {
    load_fn version_gt
    ! version_gt "1.4" "1.4.0"
}

@test "version_gt present patch beats missing patch" {
    load_fn version_gt
    version_gt "1.4.1" "1.4"
}

@test "version_gt numeric not lexical (10 vs 9)" {
    load_fn version_gt
    version_gt "v1.10.0" "v1.9.0"
}

@test "version_gt numeric not lexical reverse" {
    load_fn version_gt
    ! version_gt "1.9.0" "1.10.0"
}

# ---------------------------------------------------------------------------
# collapse_home — collapse a leading $HOME in a path to '~' for the row-2 cwd
# cell. Pure function; HOME is set locally per case so the sandbox HOME leaks
# nothing in. Guards: exact-HOME -> '~'; only a real path-segment boundary
# collapses (a sibling like /home/meX must NOT collapse).
# ---------------------------------------------------------------------------

@test "collapse_home path under HOME collapses to ~" {
    load_fn collapse_home
    [ "$(HOME=/home/me collapse_home /home/me/projects/x)" = "~/projects/x" ]
}

@test "collapse_home exact HOME collapses to bare ~" {
    load_fn collapse_home
    [ "$(HOME=/home/me collapse_home /home/me)" = "~" ]
}

@test "collapse_home unrelated path is unchanged" {
    load_fn collapse_home
    [ "$(HOME=/home/me collapse_home /var/tmp/x)" = "/var/tmp/x" ]
}

@test "collapse_home sibling prefix does NOT collapse (segment boundary)" {
    # /home/meX shares the '/home/me' text prefix but is a different directory;
    # the '$HOME/*' glob only matches on a '/' boundary, so it stays verbatim.
    load_fn collapse_home
    [ "$(HOME=/home/me collapse_home /home/meX/y)" = "/home/meX/y" ]
}

@test "collapse_home empty HOME is a no-op" {
    load_fn collapse_home
    [ "$(HOME= collapse_home /home/me/x)" = "/home/me/x" ]
}

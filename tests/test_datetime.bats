load test_helper

# Concern: datetime formatting (iso_to_epoch, format_reset_time, and the builtin
# render path's reset-time output).
#
# TZ pinning: format_reset_time and the builtin render path format with local-TZ
# `date`, so every wall-clock assertion is pinned to TZ=UTC. Exported per test
# (also inherited by render()/mk_epoch, which do not set TZ themselves). Absolute
# epoch values from iso_to_epoch are TZ-independent but we still pin for clarity.

@test "iso_to_epoch converts UTC Z timestamp to epoch seconds" {
    export TZ=UTC
    load_fn iso_to_epoch
    run iso_to_epoch "2025-06-15T12:30:00Z"
    [ "$status" -eq 0 ]
    [ "$output" = "1749990600" ]
}

@test "iso_to_epoch handles fractional seconds plus explicit +00:00 offset" {
    export TZ=UTC
    load_fn iso_to_epoch
    # Same instant as the plain-Z case: GNU `date -d` (line 311) parses the
    # fractional+offset form directly, so .123 and +00:00 do not shift the epoch.
    run iso_to_epoch "2025-06-15T12:30:00.123+00:00"
    [ "$status" -eq 0 ]
    [ "$output" = "1749990600" ]
}

@test "format_reset_time time style yields HH:MM 24h" {
    export TZ=UTC
    load_fn iso_to_epoch format_reset_time
    # style=time -> `date +"%H:%M"`. No leading @ (the @ is added by the caller).
    run format_reset_time "2025-06-15T11:30:00Z" "time"
    [ "$status" -eq 0 ]
    [ "$output" = "11:30" ]
}

@test "format_reset_time datetime style yields Weekday@HH:MM with single @ and no leading @" {
    export TZ=UTC
    load_fn iso_to_epoch format_reset_time
    # 2025-06-15 is a Sunday. style=datetime -> `date +"%a@%H:%M"`.
    run format_reset_time "2025-06-15T19:00:00Z" "datetime"
    [ "$status" -eq 0 ]
    [ "$output" = "Sun@19:00" ]
}

@test "format_reset_time default/date style yields abbreviated month and day" {
    export TZ=UTC
    load_fn iso_to_epoch format_reset_time
    # `*)` default case -> `date +"%b %-d"` (no leading zero on day via %-d).
    run format_reset_time "2025-06-15T19:00:00Z" "date"
    [ "$status" -eq 0 ]
    [ "$output" = "Jun 15" ]
}

@test "format_reset_time returns empty for empty iso string (guard)" {
    export TZ=UTC
    load_fn iso_to_epoch format_reset_time
    # Guard fires before any date call.
    run format_reset_time "" "time"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "format_reset_time returns empty for literal null iso string (guard)" {
    export TZ=UTC
    load_fn iso_to_epoch format_reset_time
    # jq emits `null` when resets_at is JSON null; the guard prevents `date -d null`.
    run format_reset_time "null" "time"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "full render shows 5h @HH:MM and 7d Weekday@HH:MM from builtin epoch resets" {
    export TZ=UTC
    # Builtin render path treats resets_at as raw epoch integers; regenerate them
    # under TZ=UTC so weekday/time stay pinned. 11:30 UTC and 19:00 UTC (Sunday).
    local five_reset seven_reset
    five_reset="$(mk_epoch '2025-06-15 11:30')"
    seven_reset="$(mk_epoch '2025-06-15 19:00')"
    local json
    json="$(jq -nc --argjson f "$five_reset" --argjson s "$seven_reset" \
        '{model:{display_name:"Opus 4.8"},rate_limits:{five_hour:{used_percentage:42,resets_at:$f},seven_day:{used_percentage:30,resets_at:$s}}}')"
    run render "$json"
    [ "$status" -eq 0 ]
    # Col-3 sub-alignment: the 5h reset pads left by the 7d weekday width (3), so
    # its '@' stacks under the 7d '@' — hence the four spaces before '@11:30'.
    assert_contains "$output" "5h 42%    @11:30"
    assert_contains "$output" "7d 30% Sun@19:00"
}

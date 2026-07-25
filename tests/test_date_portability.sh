#!/usr/bin/env bash
#
# bash_unit tests for the date-portability helpers across awsh (BSD date on
# macOS vs. GNU/busybox date on Linux/Alpine, klue's container runtime).
#
# Run with: bash_unit tests/test_date_portability.sh
#
# SPDX-FileCopyrightText: Björn Busse <bj.rn@baerlin.eu>
# SPDX-License-Identifier: BSD-3-Clause

AWSH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pull just the function (or, for the two scripts where the fix isn't inside
# a named function, the exact fixed snippet) under test out of each script
# rather than sourcing the whole file: these scripts parse "$@" and check for
# aws/jq at top level, which would require mocking a full CLI invocation to
# source safely.
_aurora_fn_src() {
    awk '/^function _aws_seconds_ago\(\)/,/^}/' "$AWSH_DIR/aws-aurora-monitor"
}

_asg_fn_src() {
    awk '/^date_utc_minus_minutes\(\)/,/^}/' "$AWSH_DIR/aws-ec2-asg-monitor"
}

_lb_fn_src() {
    awk '/^_iso8601_utc\(\)/,/^}/' "$AWSH_DIR/aws-lb"
}

_lb_traffic_fn_src() {
    awk '/^get_start_time\(\)/,/^}/' "$AWSH_DIR/aws-lb-traffic"
}

# Not a function: inline top-level script code. Extracted by the same
# distinctive comment anchor the fix itself added, through the closing `fi`.
_instance_by_traffic_snippet_src() {
    awk '/^# Get time 24 hours ago in UTC\. Epoch arithmetic/,/^fi$/' \
        "$AWSH_DIR/aws-instance-by-traffic"
}

_redshift_snippet_src() {
    awk '/Epoch arithmetic \+ the GNU\/BSD date/,/^    fi$/' \
        "$AWSH_DIR/aws-redshift-monitor"
}

eval "$(_aurora_fn_src)"
eval "$(_asg_fn_src)"
eval "$(_lb_fn_src)"
eval "$(_lb_traffic_fn_src)"

# Ground truth ISO-8601 -> epoch conversion, independent of the date
# implementation under test.
_iso_to_epoch() {
    python3 -c '
import datetime, sys
s = sys.argv[1]
fmt = "%Y-%m-%dT%H:%M:%SZ" if s.endswith("Z") else "%Y-%m-%dT%H:%M:%S"
dt = datetime.datetime.strptime(s, fmt).replace(tzinfo=datetime.timezone.utc)
print(int(dt.timestamp()))
' "$1"
}

_assert_close_to_now_minus() {
    local label="$1" iso="$2" now="$3" seconds="$4"
    local got_epoch expected diff
    got_epoch=$(_iso_to_epoch "$iso") || {
        fail "$label: could not parse '$iso' as a timestamp"
        return
    }
    expected=$((now - seconds))
    diff=$((got_epoch - expected))
    ((diff < 0)) && diff=$((-diff))
    assert "test $diff -le 3" \
        "$label: '$iso' -> epoch $got_epoch, expected ~$expected (off by ${diff}s)"
}

test_aurora_seconds_ago_on_native_date() {
    local now iso
    now=$(date -u +%s)
    iso=$(_aws_seconds_ago 300)
    _assert_close_to_now_minus "aws-aurora-monitor _aws_seconds_ago(300)" "$iso" "$now" 300
}

test_asg_minutes_ago_on_native_date() {
    local now iso
    now=$(date -u +%s)
    iso=$(date_utc_minus_minutes 5)
    _assert_close_to_now_minus "aws-ec2-asg-monitor date_utc_minus_minutes(5)" "$iso" "$now" 300
}

test_lb_iso8601_utc_on_native_date() {
    local now iso epoch
    now=$(date -u +%s)
    epoch=$((now - 300))
    iso=$(_iso8601_utc "$epoch")
    _assert_close_to_now_minus "aws-lb _iso8601_utc(now-300)" "$iso" "$now" 300
}

test_lb_traffic_get_start_time_on_native_date() {
    local now iso
    LOOKBACK=300
    now=$(date -u +%s)
    iso=$(get_start_time)
    _assert_close_to_now_minus "aws-lb-traffic get_start_time (LOOKBACK=300)" "$iso" "$now" 300
}

test_instance_by_traffic_start_time_on_native_date() {
    local now
    now=$(date -u +%s)
    eval "$(_instance_by_traffic_snippet_src)"
    _assert_close_to_now_minus "aws-instance-by-traffic START_TIME (24h)" "$START_TIME" "$now" 86400
}

test_redshift_monitor_start_time_on_native_date() {
    local now
    now=$(date -u +%s)
    eval "$(_redshift_snippet_src)"
    _assert_close_to_now_minus "aws-redshift-monitor cw_fetch start (300s)" "$start" "$now" 300
}

_container_runtime() {
    if command -v podman >/dev/null 2>&1; then
        printf 'podman'
    elif command -v docker >/dev/null 2>&1; then
        printf 'docker'
    else
        printf ''
    fi
}

# Regression coverage for the original bug: klue's container runtime is
# Alpine, whose busybox `date` understands neither BSD's -v nor GNU's
# natural-language -d "5 minutes ago", which is what broke here originally.
test_date_helpers_work_under_busybox() {
    local runtime
    runtime=$(_container_runtime)
    if [[ -z "$runtime" ]]; then
        skip "no container runtime (podman/docker) available"
        return
    fi

    # Built in three literal (quoted-heredoc) parts stitched around the two
    # snippets that aren't real functions, so their bodies land in the script
    # as actual code to run rather than as text some later "call" would need
    # to re-extract (the extraction helpers only work on the host — they
    # read files via $AWSH_DIR, which doesn't exist inside the container).
    local trailer_part1 trailer_part2 trailer_part3 full_script out
    trailer_part1=$(
        cat <<'EOF'
now=$(date -u +%s)
printf 'AURORA %s %s\n' "$now" "$(_aws_seconds_ago 300)"
now=$(date -u +%s)
printf 'ASG %s %s\n' "$now" "$(date_utc_minus_minutes 5)"
now=$(date -u +%s)
printf 'LB %s %s\n' "$now" "$(_iso8601_utc "$(($(date -u +%s) - 300))")"
LOOKBACK=300
now=$(date -u +%s)
printf 'LBTRAFFIC %s %s\n' "$now" "$(get_start_time)"
now=$(date -u +%s)
EOF
    )
    trailer_part2=$(
        cat <<'EOF'
printf 'INSTANCE %s %s\n' "$now" "$START_TIME"
now=$(date -u +%s)
EOF
    )
    trailer_part3=$(
        cat <<'EOF'
printf 'REDSHIFT %s %s\n' "$now" "$start"
EOF
    )
    # Plain concatenation (not a heredoc) so $1/${epoch} inside the extracted
    # function bodies are not re-expanded by this shell before reaching the
    # container.
    # Wrapped in throwaway functions (not run inline) so a `local` inside
    # either snippet — valid in its real home function, invalid at script
    # top level — doesn't produce a spurious warning here.
    full_script="$(_aurora_fn_src)
$(_asg_fn_src)
$(_lb_fn_src)
$(_lb_traffic_fn_src)
$trailer_part1
_run_instance_snippet() {
$(_instance_by_traffic_snippet_src)
}
_run_instance_snippet
$trailer_part2
_run_redshift_snippet() {
$(_redshift_snippet_src)
}
_run_redshift_snippet
$trailer_part3"

    out=$(printf '%s\n' "$full_script" |
        "$runtime" run --rm -i alpine:3 sh -c 'apk add --no-cache bash python3 >/dev/null 2>&1 && exec bash -s')

    _check_busybox_case "$out" AURORA "aws-aurora-monitor _aws_seconds_ago(300)" 300
    _check_busybox_case "$out" ASG "aws-ec2-asg-monitor date_utc_minus_minutes(5)" 300
    _check_busybox_case "$out" LB "aws-lb _iso8601_utc(now-300)" 300
    _check_busybox_case "$out" LBTRAFFIC "aws-lb-traffic get_start_time (LOOKBACK=300)" 300
    _check_busybox_case "$out" INSTANCE "aws-instance-by-traffic START_TIME (24h)" 86400
    _check_busybox_case "$out" REDSHIFT "aws-redshift-monitor cw_fetch start (300s)" 300
}

_check_busybox_case() {
    local out="$1" tag="$2" label="$3" seconds="$4"
    local line
    line=$(printf '%s\n' "$out" | grep "^$tag ")
    assert "test -n '$line'" "busybox: $label should produce output (got: $out)"
    if [[ -n "$line" ]]; then
        local now iso
        read -r _ now iso <<<"$line"
        _assert_close_to_now_minus "busybox $label" "$iso" "$now" "$seconds"
    fi
}

#!/usr/bin/env bash
#
# bash_unit tests for the date-portability helpers in aws-aurora-monitor and
# aws-ec2-asg-monitor (BSD date on macOS vs. GNU/busybox date on Linux/Alpine).
#
# Run with: bash_unit tests/test_date_portability.sh
#
# SPDX-FileCopyrightText: Björn Busse <bj.rn@baerlin.eu>
# SPDX-License-Identifier: BSD-3-Clause

AWSH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pull just the function under test out of each script rather than sourcing
# the whole file: both scripts parse "$@" and check for aws/jq at top level,
# which would require mocking a full CLI invocation to source safely.
_aurora_fn_src() {
    awk '/^function _aws_seconds_ago\(\)/,/^}/' "$AWSH_DIR/aws-aurora-monitor"
}

_asg_fn_src() {
    awk '/^date_utc_minus_minutes\(\)/,/^}/' "$AWSH_DIR/aws-ec2-asg-monitor"
}

eval "$(_aurora_fn_src)"
eval "$(_asg_fn_src)"

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
        assert_fail "$label: could not parse '$iso' as a timestamp"
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

    local trailer full_script out
    trailer=$(
        cat <<'EOF'
now=$(date -u +%s)
printf 'AURORA %s %s\n' "$now" "$(_aws_seconds_ago 300)"
now=$(date -u +%s)
printf 'ASG %s %s\n' "$now" "$(date_utc_minus_minutes 5)"
EOF
    )
    # Plain concatenation (not a heredoc) so $1/${epoch} inside the extracted
    # function bodies are not re-expanded by this shell before reaching the
    # container.
    full_script="$(_aurora_fn_src)
$(_asg_fn_src)
$trailer"

    out=$(printf '%s\n' "$full_script" |
        "$runtime" run --rm -i alpine:3 sh -c 'apk add --no-cache bash python3 >/dev/null 2>&1 && exec bash -s')

    local aurora_line asg_line
    aurora_line=$(printf '%s\n' "$out" | grep '^AURORA ')
    asg_line=$(printf '%s\n' "$out" | grep '^ASG ')

    assert "test -n '$aurora_line'" \
        "busybox: _aws_seconds_ago should produce output (got: $out)"
    assert "test -n '$asg_line'" \
        "busybox: date_utc_minus_minutes should produce output (got: $out)"

    if [[ -n "$aurora_line" ]]; then
        local now iso
        read -r _ now iso <<<"$aurora_line"
        _assert_close_to_now_minus "busybox aws-aurora-monitor _aws_seconds_ago(300)" "$iso" "$now" 300
    fi

    if [[ -n "$asg_line" ]]; then
        local now iso
        read -r _ now iso <<<"$asg_line"
        _assert_close_to_now_minus "busybox aws-ec2-asg-monitor date_utc_minus_minutes(5)" "$iso" "$now" 300
    fi
}

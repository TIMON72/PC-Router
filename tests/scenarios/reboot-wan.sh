#!/usr/bin/env bash
# Real OS reboot with WAN only (LTE disabled). After boot: path=wan + VPN.
# Usage: reboot-wan.sh [observe_sec]
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck disable=SC1091
source "$TESTS_ROOT/lib/reboot-case.sh"
reboot_test_run wan "${1:-180}"

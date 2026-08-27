#!/usr/bin/env bash
# Real OS reboot with WAN+LTE available. After boot: WAN preferred + VPN.
# Usage: reboot-both.sh [observe_sec]
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck disable=SC1091
source "$TESTS_ROOT/lib/reboot-case.sh"
reboot_test_run both "${1:-180}"

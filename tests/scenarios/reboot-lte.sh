#!/usr/bin/env bash
# Real OS reboot LTE-only (WAN held from early boot). After boot: path=lte + VPN.
# Usage: reboot-lte.sh [observe_sec]
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck disable=SC1091
source "$TESTS_ROOT/lib/reboot-case.sh"
reboot_test_run lte "${1:-180}"

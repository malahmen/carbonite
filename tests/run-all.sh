#!/usr/bin/env bash
# Run every tests/test-*.sh; non-zero if any fails. No network, no daemon.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
for t in "$TEST_DIR"/test-*.sh; do
    if out="$(bash "$t" 2>&1)"; then echo "PASS  $(basename "$t")"
    else echo "FAIL  $(basename "$t")"; grep -E '^ *FAIL' <<<"$out" | sed 's/^/        /'; failed=1; fi
done
exit "$failed"

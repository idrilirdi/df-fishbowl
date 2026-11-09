#!/bin/bash
# Run every test. No framework: each test file exits non-zero on failure and
# prints what broke. Needs bash, awk and python3 (stdlib only), nothing else.
set -u
cd "$(dirname "$0")/.." || exit 1
rc=0
for t in tests/fit.sh tests/frame.py; do
	echo "== $t"
	case "$t" in
	*.py) python3 -I "$t" || rc=1 ;;
	*) bash "$t" || rc=1 ;;
	esac
done
[ "$rc" = 0 ] && echo "ALL PASSED" || echo "FAILURES"
exit "$rc"

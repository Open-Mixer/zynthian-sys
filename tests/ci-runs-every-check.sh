#!/bin/bash
#******************************************************************************
# Every tests/*-check.sh runs in .github/workflows/ci.yml, or is named below
# with what it needs that CI does not have. A script that is in no step pins
# nothing: it can go red and nobody sees it.
#
#   tests/ci-runs-every-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
CI=${CI_FILE:-$HERE/../.github/workflows/ci.yml}

# script: what it needs
NOT_IN_CI="modhost-backend-check.sh"   # a running JACK server, plugin-hostd and omx-clap-host as root, port 5555 free: a Zynthian

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

for f in "$HERE"/*-check.sh; do
	name=$(basename "$f")
	case " $NOT_IN_CI " in
	*" $name "*)
		check "$name is not in CI and says why: it needs a device" bash -c '! grep -q "tests/$1" "$2"' _ "$name" "$CI" ;;
	*)
		check "$name runs in a CI step" grep -q "tests/$name" "$CI" ;;
	esac
done

[ "$fails" = 0 ] && echo "ci-runs-every-check: all checks passed" || echo "ci-runs-every-check: $fails checks failed"
exit "$fails"

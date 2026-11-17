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

# a step runs the script: a real run line, outside a comment, in a step that is not switched off
not() { ! "$@"; }
# Read with python3's standard library only (the CI job has no PyYAML): a step starts at a
# list item at the indent of the first one under `steps:`; comment lines are dropped; a step
# whose `if:` is a literal false is skipped.
runs_in() {
	python3 -I - "$1" "tests/$2" <<'PY'
import re, sys
path, want = sys.argv[1:3]
steps, cur, step_indent, in_run = [], None, None, False
for raw in open(path):
    line = raw.rstrip("\n")
    if line.lstrip().startswith("#") or not line.strip():
        continue
    indent = len(line) - len(line.lstrip())
    if line.lstrip().startswith("steps:"):
        step_indent, cur = None, None
        continue
    if line.lstrip().startswith("- "):
        if step_indent is None:
            step_indent = indent
        if indent == step_indent:
            cur = {"if": None, "run": []}
            in_run = False
            steps.append(cur)
            line = " " * (indent + 2) + line.lstrip()[2:]
    if cur is None:
        continue
    body = line.strip()
    m = re.match(r"if:\s*(.*?)\s*(#.*)?$", body)
    if m and len(line) - len(line.lstrip()) == step_indent + 2:
        cur["if"] = m.group(1)
    elif body.startswith("run:") and len(line) - len(line.lstrip()) == step_indent + 2:
        cur["run"].append(body[4:])
        in_run = True
        continue
    elif in_run and len(line) - len(line.lstrip()) > step_indent + 2:
        cur["run"].append(body)
        continue
    in_run = False
off = {"false", "${{ false }}", "'false'", '"false"'}
for st in steps:
    if st["if"] in off:
        continue
    if any(want in l for l in st["run"]):
        sys.exit(0)
sys.exit(1)
PY
}

# the matcher itself, on a workflow with a live step, a commented-out one and a disabled one
fx=$(mktemp -d)
trap 'rm -rf "$fx"' EXIT
cat >"$fx/ci.yml" <<'YML'
jobs:
  a:
    steps:
      - name: live
        run: tests/live-check.sh
      - name: live block
        run: |
          echo before
          tests/block-check.sh
      # - name: commented out
      #   run: tests/commented-check.sh
      - name: disabled
        if: false
        run: tests/disabled-check.sh
      - name: a comment inside a block
        run: |
          # tests/incomment-check.sh
          true
YML
check "the matcher finds a live step" runs_in "$fx/ci.yml" live-check.sh
check "the matcher finds a script inside a run block" runs_in "$fx/ci.yml" block-check.sh
check "the matcher does not take a commented-out step" not runs_in "$fx/ci.yml" commented-check.sh
check "the matcher does not take a step with if: false" not runs_in "$fx/ci.yml" disabled-check.sh
check "the matcher does not take a comment inside a run block" not runs_in "$fx/ci.yml" incomment-check.sh

for f in "$HERE"/*-check.sh; do
	name=$(basename "$f")
	case " $NOT_IN_CI " in
	*" $name "*)
		check "$name is not in CI and says why: it needs a device" not runs_in "$CI" "$name" ;;
	*)
		check "$name runs in a CI step" runs_in "$CI" "$name" ;;
	esac
done

[ "$fails" = 0 ] && echo "ci-runs-every-check: all checks passed" || echo "ci-runs-every-check: $fails checks failed"
exit "$fails"

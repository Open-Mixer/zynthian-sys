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
# whose `if:`, or its job's, is a literal false (`false`, `${{ false }}`, `${{false}}`) is skipped.
runs_in() {
	python3 -I - "$1" "tests/$2" <<'PY'
import re, sys
path, want = sys.argv[1:3]
steps, cur, step_indent, in_run = [], None, None, False
job, job_indent, in_jobs = {"if": None}, None, False
for raw in open(path):
    line = raw.rstrip("\n")
    if line.lstrip().startswith("#") or not line.strip():
        continue
    indent = len(line) - len(line.lstrip())
    if indent == 0:
        in_jobs, job_indent = line.startswith("jobs:"), None
        continue
    if in_jobs and job_indent is None:
        job_indent = indent
    if in_jobs and indent == job_indent:
        job, cur, step_indent = {"if": None}, None, None
        continue
    if in_jobs and indent == job_indent + 2:
        m = re.match(r"if:\s*(.*?)\s*(#.*)?$", line.strip())
        if m:
            job["if"] = m.group(1)
            continue
    if line.lstrip().startswith("steps:"):
        step_indent, cur = None, None
        continue
    if line.lstrip().startswith("- "):
        if step_indent is None:
            step_indent = indent
        if indent == step_indent:
            cur = {"if": None, "run": [], "job": job}
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
def is_off(v):
    return v is not None and re.sub(r"\s|\$\{\{|\}\}|'|\"", "", v) == "false"
for st in steps:
    if is_off(st["if"]) or is_off(st["job"]["if"]):
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
  off:
    if: false
    steps:
      - name: in a disabled job
        run: tests/joboff-check.sh
  off2:
    name: disabled the other way
    if: ${{false}}
    steps:
      - name: in a job disabled with an expression
        run: tests/jobexpr-check.sh
  off4:
    steps:
      - name: in a job disabled after its steps
        run: tests/joblate-check.sh
    if: false
  off3:
    steps:
      - name: step disabled with a spaceless expression
        if: ${{false}}
        run: tests/stepexpr-check.sh
  words:
    steps:
      - name: only named in an echo
        run: echo tests/echoed-check.sh
      - name: only named in a printf argument
        run: printf '%s\n' tests/printed-check.sh
      - name: only named in a trailing comment
        run: true # tests/trailing-check.sh
      - name: named in a comment inside a block, after a command
        run: |
          true # tests/blockcomment-check.sh
      - name: never fails the job
        continue-on-error: true
        run: tests/coe-check.sh
      - name: run with bash
        run: bash tests/withbash-check.sh
      - name: run after a separator
        run: cd . && ./tests/chained-check.sh
      - name: run in a block after an if
        run: |
          if true; then tests/inthen-check.sh; fi
      - name: run by a quoted path in a hash-free string
        run: sh "tests/quoted-check.sh"
YML
cat >"$fx/ci4.yml" <<'YML'
jobs:
    wide:
        if: false
        steps:
            - name: in a job disabled in a four-space file
              run: tests/wide-check.sh
    live:
        steps:
            - name: live in a four-space file
              run: tests/wide-live-check.sh
YML
check "the matcher finds a live step" runs_in "$fx/ci.yml" live-check.sh
check "the matcher finds a script inside a run block" runs_in "$fx/ci.yml" block-check.sh
check "the matcher does not take a commented-out step" not runs_in "$fx/ci.yml" commented-check.sh
check "the matcher does not take a step with if: false" not runs_in "$fx/ci.yml" disabled-check.sh
check "the matcher does not take a step of a job with if: false" not runs_in "$fx/ci.yml" joboff-check.sh
check "the matcher does not take a step of a job with if: \${{false}}" not runs_in "$fx/ci.yml" jobexpr-check.sh
check "the matcher does not take a step with if: \${{false}}" not runs_in "$fx/ci.yml" stepexpr-check.sh
check "the matcher does not take a step of a job whose if: false follows its steps" not runs_in "$fx/ci.yml" joblate-check.sh
check "the matcher does not take a step of a job with if: false in a four-space file" not runs_in "$fx/ci4.yml" wide-check.sh
check "the matcher finds a live step in a four-space file" runs_in "$fx/ci4.yml" wide-live-check.sh
check "the matcher does not take a name only in an echo" not runs_in "$fx/ci.yml" echoed-check.sh
check "the matcher does not take a name only in a printf argument" not runs_in "$fx/ci.yml" printed-check.sh
check "the matcher does not take a name only in a trailing comment" not runs_in "$fx/ci.yml" trailing-check.sh
check "the matcher does not take a name only in a comment after a command in a block" not runs_in "$fx/ci.yml" blockcomment-check.sh
check "the matcher does not take a step with continue-on-error" not runs_in "$fx/ci.yml" coe-check.sh
check "the matcher finds bash tests/x" runs_in "$fx/ci.yml" withbash-check.sh
check "the matcher finds ./tests/x after &&" runs_in "$fx/ci.yml" chained-check.sh
check "the matcher finds tests/x after then" runs_in "$fx/ci.yml" inthen-check.sh
check "the matcher finds a quoted path run with sh" runs_in "$fx/ci.yml" quoted-check.sh
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

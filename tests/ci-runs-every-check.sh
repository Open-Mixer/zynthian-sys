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

# a step runs the script when the script is executed: the command word of a segment of a run line
# or block (read as the comment above `segments` says: separators, prefixes, bash -c, heredocs),
# outside comments, not followed by || true, || : or || exit 0, in a step that is not switched off
# (its if:, or its job's, is not a literal false) and whose step and job do not continue-on-error
not() { ! "$@"; }
# Read with python3's standard library only (the CI job has no PyYAML): a step starts at a
# list item at the indent of the first one under `steps:`; a job's own keys are at the indent of
# its first key, whatever it is; `false`, `${{ false }}` and `${{false}}` are a literal false.
runs_in() {
	python3 -I - "$1" "tests/$2" <<'PY'
import re, shlex, sys
path, want = sys.argv[1:3]
steps, cur, step_indent, in_run = [], None, None, False
job, job_indent, in_jobs, job_key_indent = {"if": None, "coe": False}, None, False, None
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
        job, cur, step_indent, job_key_indent = {"if": None, "coe": False}, None, None, None
        continue
    if in_jobs and job_key_indent is None and indent > job_indent:
        job_key_indent = indent
    if in_jobs and indent == job_key_indent:
        m = re.match(r"if:\s*(.*?)\s*(#.*)?$", line.strip())
        if m:
            job["if"] = m.group(1)
            continue
        if re.match(r"continue-on-error:\s*(true|\$\{\{\s*true\s*\}\})\s*(#.*)?$", line.strip()):
            job["coe"] = True
            continue
    if line.lstrip().startswith("steps:"):
        step_indent, cur = None, None
        continue
    if line.lstrip().startswith("- "):
        if step_indent is None:
            step_indent = indent
        if indent == step_indent:
            cur = {"if": None, "run": [], "job": job, "coe": False}
            in_run = False
            steps.append(cur)
            line = " " * (indent + 2) + line.lstrip()[2:]
    if cur is None:
        continue
    body = line.strip()
    m = re.match(r"if:\s*(.*?)\s*(#.*)?$", body)
    if m and len(line) - len(line.lstrip()) == step_indent + 2:
        cur["if"] = m.group(1)
    elif re.match(r"continue-on-error:\s*(true|\$\{\{\s*true\s*\}\})\s*(#.*)?$", body) and len(line) - len(line.lstrip()) == step_indent + 2:
        cur["coe"] = True
    elif body.startswith("run:") and len(line) - len(line.lstrip()) == step_indent + 2:
        cur["run"].append(body[4:])
        in_run = True
        continue
    elif in_run and len(line) - len(line.lstrip()) > step_indent + 2:
        cur["run"].append(body)
        continue
    in_run = False
def strip_comment(l):
    # an unquoted " #" (or a leading #) to the end of the line
    q = None
    for i, c in enumerate(l):
        if q:
            if c == q:
                q = None
        elif c in "'\"":
            q = c
        elif c == "#" and (i == 0 or l[i - 1] in " \t"):
            return l[:i]
    return l
# Commands are read per segment: a line is split at && || ; | ( and the words then do else, outside
# quotes; a segment followed by `|| true`, `|| :` or `|| exit 0` cannot fail the job and is dropped.
# Lines of a heredoc body are data. Before the command word these are skipped: VAR=value, and
# source . exec sudo time command; env with its options and VAR=value; timeout with its options
# and duration; bash and sh with their options (-c reads its string as a command line).
SKIP = ("source", ".", "exec", "sudo", "time", "command")
def segments(l):
    out, cur, sep, q, i = [], "", "", None, 0
    def cut(newsep):
        nonlocal cur, sep
        out.append((sep, cur))
        cur, sep = "", newsep
    while i < len(l):
        c = l[i]
        if q:
            cur += c
            if c == q:
                q = None
        elif c in "'\"":
            q = c
            cur += c
        elif l.startswith("&&", i) or l.startswith("||", i):
            cut(l[i:i + 2]); i += 1
        elif c in ";|(":
            cut(c)
        else:
            m = re.match(r"(then|do|else)\b", l[i:]) if (i == 0 or not (l[i - 1].isalnum() or l[i - 1] in "_-./")) else None
            if m:
                cut(m.group(1)); i += len(m.group(1)) - 1
            else:
                cur += c
        i += 1
    out.append((sep, cur))
    return out
def words_of(t):
    try:
        return shlex.split(t)
    except ValueError:
        return t.split()
def command_of(words):
    # the words from the command word on; for bash -c, the command string comes back as text
    while words:
        w = words[0]
        if w in SKIP or re.match(r"[A-Za-z_][A-Za-z0-9_]*=", w):
            words = words[1:]
        elif w == "env":
            words = words[1:]
            while words and (words[0].startswith("-") or re.match(r"[A-Za-z_][A-Za-z0-9_]*=", words[0])):
                words = words[2:] if words[0] == "-u" else words[1:]
        elif w == "timeout":
            words = words[1:]
            while words and words[0].startswith("-"):
                words = words[2:] if words[0] in ("-k", "-s") else words[1:]
            if words and re.match(r"[0-9.]+[smhd]?$", words[0]):
                words = words[1:]
        elif w in ("bash", "sh"):
            words = words[1:]
            while words and words[0][:1] in "-+" and len(words[0]) > 1:
                o = words[0]
                if o == "--":
                    words = words[1:]
                    break
                if o.startswith("-") and "c" in o[1:] and not o.startswith("--"):
                    return ("string", words[1] if len(words) > 1 else "")
                words = words[2:] if o in ("-o", "+o") else words[1:]
        else:
            break
    return ("word", words[0].rstrip(")") if words else "")
def executes(l):
    segs = segments(strip_comment(l))
    for i, (sep, text) in enumerate(segs):
        kind, val = command_of(words_of(text))
        if kind == "string":
            hit = executes(val)
        else:
            hit = val == want or val.endswith("/" + want)
        if not hit:
            continue
        nxt = segs[i + 1] if i + 1 < len(segs) else None
        if nxt and nxt[0] == "||" and nxt[1].strip() in ("true", ":", "exit 0"):
            continue
        return True
    return False
def drop_heredocs(lines):
    out, end = [], None
    for l in lines:
        if end is not None:
            if l.strip() == end:
                end = None
            continue
        out.append(l)
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", strip_comment(l))
        if m and "<<<" not in l:
            end = m.group(2)
    return out
def join_continued(lines):
    # a line ending in a backslash joins the next one
    out, acc = [], ""
    for l in lines:
        t = l.strip()
        if t.endswith("\\"):
            acc += t[:-1].rstrip() + " "
        else:
            out.append(acc + t)
            acc = ""
    if acc:
        out.append(acc)
    return out
def is_off(v):
    return v is not None and re.sub(r"\s|\$\{\{|\}\}|'|\"", "", v) == "false"
for st in steps:
    if is_off(st["if"]) or is_off(st["job"]["if"]) or st["coe"] or st["job"]["coe"]:
        continue
    if any(executes(l) for l in drop_heredocs(join_continued(st["run"]))):
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
      - name: run on the line after a continuation
        run: |
          bash \
            tests/continued-check.sh
      - name: run on a continuation of a one-line run
        run: cd . && \
          tests/continued1-check.sh
      - name: only an echo argument on the continuation
        run: |
          echo hello \
            tests/contecho-check.sh
      - name: run by a quoted path in a hash-free string
        run: sh "tests/quoted-check.sh"
  more:
    steps:
      - name: masked with true
        run: tests/ortrue-check.sh || true
      - name: masked with a colon
        run: tests/orcolon-check.sh || :
      - name: masked with exit 0
        run: tests/orexit-check.sh || exit 0
      - name: inside a heredoc body
        run: |
          cat <<EOF
          tests/heredoc-check.sh
          EOF
      - name: after a heredoc
        run: |
          cat <<'EOF'
          data
          EOF
          tests/afterheredoc-check.sh
      - name: after a separator inside double quotes
        run: echo "a; tests/dqsep-check.sh"
      - name: after a separator inside single quotes
        run: echo 'a && tests/sqsep-check.sh'
      - name: with env
        run: env X=1 tests/env-check.sh
      - name: with command
        run: command tests/command-check.sh
      - name: with timeout
        run: timeout 60 tests/timeout-check.sh
      - name: with timeout options
        run: timeout -k 5 60 tests/timeoutk-check.sh
      - name: with bash options
        run: bash -e tests/bashe-check.sh
      - name: with bash -c
        run: bash -c 'tests/bashc-check.sh'
      - name: with bash -c after options
        run: bash -ex -o pipefail tests/bashopt-check.sh
  coejob:
    continue-on-error: true
    steps:
      - name: in a job that never fails
        run: tests/jobcoe-check.sh
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
check "the matcher finds a script on the line after a backslash in a block" runs_in "$fx/ci.yml" continued-check.sh
check "the matcher finds a script on the continuation of a one-line run" runs_in "$fx/ci.yml" continued1-check.sh
check "the matcher does not take an echo argument on a continuation line" not runs_in "$fx/ci.yml" contecho-check.sh
check "the matcher finds a quoted path run with sh" runs_in "$fx/ci.yml" quoted-check.sh
check "the matcher does not take a script masked with || true" not runs_in "$fx/ci.yml" ortrue-check.sh
check "the matcher does not take a script masked with || :" not runs_in "$fx/ci.yml" orcolon-check.sh
check "the matcher does not take a script masked with || exit 0" not runs_in "$fx/ci.yml" orexit-check.sh
check "the matcher does not take a step of a job with continue-on-error" not runs_in "$fx/ci.yml" jobcoe-check.sh
check "the matcher does not take a script in a heredoc body" not runs_in "$fx/ci.yml" heredoc-check.sh
check "the matcher finds a script after a heredoc" runs_in "$fx/ci.yml" afterheredoc-check.sh
check "the matcher does not take a ; inside double quotes as a separator" not runs_in "$fx/ci.yml" dqsep-check.sh
check "the matcher does not take a && inside single quotes as a separator" not runs_in "$fx/ci.yml" sqsep-check.sh
check "the matcher finds a script run with env" runs_in "$fx/ci.yml" env-check.sh
check "the matcher finds a script run with command" runs_in "$fx/ci.yml" command-check.sh
check "the matcher finds a script run with timeout" runs_in "$fx/ci.yml" timeout-check.sh
check "the matcher finds a script run with timeout options" runs_in "$fx/ci.yml" timeoutk-check.sh
check "the matcher finds a script run with bash options" runs_in "$fx/ci.yml" bashe-check.sh
check "the matcher finds a script run with bash -c" runs_in "$fx/ci.yml" bashc-check.sh
check "the matcher finds a script run with bash -ex -o pipefail" runs_in "$fx/ci.yml" bashopt-check.sh
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

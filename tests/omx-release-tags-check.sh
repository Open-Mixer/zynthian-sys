#!/bin/bash
#******************************************************************************
# A device follows the fork with Zynthian's own update_zynthian.sh. Our
# releases are signed tags <branch>-<release>-omx.<serial>, made by
# scripts/omx-release-tag.sh; scripts/omx-release-target.sh names the tag the
# updater takes: the newest one that contains the tip the device runs, and in a
# checkout of the fork only one of ours, signed by a pinned key. An upstream
# tag that lacks our tip, a tag signed by another key, a lightweight tag, a tag
# naming another repository and a device with no pinned key all leave the
# device where it is. The daily follower omx-track-latest is gone.
#
#   tests/omx-release-tags-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/..
TARGET=$ROOT/scripts/omx-release-target.sh
TAG=$ROOT/scripts/omx-release-tag.sh
UPDATER=$ROOT/scripts/update_zynthian.sh

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

check "the target script parses" bash -n "$TARGET"
check "the target script is executable" test -x "$TARGET"
check "the tag script parses" bash -n "$TAG"
check "the tag script is executable" test -x "$TAG"
defpat=$(sed -n 's/^FORK_URL_PATTERN=\${FORK_URL_PATTERN:-\(.*\)}$/\1/p' "$TARGET" 2>/dev/null)
check "the default fork pattern takes the Open-Mixer fork" bash -c 'echo https://github.com/Open-Mixer/zynthian-ui.git | grep -q "$1"' _ "$defpat"
check "and a FreeMixer remote of an older install" bash -c 'echo https://github.com/FreeMixer/zynthian-ui.git | grep -q "$1"' _ "$defpat"
check "and never upstream" bash -c '[ -n "$1" ] && ! echo https://github.com/zynthian/zynthian-ui.git | grep -q "$1"' _ "$defpat"

# The daily follower is gone, and a device that had it loses its units
for f in scripts/omx-track-latest.sh scripts/omx-track-tag.sh etc/systemd/omx-track-latest.service \
	etc/systemd/omx-track-latest.timer tests/omx-track-latest-check.sh; do
	check "$f is deleted" test ! -e "$ROOT/$f"
done
check "the update script no longer enables the timer" bash -c '! grep -q "enable --now omx-track-latest" "$1"' _ "$ROOT/scripts/update_zynthian_sys.sh"
check "the update script stops the timer a device still has" grep -q 'systemctl disable --now omx-track-latest.timer' "$ROOT/scripts/update_zynthian_sys.sh"
check "and removes both units" grep -q 'rm -f /etc/systemd/system/omx-track-latest.service /etc/systemd/system/omx-track-latest.timer' "$ROOT/scripts/update_zynthian_sys.sh"
check "the unit removal comes before the daemon reload" bash -c 'a=$(grep -n "rm -f /etc/systemd/system/omx-track-latest.service" "$1" | cut -d: -f1); b=$(grep -n "^systemctl daemon-reload" "$1" | tail -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$ROOT/scripts/update_zynthian_sys.sh"
check "the README no longer names the follower" bash -c '! grep -q "omx-track" "$1"' _ "$ROOT/README.md"
check "the README names the tag form" grep -q -- '<branch>-<release>-omx.<serial>' "$ROOT/README.md"
check "an update upgrades the OpenMixer packages, once" test "$(grep -c 'install_openmixer.sh --upgrade' "$UPDATER")" = 1
check "the updater asks the target script, in every repository" grep -q 'scripts/omx-release-target.sh' "$UPDATER"
check "the updater no longer takes the last tag of a plain sort" bash -c '! grep -q "stags\[-1\]" "$1"' _ "$UPDATER"
[ -x "$TARGET" ] && [ -x "$TAG" ] || { echo; echo "$fails failed (the scripts are missing: behaviour not run)"; exit 1; }

# Behaviour against a local upstream and a local fork, with throwaway keys:
# "release" is pinned, "intruder" is not
w=$(mktemp -d)
export GNUPGHOME=$w/gnupg GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Release <release@example.org>' ed25519 sign 1y
gpg --batch --quiet --passphrase '' --quick-gen-key 'Intruder <intruder@example.org>' ed25519 sign 1y
fpr() { gpg --batch --with-colons --fingerprint "$1" | awk -F: '/^fpr:/ {print $10; exit}'; }
gpg --batch --armor --export "$(fpr release@example.org)" >"$w/pinned.asc"

# upstream: one release, vangelis-2610, a plain tag as upstream makes them
git -c init.defaultBranch=vangelis init -q --bare "$w/upstream.git"
git -c init.defaultBranch=vangelis init -q "$w/up"
u() { git -C "$w/up" "$@"; }
echo 1 >"$w/up/f"; u add f; u commit -qm one; u tag vangelis-2610
u remote add o "$w/upstream.git"; u push -q o vangelis vangelis-2610
# the fork: upstream plus our work on the branch openmixer
git init -q --bare "$w/fork.git"
git clone -q "$w/upstream.git" "$w/src"
g() { git -C "$w/src" "$@"; }
g checkout -q -b openmixer; echo ours >"$w/src/o"; g add o; g commit -qm ours
g remote add fork "$w/fork.git"; g push -q fork openmixer vangelis-2610
# the device: origin is upstream, fork is the fork, on openmixer
mkdir -p "$w/z"
git clone -q "$w/upstream.git" "$w/z/zui"
d() { git -C "$w/z/zui" "$@"; }
d remote add fork "$w/fork.git"; d fetch -q fork; d checkout -q -b openmixer fork/openmixer
pat=$w/fork.git
keys=$w/pinned.asc
fetch() { d fetch -q --tags --all --prune --prune-tags --force; }
target() { fetch; FORK_URL_PATTERN=$pat RELEASE_KEYS=$keys "$TARGET" "$w/z/zui" vangelis; }
commit() { echo "$1" >"$w/src/o"; g commit -qam "$1"; g push -q fork openmixer; }
release() { "$TAG" "$w/src" --branch vangelis --name "${2:-zui}" --key "$(fpr "$1")" --push fork; }
head_of() { d rev-parse HEAD; }

out=$(target 2>"$w/err"); rc=$?
check "no tag of ours on the fork: nothing to take" test -z "$out" -a "$rc" = 1
check "upstream's own tag is not ours: the log says so" grep -q 'vangelis-2610 is not an OpenMixer release tag, not taken' "$w/err"

commit two
out=$(release release@example.org)
check "the first release of vangelis-2610 is vangelis-2610-omx.1" test "$(echo "$out" | head -1)" = "vangelis-2610-omx.1 $(g rev-parse HEAD)"
check "the tag is annotated and names the repository" bash -c 'git -C "$1" cat-file tag vangelis-2610-omx.1 | grep -qx "repository: zui"' _ "$w/src"
out=$(target 2>"$w/err"); rc=$?
check "a tag signed by the pinned key that contains the device's tip is the target" test "$out" = vangelis-2610-omx.1 -a "$rc" = 0
check "a commit pushed without a tag is not a target" bash -c 'echo three >"$1/o"; git -C "$1" commit -qam three; git -C "$1" push -q fork openmixer; true' _ "$w/src"
out=$(target 2>/dev/null)
check "the target is still the tag, not the branch tip" test "$out" = vangelis-2610-omx.1

# upstream releases vangelis-2610.1, which lacks our work and sorts after ours
echo 2 >"$w/up/f"; u commit -qam two; u tag vangelis-2610.1; u push -q o vangelis vangelis-2610.1
out=$(target 2>"$w/err")
check "an upstream tag that lacks the device's tip is refused" grep -q "vangelis-2610.1 does not contain the tip this device runs ($(d rev-parse --short HEAD)), not taken" "$w/err"
check "and ours is still the target" test "$out" = vangelis-2610-omx.1

# the updater's own lines, run against the stand-in tree
sed -n '/^if \[\[ "\$ZYNTHIAN_STABLE_TAG" == "last" \]\]; then$/,/^else$/p' "$UPDATER" | sed '$d' | sed "s|/zynthian/|$w/z/|" >"$w/block.sh"
echo fi >>"$w/block.sh"
check "the updater's tag block is found" test "$(grep -c 'for repo_dir in' "$w/block.sh")" = 1
sed -i "s/^  for repo_dir in .*; do$/  for repo_dir in zui ; do/" "$w/block.sh"
update() { ZYNTHIAN_STABLE_TAG=last ZYNTHIAN_STABLE_BRANCH=vangelis ZYNTHIAN_SYS_DIR=$ROOT FORK_URL_PATTERN=$pat RELEASE_KEYS=$keys bash "$w/block.sh" 2>&1; }
out=$(update)
check "the stock updater moves the device to our tag" test "$(head_of)" = "$(g rev-parse 'vangelis-2610-omx.1^{commit}')"
check "on a branch named after the tag, as upstream's scripts expect" test "$(d branch --show-current)" = vangelis-2610-omx.1
check "the updater's log names the refused upstream tag" grep -q 'vangelis-2610.1 does not contain the tip' <<<"$out"
one=$(head_of)
out=$(update)
check "a second run changes nothing" test "$(head_of)" = "$one" -a "$(d branch --show-current)" = vangelis-2610-omx.1

# our next releases: the serial counts, and 10 comes after 9
for i in 2 3 4 5 6 7 8 9 10; do commit "r$i"; release release@example.org >/dev/null; done
check "the tenth release is omx.10" g rev-parse -q --verify refs/tags/vangelis-2610-omx.10
out=$(target 2>/dev/null)
check "omx.10 is newer than omx.9" test "$out" = vangelis-2610-omx.10
update >/dev/null
check "the updater takes omx.10" test "$(head_of)" = "$(g rev-parse HEAD)" -a "$(d branch --show-current)" = vangelis-2610-omx.10
ten=$(head_of)

# what must not move a device
commit forged
g tag -s -u "$(fpr intruder@example.org)" -m 'repository: zui' vangelis-2610-omx.99; g push -q fork refs/tags/vangelis-2610-omx.99
out=$(target 2>"$w/err")
check "a tag signed by another key is refused" grep -q 'vangelis-2610-omx.99 has no good signature by a pinned key, not taken' "$w/err"
check "a forged newer tag does not hide the good one" test "$out" = vangelis-2610-omx.10
g tag vangelis-2610-omx.98; g push -q fork refs/tags/vangelis-2610-omx.98
out=$(target 2>"$w/err")
check "a lightweight tag is refused" grep -q 'vangelis-2610-omx.98 is not an annotated tag, not taken' "$w/err"
g tag -s -u "$(fpr release@example.org)" -m 'repository: other' vangelis-2610-omx.97; g push -q fork refs/tags/vangelis-2610-omx.97
out=$(target 2>"$w/err")
check "a tag naming another repository is refused" grep -q 'vangelis-2610-omx.97 does not name zui and itself, not taken' "$w/err"
g tag vangelis-9999; g push -q fork refs/tags/vangelis-9999
out=$(target 2>"$w/err")
check "a plain tag pushed to the fork is refused, whatever its name" grep -q 'vangelis-9999 is not an OpenMixer release tag, not taken' "$w/err"
check "after all of them the target is unchanged" test "$out" = vangelis-2610-omx.10
update >/dev/null
check "and the updater leaves the device where it is" test "$(head_of)" = "$ten" -a "$(d branch --show-current)" = vangelis-2610-omx.10
keys=$w/absent.asc
out=$(target 2>"$w/err"); rc=$?
check "no pinned key: nothing to take" test -z "$out" -a "$rc" = 1
check "no pinned key: the log says so" grep -q 'no pinned signing key at' "$w/err"
update >/dev/null
check "no pinned key: the updater leaves the device and its branch" test "$(head_of)" = "$ten" -a "$(d branch --show-current)" = vangelis-2610-omx.10
keys=$w/pinned.asc

# a repository we do not fork (zynthian-data, zyncoder): upstream's tags, with
# the same refusal of a tag that would rewind the device
git clone -q "$w/upstream.git" "$w/z/zdata"
out=$(FORK_URL_PATTERN=$pat RELEASE_KEYS=$keys "$TARGET" "$w/z/zdata" vangelis 2>"$w/err")
check "no fork remote: upstream's newest tag is the target when it contains the tip" test "$out" = vangelis-2610.1
echo 3 >"$w/up/f"; u commit -qam three; u push -q o vangelis
git -C "$w/z/zdata" pull -q
out=$(FORK_URL_PATTERN=$pat RELEASE_KEYS=$keys "$TARGET" "$w/z/zdata" vangelis 2>"$w/err"); rc=$?
check "no fork remote: a device ahead of the newest tag is not rewound" test -z "$out" -a "$rc" = 1
check "and the log says why" grep -q 'vangelis-2610.1 does not contain the tip this device runs' "$w/err"

rm -rf "$w"
unset GNUPGHOME GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL

echo
[ "$fails" = 0 ] && echo "all ok" || echo "$fails failed"
exit $((fails > 0))

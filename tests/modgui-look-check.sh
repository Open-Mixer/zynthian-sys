#!/bin/bash
#******************************************************************************
# sbin/omx-modgui-look.sh over a stub omx-modgui-sync, a stub omx-panel and a
# stub dpkg-query: the MOD GUI look (omx-panel's modgui-look setting) is
# recorded once, in /etc/omx/modgui-look, and omx-modgui-sync (omx-panel) writes
# the MOD GUI bundles in it, in MODGUI_DIR (omx-modgui-<name>.lv2, marker
# .omx-modgui-sync); omx-plugins ships no MOD GUI (omx-plugins#122) and the
# package's own bundles in /usr/lib/lv2 are never written. The looks are the
# ones omx-panel declares (schema/modgui-looks.json), never a list of our own;
# an unknown look writes nothing; a sync that fails leaves the setting as it
# was; --apply (the apt hook) runs the sync only when omx-plugins changed since
# the look was applied. Runs anywhere: every path is a temporary directory.
#
#   tests/modgui-look-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${SCRIPT:-$HERE/../sbin/omx-modgui-look.sh}
RECIPE=$HERE/../scripts/recipes/install_openmixer.sh

fails=0
FAILED_ONCE="${TMPDIR:-/tmp}/modgui-look-failed-once.$$"; export FAILED_ONCE
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/lv2/a.lv2" "$T/lv2/b.lv2" "$T/lv2/c.lv2" "$T/modgui" "$T/etc" "$T/var" "$T/schema"
# the package's own bundles, as omx-plugins-lv2 installs them: never written
for b in a b c; do echo packaged > "$T/lv2/$b.lv2/manifest.ttl"; done
packaged() { cat "$T"/lv2/*.lv2/* | tr '\n' ' '; find "$T/lv2" -mindepth 2 | wc -l; }
PACKAGED=$(packaged)

# omx-panel's declaration, as its package installs it
cat > "$T/schema/modgui-looks.json" <<'EOF'
{"setting": {"name": "modgui-look", "values": ["vintage", "console", "3d"], "default": "vintage",
 "env": "OMX_MODGUI_LOOK", "flag": "--look"}, "looks": {}}
EOF

# omx-panel: any call is logged; `modgui ... --out <dir>` writes there (as the real one does)
cat > "$T/bin/omx-panel" <<'EOF'
#!/bin/bash
echo "omx-panel $*" >> "$CALLS"
while [ $# -gt 0 ]; do
	case $1 in --look) look=$2; shift 2 ;; --out) out=$2; shift 2 ;; *) shift ;; esac
done
[ -n "${out:-}" ] && mkdir -p "$out" && echo "${look:-}" > "$out/look"
exit 0
EOF

# omx-modgui-sync (omx-panel#140): reads the look from $MODGUI_LOOK_FILE (first line) and writes
# $MODGUI_DIR/omx-modgui-<name>.lv2 with the marker; SYNC_FAIL=1 makes it fail to start
cat > "$T/bin/omx-modgui-sync" <<'EOF'
#!/bin/bash
echo "omx-modgui-sync $* MODGUI_LOOK_FILE=${MODGUI_LOOK_FILE:-} MODGUI_DIR=${MODGUI_DIR:-}" >> "$CALLS"
[ "${SYNC_FAIL:-}" = 1 ] && { echo "omx-modgui-sync: python3-lilv is not installed" >&2; exit 1; }
look=$(head -n 1 "${MODGUI_LOOK_FILE:-/etc/omx/modgui-look}" 2>/dev/null)
for n in a b c; do
	d=$MODGUI_DIR/omx-modgui-$n.lv2
	mkdir -p "$d" && printf 'urn:%s\n--installed omx-plugins/%s --look %s\n' "$n" "$n" "$look" > "$d/.omx-modgui-sync"
	echo "${look:-default}" > "$d/look"
	# SYNC_FAIL_AFTER=1: the FIRST call dies after one bundle (the later ones are fine)
	if [ "${SYNC_FAIL_AFTER:-}" = 1 ] && [ ! -e "$FAILED_ONCE" ]; then
		: > "$FAILED_ONCE"; echo "omx-modgui-sync: no space left on device" >&2; exit 1
	fi
done
echo "omx-modgui-sync: 3 written, 0 up to date, 0 ship their own, 0 without a descriptor, 0 without controls, 0 with nothing to draw, 0 removed, 0 could not be drawn"
EOF

# dpkg-query: omx-plugins-lv2's file list (its bundles, and a file inside one) and its version
cat > "$T/bin/dpkg-query" <<'EOF'
#!/bin/bash
case "$*" in
"-L omx-plugins-lv2") printf '%s\n' /. "$LV2_DIR" "$LV2_DIR/a.lv2" "$LV2_DIR/a.lv2/manifest.ttl" "$LV2_DIR/b.lv2" "$LV2_DIR/c.lv2" ;;
"-W -f=\${Version} omx-plugins-lv2") printf '%s' "$PKGVER" ;;
*) exit 1 ;;
esac
EOF
chmod +x "$T/bin/omx-panel" "$T/bin/omx-modgui-sync" "$T/bin/dpkg-query"

export PATH=$T/bin:$PATH CALLS=$T/calls LV2_DIR=$T/lv2 MODGUI_DIR=$T/modgui PKGVER=1.0 \
	OMX_PANEL_LOOKS=$T/schema/modgui-looks.json OMX_MODGUI_LOOK_FILE=$T/etc/modgui-look \
	OMX_MODGUI_LOOK_STAMP=$T/var/modgui-look.applied
run() { : > "$CALLS"; "$SCRIPT" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
rc() { test "$(cat "$T/rc")" = "$1"; }
looks() { cat "$T"/modgui/omx-modgui-{a,b,c}.lv2/look 2>/dev/null | tr '\n' ' '; }
nsync() { grep -c '^omx-modgui-sync' "$CALLS"; }
npanel() { grep -c '^omx-panel modgui' "$CALLS"; }
untouched() { test "$(packaged)" = "$PACKAGED"; }

# --- what the settings entry offers and shows
run --list
check "--list prints omx-panel's declared looks, in its order" test "$(cat "$T/out")" = "$(printf 'vintage\nconsole\n3d')"
run --show
check "--show with nothing recorded is the declared default" test "$(cat "$T/out")" = vintage

# --- setting a look
run console
check "setting console exits 0" rc 0
check "  ... runs omx-modgui-sync once" test "$(nsync)" = 1
check "  ... which reads the look from the recorded file (MODGUI_LOOK_FILE)" \
	grep -q "^omx-modgui-sync  MODGUI_LOOK_FILE=$T/etc/modgui-look MODGUI_DIR=$T/modgui\$" "$CALLS"
check "  ... the MODGUI_DIR bundles wear console" test "$(looks)" = "console console console "
check "  ... the package's own bundles in LV2_DIR are not written" untouched
check "  ... and omx-panel modgui is never run on them" test "$(npanel)" = 0
check "  ... the look is recorded" test "$(cat "$T/etc/modgui-look")" = console
check "  ... --show reads it back" bash -c '"$1" --show | grep -qx console' _ "$SCRIPT"
check "  ... the output names the look and the sync's summary" \
	bash -c 'grep -q "modgui-look console: applied" "$1" && grep -q "3 written" "$1"' _ "$T/out"

# --- an undeclared look writes nothing
run neon
check "an undeclared look exits 2" rc 2
check "  ... naming it and the declared ones" grep -q "neon.*vintage console 3d" "$T/out"
check "  ... no sync, no bundle touched" test "$(looks) $(nsync)" = "console console console  0"
check "  ... the recorded look stays" test "$(cat "$T/etc/modgui-look")" = console

# --- a sync that fails: the setting stays
SYNC_FAIL=1 run 3d
check "a sync that fails exits 1" rc 1
check "  ... naming omx-modgui-sync's reason" grep -q "python3-lilv" "$T/out"
check "  ... the recorded look stays" test "$(cat "$T/etc/modgui-look")" = console
check "  ... the package's own bundles are not written" untouched

# --- a sync that fails PART WAY: the bundles it already rewrote wear the new look, so it is put back
before=$(grep -c . "$CALLS")
rm -f "$FAILED_ONCE"; SYNC_FAIL_AFTER=1 FAILED_ONCE=$FAILED_ONCE run 3d
check "a sync that fails after one bundle exits 1" rc 1
check "  ... the recorded look is back to console" test "$(cat "$T/etc/modgui-look")" = console
check "  ... a second sync ran in the old look (two calls)" test "$(( $(grep -c . "$CALLS") - before ))" = 2
check "  ... every bundle wears console again" test "$(looks)" = "console console console"
check "  ... the restore left no .tmp file" test ! -e "$T/etc/modgui-look.tmp"

# --- --apply after a package update (the apt hook)
run --apply
check "--apply with omx-plugins unchanged exits 0 and calls nothing" test "$(cat "$T/rc") $(nsync)" = "0 0"
PKGVER=1.1 run --apply
check "--apply after an omx-plugins update runs omx-modgui-sync in the recorded look" \
	test "$(cat "$T/rc") $(nsync) $(looks)" = "0 1 console console console "
check "  ... and writes nothing in the package's bundles" bash -c 'test "$1" = 0' _ "$(npanel)"
untouched || bad "  ... the package's bundles changed under --apply"
PKGVER=1.1 run --apply
check "  ... and once done, a second --apply calls nothing" test "$(nsync)" = 0

# --- nothing recorded, no declaration
rm -f "$T/etc/modgui-look" "$T/var/modgui-look.applied"
run --apply
check "--apply with no look recorded runs omx-modgui-sync (its default look), writes no look, exit 0" \
	test "$(cat "$T/rc") $(nsync) $(test -e "$T/etc/modgui-look" && echo written)" = "0 1 "
OMX_PANEL_LOOKS=$T/none.json run console
check "no omx-panel looks declaration: refused, exit 1, naming where it looked" \
	bash -c 'test "$(cat "$1/rc")" = 1 && grep -q "$1/none.json" "$1/out"' _ "$T"
check "  ... nothing recorded, no sync" test ! -e "$T/etc/modgui-look" -a "$(nsync)" = 0
check "the package's own bundles were never written, through every run" untouched

# --- the recipe keeps a package update from undoing the look
check "install_openmixer.sh installs the apt hook that runs --apply and never fails apt" \
	grep -q 'omx-modgui-look.sh --apply || true' "$RECIPE"

echo "modgui-look-check: $fails failed"
[ "$fails" = 0 ]

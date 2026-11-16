#!/bin/bash
#******************************************************************************
# sbin/omx-modgui-look.sh over a stub omx-panel and a stub dpkg-query: the
# MOD GUI look (omx-panel's modgui-look setting) is recorded once, in
# /etc/omx/modgui-look, and every installed omx-plugins LV2 bundle's MOD GUI is
# regenerated in it. The looks are the ones omx-panel declares
# (schema/modgui-looks.json), never a list of our own; an unknown look writes
# nothing; a bundle that fails puts the ones already done back and leaves the
# setting as it was; --apply regenerates only when omx-plugins changed since the
# look was applied (a package update ships the default look again). Runs
# anywhere: every path is a temporary directory.
#
#   tests/modgui-look-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${SCRIPT:-$HERE/../sbin/omx-modgui-look.sh}
RECIPE=$HERE/../scripts/recipes/install_openmixer.sh

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/lv2/a.lv2" "$T/lv2/b.lv2" "$T/lv2/c.lv2" "$T/etc" "$T/var" "$T/schema"
for b in a b c; do echo vintage > "$T/lv2/$b.lv2/look"; done

# omx-panel's declaration, as its package installs it
cat > "$T/schema/modgui-looks.json" <<'EOF'
{"setting": {"name": "modgui-look", "values": ["vintage", "console", "3d"], "default": "vintage",
 "env": "OMX_MODGUI_LOOK", "flag": "--look"}, "looks": {}}
EOF

# omx-panel: `modgui --look <l> --installed omx-plugins/<name> --out <bundle>` writes <l> into the bundle's
# `look`; an undeclared look is refused by name, exit 2; FAIL_ON=<name> fails that plugin
cat > "$T/bin/omx-panel" <<'EOF'
#!/bin/bash
echo "omx-panel $*" >> "$CALLS"
[ "$1" = modgui ] || exit 2
shift
while [ $# -gt 0 ]; do
	case $1 in
	--look) look=$2; shift 2 ;;
	--installed) inst=$2; shift 2 ;;
	--out) out=$2; shift 2 ;;
	*) echo "omx-panel: unknown option $1" >&2; exit 2 ;;
	esac
done
case $look in vintage | console | 3d) ;; *) echo "omx-panel: unknown look '$look'" >&2; exit 2 ;; esac
[ "${inst#omx-plugins/}" = "${FAIL_ON:-}" ] && { echo "omx-panel: cannot write $out" >&2; exit 1; }
echo "$look" > "$out/look"
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
chmod +x "$T/bin/omx-panel" "$T/bin/dpkg-query"

export PATH=$T/bin:$PATH CALLS=$T/calls LV2_DIR=$T/lv2 PKGVER=1.0 \
	OMX_PANEL_LOOKS=$T/schema/modgui-looks.json OMX_MODGUI_LOOK_FILE=$T/etc/modgui-look \
	OMX_MODGUI_LOOK_STAMP=$T/var/modgui-look.applied
run() { : > "$CALLS"; "$SCRIPT" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
rc() { test "$(cat "$T/rc")" = "$1"; }
looks() { cat "$T/lv2/a.lv2/look" "$T/lv2/b.lv2/look" "$T/lv2/c.lv2/look" | tr '\n' ' '; }
ncalls() { grep -c '^omx-panel ' "$CALLS"; }

# --- what the settings entry offers and shows
run --list
check "--list prints omx-panel's declared looks, in its order" test "$(cat "$T/out")" = "$(printf 'vintage\nconsole\n3d')"
run --show
check "--show with nothing recorded is the declared default" test "$(cat "$T/out")" = vintage

# --- setting a look
run console
check "setting console exits 0" rc 0
check "  ... every installed bundle is regenerated in console" test "$(looks)" = "console console console "
check "  ... each by omx-panel modgui --look console --installed omx-plugins/<name> --out <bundle>" \
	grep -qx "omx-panel modgui --look console --installed omx-plugins/b --out $T/lv2/b.lv2" "$CALLS"
check "  ... one call per bundle (a file inside a bundle is not a bundle)" test "$(ncalls)" = 3
check "  ... the look is recorded" test "$(cat "$T/etc/modgui-look")" = console
check "  ... --show reads it back" bash -c '"$1" --show | grep -qx console' _ "$SCRIPT"
check "  ... the output names the look and the count" grep -q "modgui-look console: 3 bundle(s) regenerated" "$T/out"

# --- an undeclared look writes nothing
run neon
check "an undeclared look exits 2" rc 2
check "  ... naming it and the declared ones" grep -q "neon.*vintage console 3d" "$T/out"
check "  ... no bundle touched, no call" test "$(looks) $(ncalls)" = "console console console  0"
check "  ... the recorded look stays" test "$(cat "$T/etc/modgui-look")" = console

# --- a bundle that fails: the done ones go back, the setting stays
FAIL_ON=b run 3d
check "a bundle that fails exits 1" rc 1
check "  ... naming the plugin" grep -q "omx-plugins/b" "$T/out"
check "  ... the bundle done before it is put back in the recorded look" test "$(looks)" = "console console console "
check "  ... the recorded look stays" test "$(cat "$T/etc/modgui-look")" = console

# --- --apply after a package update
run --apply
check "--apply with omx-plugins unchanged exits 0 and calls nothing" test "$(cat "$T/rc") $(ncalls)" = "0 0"
for b in a b c; do echo vintage > "$T/lv2/$b.lv2/look"; done   # the update ships the default look again
PKGVER=1.1 run --apply
check "--apply after an omx-plugins update regenerates every bundle in the recorded look" \
	test "$(cat "$T/rc") $(looks)" = "0 console console console "
PKGVER=1.1 run --apply
check "  ... and once done, a second --apply calls nothing" test "$(ncalls)" = 0

# --- nothing recorded, no declaration
rm -f "$T/etc/modgui-look" "$T/var/modgui-look.applied"
run --apply
check "--apply with no look recorded leaves the packages' look, exit 0, no call" test "$(cat "$T/rc") $(ncalls)" = "0 0"
OMX_PANEL_LOOKS=$T/none.json run console
check "no omx-panel looks declaration: refused, exit 1, naming where it looked" \
	bash -c 'test "$(cat "$1/rc")" = 1 && grep -q "$1/none.json" "$1/out"' _ "$T"
check "  ... nothing recorded, no call" test ! -e "$T/etc/modgui-look" -a "$(ncalls)" = 0

# --- the recipe keeps a package update from undoing the look
check "install_openmixer.sh installs the apt hook that runs --apply and never fails apt" \
	grep -q 'omx-modgui-look.sh --apply || true' "$RECIPE"

echo "modgui-look-check: $fails failed"
[ "$fails" = 0 ]

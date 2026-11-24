#!/bin/bash
#******************************************************************************
# scripts/omx-zynthian-gui-build.sh over a stand-in `omx-panel gui-stage` and
# a stub dpkg-query: the package omx-zynthian-gui is staged from the base
# (omx-panel's descriptions-store.md, section 6 and lane 16). The set is every
# installed LV2 plugin bundle on Zynthian's LV2_PATH that omx-plugins-lv2 does
# not own and that no sync of ours wrote; gui-stage runs once over it with the
# base and the package's directory; the package (noarch) holds, for each
# plugin the base describes, its MOD GUI and its LV2 desktop UI, and the
# complement where gui-stage wrote one; a plugin the base does not describe is
# named; two builds give the same bytes. A missing base, a failed gui-stage, a
# staged plugin without a MOD GUI or a desktop UI, and a set the base describes
# none of are each refused, and no package is written.
#
# The stand-in gui-stage follows omx-panel's section 6 (flags only, keys.json
# with each plugin's sha256, <out>/<sha256>/{modgui,complement,lv2ui}); the
# real one is omx-panel#170. Needs dpkg-deb (any Debian):
#
#   tests/omx-zynthian-gui-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
BUILD=${BUILD:-$HERE/../scripts/omx-zynthian-gui-build.sh}

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
not() { ! "$@"; }

command -v dpkg-deb >/dev/null || { echo "no dpkg-deb: run it on Debian"; exit 2; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/lv2" "$T/lv2b" "$T/config"

# an LV2 bundle: name, directory, and whether its TTL states port groups
bundle() {
	local d=$2/$1.lv2
	mkdir -p "$d"
	printf '<urn:zyn:%s> a lv2:Plugin ; lv2:binary <%s.so> ; rdfs:seeAlso <%s.ttl> .\n' "$1" "$1" "$1" >"$d/manifest.ttl"
	printf 'binary of %s\n' "$1" >"$d/$1.so"
	if [ "$3" = groups ]; then echo "<urn:zyn:$1> pg:group <urn:zyn:$1#g> ." >"$d/$1.ttl"; else echo "<urn:zyn:$1> a lv2:Plugin ." >"$d/$1.ttl"; fi
}
bundle alpha "$T/lv2" none     # Zynthian's: no groups, so a complement
bundle beta "$T/lv2" groups    # Zynthian's: groups stated, no complement
bundle gamma "$T/lv2b" none    # Zynthian's, on the second LV2_PATH directory; the base does not describe it
bundle omx-comp "$T/lv2" none  # omx-plugins-lv2's: omx-plugins-gui stages it
mkdir -p "$T/lv2/presets.lv2" "$T/lv2/omx-modgui-alpha.lv2" "$T/lv2/omx-complement-alpha.lv2"
echo '<urn:zyn:alpha#p1> a pset:Preset .' >"$T/lv2/presets.lv2/manifest.ttl"  # a preset bundle: no binary
cp "$T/lv2/alpha.lv2/manifest.ttl" "$T/lv2/omx-modgui-alpha.lv2/" && : >"$T/lv2/omx-modgui-alpha.lv2/.omx-modgui-sync"
cp "$T/lv2/alpha.lv2/manifest.ttl" "$T/lv2/omx-complement-alpha.lv2/" && : >"$T/lv2/omx-complement-alpha.lv2/.omx-complement-sync"
printf 'export LV2_PATH="%s:%s:%s"\n' "$T/lv2" "$T/missing" "$T/lv2b" >"$T/config/zynthian_envars.sh"
echo "base bytes" >"$T/panel.sqlite"
printf 'alpha\nbeta\n' >"$T/base-has"

# dpkg-query: omx-plugins-lv2's file list and omx-panel-descriptions' version
cat >"$T/bin/dpkg-query" <<'EOF'
#!/bin/bash
case "$*" in
"-L omx-plugins-lv2") printf '%s\n' /. "$LV2_DIR" "$LV2_DIR/omx-comp.lv2" "$LV2_DIR/omx-comp.lv2/manifest.ttl" ;;
"-W -f=\${Version} omx-panel-descriptions") printf '0.3.0-1' ;;
*) exit 1 ;;
esac
EOF

# omx-panel gui-stage, as omx-panel's section 6 states it: the plugins of $BASE_HAS are described
cat >"$T/bin/omx-panel" <<'EOF'
#!/bin/bash
echo "omx-panel $*" >>"$CALLS"
[ "$1" = gui-stage ] || exit 2
shift
while [ $# -gt 0 ]; do
	case $1 in --set) set=$2 ;; --descriptions) base=$2 ;; --out) out=$2 ;; *) exit 2 ;; esac
	shift 2
done
cp "$set" "$SET_SEEN"
[ "${STAGE_FAIL:-}" = 1 ] && { echo "gui-stage: $base: schema-mismatch" >&2; exit 1; }
mkdir -p "$out"
plugins=
while IFS= read -r b; do
	n=$(basename "$b" .lv2)
	grep -qx "$n" "$BASE_HAS" || continue
	sha=$(sha256sum "$b/$n.so" | cut -d' ' -f1)
	mkdir -p "$out/$sha/modgui/modgui" "$out/$sha/lv2ui"
	echo "modgui of $n" >"$out/$sha/modgui/modgui.ttl"
	echo "icon of $n" >"$out/$sha/modgui/modgui/icon.html"
	[ "${STAGE_NO_LV2UI:-}" = "$n" ] || echo "ui of $n" >"$out/$sha/lv2ui/manifest.ttl"
	grep -q 'pg:group' "$b/$n.ttl" || { mkdir -p "$out/$sha/complement" && echo "groups of $n" >"$out/$sha/complement/manifest.ttl"; }
	plugins="$plugins${plugins:+,}{\"sha256\": \"$sha\", \"format\": \"lv2\", \"uri\": \"urn:zyn:$n\"}"
done <"$set"
echo "{\"plugins\": [$plugins]}" >"$out/keys.json"
EOF
chmod +x "$T/bin/dpkg-query" "$T/bin/omx-panel"

sha() { sha256sum "$1" | cut -d' ' -f1; }
SHA_A=$(sha "$T/lv2/alpha.lv2/alpha.so")
SHA_B=$(sha "$T/lv2/beta.lv2/beta.so")
GUI=./usr/share/omx/gui/omx-zynthian-gui

# a build into $T/out/<run>: its exit status in $T/out/<run>.rc, its output in .log
build() {
	rm -rf "$T/out/$1" && mkdir -p "$T/out/$1"
	: >"$T/calls"
	PATH="$T/bin:$PATH" CALLS=$T/calls SET_SEEN=$T/set-seen BASE_HAS=$T/base-has LV2_DIR=$T/lv2 \
		ZYNTHIAN_CONFIG_DIR=$T/config OMX_PANEL_BASE=$T/panel.sqlite \
		"$BUILD" --out "$T/out/$1" >"$T/out/$1.log" 2>&1
	echo $? >"$T/out/$1.rc"
}
debs() { find "$T/out/$1" -name '*.deb' | wc -l; }
deb() { find "$T/out/$1" -name '*.deb' | head -n 1; }
holds() { dpkg-deb -c "$(deb "$1")" | awk '{print $NF}' | grep -qx "$2"; }
# a package was written and it does not hold $2 (never true of a missing package)
lacks() { [ -n "$(deb "$1")" ] && ! holds "$1" "$2"; }
# the paths of the package outside /usr/share/omx/gui/omx-zynthian-gui and its parents (none, when one was written)
outside() { [ -n "$(deb "$1")" ] && dpkg-deb -c "$(deb "$1")" | awk '{print $NF}' | grep -vE '^\./(usr/(share/(omx/(gui/(omx-zynthian-gui/.*)?)?)?)?)?$'; }
# the set gui-stage was given does not hold $1 (never true of a set never given)
kept_out() { [ -f "$T/set-seen" ] && ! grep -qE "$1" "$T/set-seen"; }
field() { dpkg-deb -f "$(deb "$1")" "$2"; }
says() { grep -q "$2" "$T/out/$1.log"; }
rc() { cat "$T/out/$1.rc"; }

echo "== the default set, staged from the base"
build one
cat "$T/out/one.log"
check "the build succeeds" test "$(rc one)" = 0
check "gui-stage runs once" test "$(grep -c '^omx-panel gui-stage ' "$T/calls")" = 1
check "gui-stage reads the base the build names" grep -q -- "--descriptions $T/panel.sqlite" "$T/calls"
check "the set is Zynthian's plugin bundles on LV2_PATH, in byte order" \
	test "$(cat "$T/set-seen" 2>/dev/null)" = "$(printf '%s\n' "$T/lv2/alpha.lv2" "$T/lv2/beta.lv2" "$T/lv2b/gamma.lv2")"
check "omx-plugins-lv2's bundle is not in the set (omx-plugins-gui stages it)" kept_out omx-comp
check "a bundle without a binary, and the bundles our syncs wrote, are not in the set" \
	kept_out 'presets|omx-modgui-alpha|omx-complement-alpha'
check "one package is written" test "$(debs one)" = 1
check "the package is omx-zynthian-gui" test "$(field one Package)" = omx-zynthian-gui
check "the package is noarch (Architecture: all)" test "$(field one Architecture)" = all
check "its version is the base's and the key record's" \
	test "$(field one Version)" = "0.3.0-1+k$(dpkg-deb --fsys-tarfile "$(deb one)" | tar -xO "$GUI/keys.json" | sha256sum | cut -c1-12)"
check "it holds the key record" holds one "$GUI/keys.json"
for p in "alpha $SHA_A" "beta $SHA_B"; do
	set -- $p
	check "it holds $1's MOD GUI under its binary's sha256" holds one "$GUI/$2/modgui/modgui.ttl"
	check "it holds $1's LV2 desktop UI" holds one "$GUI/$2/lv2ui/manifest.ttl"
done
check "it holds the complement of alpha, whose TTL states no groups" holds one "$GUI/$SHA_A/complement/manifest.ttl"
check "it holds no complement for beta, whose TTL states groups" lacks one "$GUI/$SHA_B/complement/manifest.ttl"
check "it holds nothing outside /usr/share/omx/gui/omx-zynthian-gui" \
	test -n "$(deb one)" -a -z "$(outside one)"
check "it says how many of the set were staged" says one "2 of 3 plugins staged"
check "it names the plugin the base does not describe" says one "$T/lv2b/gamma.lv2: not in the base"

echo "== two builds give the same bytes"
sleep 1
build two
check "the second build's package is byte-identical" cmp -s "$(deb one)" "$(deb two)"

echo "== refused, and no package written"
mv "$T/panel.sqlite" "$T/panel.sqlite.away"
build nobase
check "no base: refused" test "$(rc nobase)" = 1
check "no base: it names the base" says nobase "$T/panel.sqlite"
check "no base: no package" test "$(debs nobase)" = 0
check "no base: gui-stage is not run" not grep -q gui-stage "$T/calls"
mv "$T/panel.sqlite.away" "$T/panel.sqlite"

STAGE_FAIL=1 build stagefail
check "a failed gui-stage: refused" test "$(rc stagefail)" = 1
check "a failed gui-stage: its words are shown" says stagefail schema-mismatch
check "a failed gui-stage: no package" test "$(debs stagefail)" = 0

STAGE_NO_LV2UI=beta build nolv2ui
check "a staged plugin without a desktop UI: refused" test "$(rc nolv2ui)" = 1
check "a staged plugin without a desktop UI: named" says nolv2ui "$SHA_B: no lv2ui"
check "a staged plugin without a desktop UI: no package" test "$(debs nolv2ui)" = 0

: >"$T/base-has"
build none
check "a set the base describes none of: refused" test "$(rc none)" = 1
check "a set the base describes none of: says nothing-staged" says none nothing-staged
check "a set the base describes none of: no package" test "$(debs none)" = 0

echo
if [ "$fails" = 0 ]; then echo "omx-zynthian-gui: all checks pass"; else echo "omx-zynthian-gui: $fails failed"; fi
[ "$fails" = 0 ]

#!/bin/bash
#******************************************************************************
# The package omx-zynthian-gui, staged from the base (omx-panel's
# docs/descriptions-store.md, section 6, lane 16):
#
#   omx-zynthian-gui-build.sh --out <dir>
#
# - The set is Zynthian's default third-party plugins as installed: every
#   bundle on Zynthian's LV2_PATH (zynthian_envars.sh, or the environment) whose
#   manifest.ttl names an lv2:binary, except omx-plugins-lv2's (omx-plugins-gui
#   stages those) and the bundles our syncs wrote (.omx-modgui-sync,
#   .omx-complement-sync). One path per line, in byte order.
# - `omx-panel gui-stage --set <set> --descriptions <base> --out <dir>` writes
#   each plugin's MOD GUI, LV2 desktop UI and, where its TTL states no groups,
#   LV2 complement, under its binary's SHA-256, and keys.json. The base is
#   omx-panel-descriptions' /usr/share/omx/panel/panel.sqlite (OMX_PANEL_BASE).
# - <dir>/omx-zynthian-gui_<version>_all.deb holds them under
#   /usr/share/omx/gui/omx-zynthian-gui/. The version is the base package's
#   and the key record's: <omx-panel-descriptions version>+k<first 12 hex
#   digits of keys.json's SHA-256>, so the same set over the same base and
#   rules is the same version and the same bytes.
#
# A set plugin the base does not describe is named and not staged. Refused
# (exit 1, no package): no base, gui-stage failing, a staged plugin without
# its MOD GUI or its desktop UI, and a set the base describes none of
# (nothing-staged). Run by install_openmixer.sh, so by the image build.
#******************************************************************************

ZYNTHIAN_CONFIG_DIR=${ZYNTHIAN_CONFIG_DIR:-/zynthian/config}
ENVARS=${ENVARS:-$ZYNTHIAN_CONFIG_DIR/zynthian_envars.sh}
OMX_PANEL_BASE=${OMX_PANEL_BASE:-/usr/share/omx/panel/panel.sqlite}
PKG=omx-zynthian-gui
GUI_DIR=usr/share/omx/gui/$PKG

usage() { echo "Usage: $0 --out <dir>" >&2; exit 2; }
refuse() { echo "omx-zynthian-gui: $*" >&2; exit 1; }

out=
while [ $# -gt 0 ]; do
	case $1 in
	--out) [ -n "$2" ] || usage; out=$2; shift 2 ;;
	*) usage ;;
	esac
done
[ -n "$out" ] || usage

[ -n "$LV2_PATH" ] || LV2_PATH=$(sed -n "s/^export LV2_PATH=[\"']\{0,1\}\([^\"']*\).*/\1/p" "$ENVARS" 2>/dev/null | tail -n 1)
[ -n "$LV2_PATH" ] || refuse "no LV2_PATH in the environment nor in $ENVARS"
[ -f "$OMX_PANEL_BASE" ] || refuse "no base at $OMX_PANEL_BASE (omx-panel-descriptions)"
base_version=$(dpkg-query -W -f='${Version}' omx-panel-descriptions 2>/dev/null)
[ -n "$base_version" ] || refuse "omx-panel-descriptions is not installed: the version comes from the base it holds"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# omx-plugins-lv2's bundles: omx-plugins-gui stages them, and gui-stage refuses a key another package stages
dpkg-query -L omx-plugins-lv2 2>/dev/null | sort -u >"$work/omx-plugins"

# the set: each bundle with a binary on LV2_PATH, but omx-plugins' and our syncs'
IFS=: read -ra dirs <<<"$LV2_PATH"
for d in "${dirs[@]}"; do
	[ -d "$d" ] || continue
	for b in "$d"/*.lv2; do
		[ -f "$b/manifest.ttl" ] || continue
		grep -q 'lv2:binary' "$b/manifest.ttl" || continue
		[ -e "$b/.omx-modgui-sync" ] || [ -e "$b/.omx-complement-sync" ] && continue
		grep -qxF "$b" "$work/omx-plugins" && continue
		echo "$b"
	done
done | LC_ALL=C sort -u >"$work/set"
total=$(wc -l <"$work/set")
[ "$total" -gt 0 ] || refuse "no plugin bundle on LV2_PATH ($LV2_PATH): nothing-staged"

root=$work/root
stage=$root/$GUI_DIR
mkdir -p "$stage"
omx-panel gui-stage --set "$work/set" --descriptions "$OMX_PANEL_BASE" --out "$stage" ||
	refuse "omx-panel gui-stage failed: no package"
[ -f "$stage/keys.json" ] || refuse "gui-stage wrote no keys.json in $stage"

# the binaries' SHA-256 the key record stages, one per line
python3 -c 'import json, sys; [print(p["sha256"]) for p in json.load(open(sys.argv[1]))["plugins"]]' \
	"$stage/keys.json" >"$work/staged" || refuse "keys.json in $stage is not a key record"
staged=$(wc -l <"$work/staged")
[ "$staged" -gt 0 ] || refuse "the base describes none of the $total plugins of the set: nothing-staged"

missing=0
while IFS= read -r sha; do
	[ -f "$stage/$sha/modgui/modgui.ttl" ] || { echo "omx-zynthian-gui: $sha: no modgui" >&2; missing=1; }
	[ -f "$stage/$sha/lv2ui/manifest.ttl" ] || { echo "omx-zynthian-gui: $sha: no lv2ui" >&2; missing=1; }
done <"$work/staged"
[ "$missing" = 0 ] || refuse "a staged plugin lacks its MOD GUI or its desktop UI: no package"

# each set plugin the base does not describe, by its bundle
while IFS= read -r b; do
	found=0
	for so in "$b"/*.so; do
		[ -f "$so" ] && grep -qx "$(sha256sum "$so" | cut -d' ' -f1)" "$work/staged" && found=1
	done
	[ "$found" = 1 ] || echo "  $b: not in the base, not staged"
done <"$work/set"

version="$base_version+k$(sha256sum "$stage/keys.json" | cut -c1-12)"
mkdir -p "$root/DEBIAN"
cat >"$root/DEBIAN/control" <<EOF
Package: $PKG
Version: $version
Architecture: all
Maintainer: OpenMixer <commits@openmixer.org>
Section: sound
Priority: optional
Description: OpenMixer GUIs staged for Zynthian's default plugins
 MOD GUI, LV2 desktop UI and LV2 port-group complement of Zynthian's default
 third-party LV2 plugins, generated by omx-panel gui-stage from the
 descriptions base ($base_version). Staged only: a host's sync links one
 when the plugin's binary, source and rules match its key, and generates
 locally otherwise.
EOF

# the same bytes from the same input: dpkg-deb clamps every mtime to the base's (SOURCE_DATE_EPOCH),
# the modes are fixed and the owner is root
epoch=$(stat -c %Y "$OMX_PANEL_BASE")
find "$root" -type d -exec chmod 0755 {} + && find "$root" -type f -exec chmod 0644 {} +
mkdir -p "$out"
deb=$out/${PKG}_${version}_all.deb
SOURCE_DATE_EPOCH=$epoch dpkg-deb --root-owner-group -Zxz --build "$root" "$deb" >/dev/null ||
	refuse "dpkg-deb could not build $deb"
echo "omx-zynthian-gui: $staged of $total plugins staged: $deb"

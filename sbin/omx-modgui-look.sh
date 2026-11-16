#!/bin/bash
#******************************************************************************
# The MOD GUI look of the OpenMixer plugins, chosen once for the whole Zynthian.
#
#   omx-modgui-look.sh <look>    regenerate every installed omx-plugins bundle's
#                                MOD GUI in <look>, then record it
#   omx-modgui-look.sh --apply   the recorded look again, when omx-plugins-lv2
#                                changed since it was applied (an update ships
#                                the packages' default look); run by apt
#   omx-modgui-look.sh --show    the recorded look, else the declared default
#   omx-modgui-look.sh --list    the looks omx-panel declares, one per line
#
# The looks, their default and the setting's name are omx-panel's
# (schema/modgui-looks.json, `setting`); nothing here lists them. The packages
# ship the default look; a bundle is regenerated in place, as
#   omx-panel modgui --look <look> --installed omx-plugins/<name> --out <bundle>
# for each bundle omx-plugins-lv2 installs in LV2_DIR. An undeclared look exits
# 2 with nothing written. A bundle that fails exits 1, naming it: the bundles
# regenerated before it are put back in the recorded look (the declared default
# when none is recorded) and the setting stays as it was. MOD-UI and
# plugin-hostd read the new GUIs from their next start.
#
# Where (the environment overrides):
#   OMX_MODGUI_LOOK_FILE   the setting, one word  /etc/omx/modgui-look
#   OMX_MODGUI_LOOK_STAMP  what was last applied  /var/lib/omx/modgui-look.applied
#   OMX_PANEL_LOOKS        omx-panel's looks      /usr/share/omx-panel/schema/modgui-looks.json
#   LV2_DIR                the bundles            /usr/lib/lv2
#******************************************************************************

LOOK_FILE=${OMX_MODGUI_LOOK_FILE:-/etc/omx/modgui-look}
STAMP=${OMX_MODGUI_LOOK_STAMP:-/var/lib/omx/modgui-look.applied}
LOOKS=${OMX_PANEL_LOOKS:-/usr/share/omx-panel/schema/modgui-looks.json}
LV2_DIR=${LV2_DIR:-/usr/lib/lv2}
PKG=omx-plugins-lv2
me=omx-modgui-look

die() { echo "$me: $*" >&2; exit "${2:-1}"; }

# setting <field>: a field of the declaration's `setting` (values one per line)
setting() {
	[ -r "$LOOKS" ] || die "omx-panel's looks declaration is not at $LOOKS (an omx-panel with the MOD GUI looks)"
	python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))["setting"][sys.argv[2]]
print("\n".join(s) if isinstance(s, list) else s)' "$LOOKS" "$1" ||
		die "$LOOKS has no setting.$1"
}

recorded() { [ -s "$LOOK_FILE" ] && head -n 1 "$LOOK_FILE"; }
version() { dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null; }
bundles() { dpkg-query -L "$PKG" 2>/dev/null | grep -E "^$LV2_DIR/[^/]+\.lv2\$"; }

# regen <look> <bundle>: one bundle's MOD GUI in <look>
regen() {
	local name
	name=$(basename "$2" .lv2)
	omx-panel modgui --look "$1" --installed "omx-plugins/$name" --out "$2"
}

# set_look <look>: every bundle in <look>, then the setting and the stamp
set_look() {
	local look=$1 values prev b n=0 done=()
	values=$(setting values) || exit 1
	grep -qxF -- "$look" <<<"$values" ||
		die "'$look' is not a MOD GUI look omx-panel declares ($(echo $values))" 2
	prev=$(recorded) || prev=$(setting default) || exit 1
	for b in $(bundles); do
		if ! regen "$look" "$b"; then
			echo "$me: omx-plugins/$(basename "$b" .lv2) could not take the $look look; putting ${#done[@]} bundle(s) back in $prev" >&2
			for d in "${done[@]}"; do regen "$prev" "$d" || echo "$me: $d could not go back to $prev" >&2; done
			exit 1
		fi
		done+=("$b")
		n=$((n + 1))
	done
	mkdir -p "$(dirname "$LOOK_FILE")" "$(dirname "$STAMP")"
	echo "$look" > "$LOOK_FILE.tmp" && mv "$LOOK_FILE.tmp" "$LOOK_FILE"
	echo "$look $(version)" > "$STAMP"
	echo "modgui-look $look: $n bundle(s) regenerated; MOD-UI shows them from its next start"
}

case ${1:-} in
--list) setting values ;;
--show) recorded || setting default ;;
--apply)
	look=$(recorded) || { echo "modgui-look: none recorded, the packages' look stays"; exit 0; }
	[ "$(cat "$STAMP" 2>/dev/null)" = "$look $(version)" ] && { echo "modgui-look $look: unchanged"; exit 0; }
	set_look "$look"
	;;
"" | -*) sed -n '/^#   omx-modgui-look.sh/,/^#$/s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
*) set_look "$1" ;;
esac

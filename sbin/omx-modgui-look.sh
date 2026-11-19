#!/bin/bash
#******************************************************************************
# The MOD GUI look of the OpenMixer plugins, chosen once for the whole Zynthian.
#
#   omx-modgui-look.sh <look>    record <look> and have omx-modgui-sync write
#                                every MOD GUI bundle in it
#   omx-modgui-look.sh --apply   omx-modgui-sync again, in the recorded look,
#                                when omx-plugins-lv2 changed since it was
#                                applied (its plugins come and go); run by apt
#   omx-modgui-look.sh --show    the recorded look, else the declared default
#   omx-modgui-look.sh --list    the looks omx-panel declares, one per line
#
# The looks, their default and the setting's name are omx-panel's
# (schema/modgui-looks.json, `setting`); nothing here lists them. omx-plugins
# ships no MOD GUI (omx-plugins#122): omx-panel's omx-modgui-sync writes one
# bundle per plugin in MODGUI_DIR (omx-modgui-<name>.lv2, marked
# .omx-modgui-sync) in the look named by the first line of the setting's file,
# and writes again a bundle made under another look (omx-panel#140). The
# package's own bundles in /usr/lib/lv2 are never written here. An undeclared
# look exits 2 with nothing written. A sync that fails exits 1 with its reason,
# and the setting is put back as it was. MOD-UI and plugin-hostd read the new
# GUIs from their next start.
#
# Where (the environment overrides):
#   OMX_MODGUI_LOOK_FILE   the setting, one word  /etc/omx/modgui-look
#                          (passed to omx-modgui-sync as MODGUI_LOOK_FILE)
#   OMX_MODGUI_LOOK_STAMP  what was last applied  /var/lib/omx/modgui-look.applied
#   OMX_PANEL_LOOKS        omx-panel's looks      /usr/share/omx-panel/schema/modgui-looks.json
#   MODGUI_DIR             the bundles            omx-modgui-sync's: /usr/local/lib/lv2 for root
#******************************************************************************

LOOK_FILE=${OMX_MODGUI_LOOK_FILE:-/etc/omx/modgui-look}
STAMP=${OMX_MODGUI_LOOK_STAMP:-/var/lib/omx/modgui-look.applied}
LOOKS=${OMX_PANEL_LOOKS:-/usr/share/omx-panel/schema/modgui-looks.json}
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

# run_sync: omx-modgui-sync, reading the look from the setting's file (MODGUI_DIR passes through)
run_sync() { MODGUI_LOOK_FILE=$LOOK_FILE omx-modgui-sync; }

# set_look <look>: record <look>, then omx-modgui-sync; a failed sync puts the setting back
set_look() {
	local look=$1 values prev out
	values=$(setting values) || exit 1
	grep -qxF -- "$look" <<<"$values" ||
		die "'$look' is not a MOD GUI look omx-panel declares ($(echo $values))" 2
	prev=$(recorded) || prev=
	mkdir -p "$(dirname "$LOOK_FILE")" "$(dirname "$STAMP")"
	echo "$look" > "$LOOK_FILE.tmp" && mv "$LOOK_FILE.tmp" "$LOOK_FILE" || die "could not write $LOOK_FILE"
	if ! out=$(run_sync 2>&1); then
		if [ -n "$prev" ]; then echo "$prev" > "$LOOK_FILE"; else rm -f "$LOOK_FILE"; fi
		die "omx-modgui-sync failed, the look stays ${prev:-the default}: $out"
	fi
	echo "$look $(version)" > "$STAMP"
	echo "modgui-look $look: applied by omx-modgui-sync; MOD-UI shows it from its next start"
	echo "$out"
}

case ${1:-} in
--list) setting values ;;
--show) recorded || setting default ;;
--apply)
	look=$(recorded) || {
		# none recorded: omx-modgui-sync in omx-panel's default look, nothing recorded
		[ "$(cat "$STAMP" 2>/dev/null)" = "- $(version)" ] && { echo "modgui-look default: unchanged"; exit 0; }
		out=$(run_sync 2>&1) || die "omx-modgui-sync failed: $out"
		mkdir -p "$(dirname "$STAMP")" && echo "- $(version)" > "$STAMP"
		echo "modgui-look default: applied by omx-modgui-sync"; echo "$out"
		exit 0
	}
	[ "$(cat "$STAMP" 2>/dev/null)" = "$look $(version)" ] && { echo "modgui-look $look: unchanged"; exit 0; }
	set_look "$look"
	;;
"" | -*) sed -n '/^#   omx-modgui-look.sh/,/^#$/s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
*) set_look "$1" ;;
esac

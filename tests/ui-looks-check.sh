#!/bin/bash
#******************************************************************************
# The UI looks in config/ui-looks: each sets the sixteen ZYNTHIAN_UI_COLOR_*
# and the font, in one order; stock.sh is zynthian-ui's own defaults (read from
# the zynthian_gui_config.py given in ZYNTHIAN_GUI_CONFIG); the OpenMixer
# vintage file's pin recomputes from its own lines. sbin/omx-ui-look.sh is run
# on copies of zynthian_envars.sh, so it runs anywhere.
#
#   ZYNTHIAN_GUI_CONFIG=<zynthian-ui>/zyngui/zynthian_gui_config.py tests/ui-looks-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
LOOKS=$HERE/../config/ui-looks
SCRIPT=${SCRIPT:-$HERE/../sbin/omx-ui-look.sh}

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

keys() { sed -n 's/^export \([A-Z0-9_]*\)=.*/\1/p' "$1"; }
val() { sed -n "s/^export $2=\"\([^\"]*\)\"$/\1/p" "$1" | tail -n 1; }

KEYS="ZYNTHIAN_UI_COLOR_BG ZYNTHIAN_UI_COLOR_TX ZYNTHIAN_UI_COLOR_TX_OFF ZYNTHIAN_UI_COLOR_ON ZYNTHIAN_UI_COLOR_OFF
ZYNTHIAN_UI_COLOR_LOW_ON ZYNTHIAN_UI_COLOR_HL ZYNTHIAN_UI_COLOR_ML ZYNTHIAN_UI_COLOR_PANEL_BG ZYNTHIAN_UI_COLOR_PANEL_HL
ZYNTHIAN_UI_COLOR_INFO ZYNTHIAN_UI_COLOR_MIDI ZYNTHIAN_UI_COLOR_ALT ZYNTHIAN_UI_COLOR_ALT2 ZYNTHIAN_UI_COLOR_ERROR
ZYNTHIAN_UI_COLOR_WARN ZYNTHIAN_UI_FONT_FAMILY"
want=$(echo $KEYS | tr ' ' '\n')

# --- the files
for f in stock openmixer-vintage; do
	check "$f.sh sets the sixteen colours and the font, in order" test "$(keys "$LOOKS/$f.sh" 2>/dev/null)" = "$want"
done
check "every look names itself on its first line" \
	bash -c 'for f in "$1"/*.sh; do head -n 1 "$f" | grep -q "^# [A-Za-z]"; done' _ "$LOOKS"

V=$LOOKS/openmixer-vintage.sh
pin=$(sed -n 's/^# pin sha256:\([0-9a-f]\{64\}\).*/\1/p' "$V" 2>/dev/null)
sum=$(sed -n 's/^export \([A-Z0-9_]*\)="\([^"]*\)"$/\1=\2/p' "$V" 2>/dev/null | sha256sum | cut -d' ' -f1)
check "the vintage file's pin recomputes from its lines" test -n "$pin" -a "$pin" = "$sum"

if [ -f "${ZYNTHIAN_GUI_CONFIG:-}" ]; then
	same=1
	for k in $KEYS; do
		d=$(sed -n "s/^[a-z0-9_]* = os.environ.get('$k', \"\([^\"]*\)\").*/\1/p" "$ZYNTHIAN_GUI_CONFIG" | head -n 1)
		[ -n "$d" ] && [ "$d" = "$(val "$LOOKS/stock.sh" "$k")" ] || { same=0; echo "     $k: zynthian-ui '${d}' stock.sh '$(val "$LOOKS/stock.sh" "$k")'"; }
	done
	check "stock.sh is zynthian-ui's own defaults" test $same = 1
else
	bad "stock.sh against zynthian-ui: ZYNTHIAN_GUI_CONFIG names no file"
fi

# --- omx-ui-look.sh on copies of the envars
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
E=$work/zynthian_envars.sh
envars() { # a config with the stock look, one colour changed by hand, and the font unset
	sed '/ZYNTHIAN_UI_FONT_FAMILY/d; s/^export ZYNTHIAN_UI_COLOR_INFO=.*/export ZYNTHIAN_UI_COLOR_INFO="#123456"/' \
		"$LOOKS/stock.sh" > "$E"
	echo 'export ZYNTHIAN_UI_POWER_SAVE_MINUTES="60"' >> "$E"
}
look() { ZYNTHIAN_SYS_DIR=$HERE/.. bash "$SCRIPT" "$@" > "$work/out" 2>&1; }

envars
look --keep-changed openmixer-vintage "$E"
check "--keep-changed applies the look where the value is stock or unset" \
	test -n "$(val "$V" ZYNTHIAN_UI_COLOR_BG)" -a "$(val "$E" ZYNTHIAN_UI_COLOR_BG)" = "$(val "$V" ZYNTHIAN_UI_COLOR_BG)" -a "$(val "$E" ZYNTHIAN_UI_FONT_FAMILY)" = "$(val "$V" ZYNTHIAN_UI_FONT_FAMILY)"
check "--keep-changed leaves a colour changed by hand" test "$(val "$E" ZYNTHIAN_UI_COLOR_INFO)" = "#123456"
check "--keep-changed names the colour it left" grep -q "ZYNTHIAN_UI_COLOR_INFO" "$work/out"
check "other settings stay" grep -qx 'export ZYNTHIAN_UI_POWER_SAVE_MINUTES="60"' "$E"
cp "$E" "$work/once"
look --keep-changed openmixer-vintage "$E"
check "a second run changes nothing" cmp -s "$E" "$work/once"

look stock "$E"
same=1
for k in $KEYS; do [ -n "$(val "$E" "$k")" ] && [ "$(val "$E" "$k")" = "$(val "$LOOKS/stock.sh" "$k")" ] || same=0; done
check "a look chosen by name sets all seventeen, a hand change included" test $same = 1
check "each key once" bash -c 'for k in $2; do [ "$(grep -c "^export $k=" "$1")" = 1 ] || exit 1; done' _ "$E" "$KEYS"

envars; cp "$E" "$work/before"
look no-such-look "$E"; rc=$?
check "an unknown look is refused by name, exit 2, nothing written" \
	test $rc = 2 -a "$(grep -c no-such-look "$work/out")" -ge 1 -a -z "$(cmp "$E" "$work/before")"
look; rc=$?
check "no look: usage, exit 2" test $rc = 2

[ $fails = 0 ] && echo "ui-looks: all checks pass" || echo "ui-looks: $fails failed"
[ $fails = 0 ]

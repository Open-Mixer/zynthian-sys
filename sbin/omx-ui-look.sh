#!/bin/bash
#******************************************************************************
# Set Zynthian's UI look: the ZYNTHIAN_UI_COLOR_* and the font of one file in
# config/ui-looks, written into zynthian_envars.sh. The other settings stay as
# they are. The UI reads them when it starts.
#
#   omx-ui-look.sh [--keep-changed] <look> [zynthian_envars.sh]
#
# <look> is a file name in config/ui-looks without .sh (stock,
# openmixer-vintage). --keep-changed sets a key only where it is unset or still
# holds the stock value, and names each key it leaves: the recipe uses it so
# colours chosen by hand survive. An unknown look is refused by name, exit 2.
#******************************************************************************

ZYNTHIAN_SYS_DIR=${ZYNTHIAN_SYS_DIR:-/zynthian/zynthian-sys}
ZYNTHIAN_CONFIG_DIR=${ZYNTHIAN_CONFIG_DIR:-/zynthian/config}
LOOKS=$ZYNTHIAN_SYS_DIR/config/ui-looks

keep=0
if [ "${1:-}" = --keep-changed ]; then keep=1; shift; fi
name=${1:-}
ENVARS=${2:-$ZYNTHIAN_CONFIG_DIR/zynthian_envars.sh}

if [ -z "$name" ]; then
	echo "usage: omx-ui-look.sh [--keep-changed] <look> [zynthian_envars.sh]; looks: $(cd "$LOOKS" 2>/dev/null && ls *.sh | sed 's/\.sh$//' | tr '\n' ' ')" >&2
	exit 2
fi
LOOK=$LOOKS/$name.sh
if [ ! -f "$LOOK" ]; then
	echo "omx-ui-look.sh: no look named '$name' in $LOOKS; nothing written" >&2
	exit 2
fi
if [ ! -f "$ENVARS" ]; then
	echo "omx-ui-look.sh: no $ENVARS; nothing written" >&2
	exit 2
fi

# The value of an exported variable in a file, quotes removed (the last line wins)
envar_get() {
	sed -n "s/^export $1=[\"']\{0,1\}\([^\"']*\).*/\1/p" "$2" | tail -n 1
}

tmp=$(mktemp "$ENVARS.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
cp -p "$ENVARS" "$tmp"
set_n=0
for key in $(sed -n 's/^export \([A-Z0-9_]*\)=.*/\1/p' "$LOOK"); do
	want=$(envar_get "$key" "$LOOK")
	have=$(envar_get "$key" "$tmp")
	if [ $keep = 1 ] && [ -n "$have" ] && [ "$have" != "$(envar_get "$key" "$LOOKS/stock.sh")" ] && [ "$have" != "$want" ]; then
		echo "kept $key=$have (changed by hand)"
		continue
	fi
	[ "$have" = "$want" ] && continue
	if grep -q "^export $key=" "$tmp"; then
		sed -i "/^export $key=/d" "$tmp"
	fi
	echo "export $key=\"$want\"" >>"$tmp"
	set_n=$((set_n + 1))
done
if [ $set_n -gt 0 ]; then
	mv "$tmp" "$ENVARS"
	trap - EXIT
fi
echo "look $name: $set_n setting(s) written to $ENVARS"

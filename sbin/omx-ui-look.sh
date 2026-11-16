#!/bin/bash
#******************************************************************************
# Set Zynthian's UI look: the ZYNTHIAN_UI_COLOR_* and the font of one file in
# config/ui-looks, written into zynthian_envars.sh. The other settings stay as
# they are. The UI reads them when it starts.
#
#   omx-ui-look.sh [--keep-changed] <look> [zynthian_envars.sh]
#   omx-ui-look.sh --complete [zynthian_envars.sh]
#
# <look> is a file name in config/ui-looks without .sh (stock,
# openmixer-vintage). --keep-changed sets a key only where it is unset or still
# holds the stock value, and names each key it leaves: the recipe uses it so
# colours chosen by hand survive. An unknown look is refused by name, exit 2.
#
# --complete adds the keys a look gained since it was written (the main menu
# grid's ZYNTHIAN_UI_COLOR_GRID_*), from the look the file holds: the one
# matching the most of its keys, more than three quarters of those it shares.
# It sets only keys the file lacks, and on a mix of looks sets none and says
# so. The recipe runs it on every run.
#******************************************************************************

ZYNTHIAN_SYS_DIR=${ZYNTHIAN_SYS_DIR:-/zynthian/zynthian-sys}
ZYNTHIAN_CONFIG_DIR=${ZYNTHIAN_CONFIG_DIR:-/zynthian/config}
LOOKS=$ZYNTHIAN_SYS_DIR/config/ui-looks

keep=0 complete=0
case ${1:-} in
--keep-changed) keep=1; shift ;;
--complete) complete=1; shift; set -- "" "$@" ;;
esac
name=${1:-}
ENVARS=${2:-$ZYNTHIAN_CONFIG_DIR/zynthian_envars.sh}

if [ -z "$name" ] && [ $complete = 0 ]; then
	echo "usage: omx-ui-look.sh [--keep-changed] <look> [zynthian_envars.sh]; looks: $(cd "$LOOKS" 2>/dev/null && ls *.sh | sed 's/\.sh$//' | tr '\n' ' ')" >&2
	exit 2
fi
LOOK=$LOOKS/$name.sh
if [ $complete = 0 ] && [ ! -f "$LOOK" ]; then
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

if [ $complete = 1 ]; then
	best= best_n=0 second_n=0 best_shared=0
	for f in "$LOOKS"/*.sh; do
		n=0 shared=0
		for key in $(sed -n 's/^export \([A-Z0-9_]*\)=.*/\1/p' "$f"); do
			have=$(envar_get "$key" "$ENVARS")
			[ -n "$have" ] || continue
			shared=$((shared + 1))
			[ "$have" = "$(envar_get "$key" "$f")" ] && n=$((n + 1))
		done
		if [ $n -gt $best_n ]; then second_n=$best_n best=$f best_n=$n best_shared=$shared
		elif [ $n -gt $second_n ]; then second_n=$n; fi
	done
	if [ -z "$best" ] || [ $best_n = $second_n ] || [ $((best_n * 4)) -le $((best_shared * 3)) ]; then
		echo "complete: no look held ($best_n of $best_shared keys at most); nothing added"
		exit 0
	fi
	name=$(basename "$best" .sh) added=0
	for key in $(sed -n 's/^export \([A-Z0-9_]*\)=.*/\1/p' "$best"); do
		grep -q "^export $key=" "$ENVARS" && continue
		echo "export $key=\"$(envar_get "$key" "$best")\"" >>"$ENVARS"
		added=$((added + 1))
	done
	echo "complete $name: $added setting(s) added to $ENVARS"
	exit 0
fi

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

#!/bin/bash
#******************************************************************************
# The UI looks in config/ui-looks are GENERATED from omx-panel's skins
# (docs/ui-looks.md; omx-panel docs/looks-widget-library-and-skin.md section
# 11): each config/ui-looks/<skin id>.sh is byte for byte what
# `omx-panel skin --library tk <skin id>` prints, every skin omx-panel ships
# with a tk file has its look here and every look here its skin. A hand edit
# is red; so is a skin changed in omx-panel and not generated here again.
#
#   tests/ui-looks-generated-check.sh            check
#   tests/ui-looks-generated-check.sh --write    write every skin's look (the one way a look changes)
#
# OMX_PANEL names the omx-panel command (default: omx-panel on the PATH), e.g.
# OMX_PANEL="node ../omx-panel/bin/omx-panel.mjs".
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
LOOKS=$HERE/../config/ui-looks
read -r -a PANEL <<<"${OMX_PANEL:-omx-panel}"

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }

write=0
case "${1:-}" in
--write) write=1 ;;
"") ;;
*) echo "usage: ui-looks-generated-check.sh [--write]" >&2; exit 2 ;;
esac

if ! ids=$("${PANEL[@]}" skin --library tk --list 2>"${TMPDIR:-/tmp}/ui-looks-gen.$$"); then
	bad "omx-panel (${PANEL[*]}) renders no skin: $(head -n 2 "${TMPDIR:-/tmp}/ui-looks-gen.$$" | tr '\n' ' ')(needs omx-panel's skin --library tk)"
	rm -f "${TMPDIR:-/tmp}/ui-looks-gen.$$"
	echo "ui-looks-generated: $fails failed"
	exit 1
fi
rm -f "${TMPDIR:-/tmp}/ui-looks-gen.$$"
[ -n "$ids" ] || bad "omx-panel ships no skin with a tk file"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for id in $ids; do
	if ! "${PANEL[@]}" skin --library tk "$id" >"$work/$id.sh" 2>"$work/$id.err"; then
		bad "omx-panel refuses its own skin $id: $(tr '\n' ' ' <"$work/$id.err")"
		continue
	fi
	if [ $write = 1 ]; then
		cmp -s "$work/$id.sh" "$LOOKS/$id.sh" && ok "$id.sh is the generator's already" || {
			cp "$work/$id.sh" "$LOOKS/$id.sh" && ok "$id.sh written from omx-panel's skin $id"
		}
	elif [ ! -f "$LOOKS/$id.sh" ]; then
		bad "omx-panel's skin $id has no look here: config/ui-looks/$id.sh (run with --write)"
	elif cmp -s "$work/$id.sh" "$LOOKS/$id.sh"; then
		ok "$id.sh is what omx-panel generates from its skin $id"
	else
		bad "$id.sh is not what omx-panel generates from its skin $id (a hand edit, or the skin changed: run with --write)"
		diff "$work/$id.sh" "$LOOKS/$id.sh" | head -n 8 | sed 's/^/     /'
	fi
done
for f in "$LOOKS"/*.sh; do
	id=$(basename "$f" .sh)
	echo "$ids" | grep -qx "$id" || bad "config/ui-looks/$id.sh has no skin in omx-panel (remove it with git rm, or add the skin there)"
done

[ $fails = 0 ] && echo "ui-looks-generated: all checks pass" || echo "ui-looks-generated: $fails failed"
[ $fails = 0 ]

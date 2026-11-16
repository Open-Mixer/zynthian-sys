#!/bin/bash
#******************************************************************************
# Zynthian's plugin directories in plugin-hostd's settings, the one place they
# are written (plugin-qualify#9):
#
#   omx-search-paths.sh
#
# - lv2_path in $PHD_CONF is Zynthian's LV2_PATH (zynthian_envars.sh, written
#   by update_zynthian_sys.sh), and clap_path its CLAP directories: the
#   packages' /usr/lib/clap and /usr/local/lib/clap, where the plugins built
#   on the device (Surge XT) go. The settings file is over the environment, so
#   every plugin-hostd started with it searches exactly these.
# - plugin-qualify-sync scans what `plugin-hostd --search-path -c <file>`
#   prints, so hostd_conf in $QUALIFY_CONF names $PHD_CONF. config/qualify.conf
#   sets no search path of its own, and this script does not touch one.
#
# Safe to run any number of times: a run that finds everything in place
# changes nothing. Run by install_openmixer.sh and before every
# plugin-qualify-sync (its zynthian.conf drop-in), so an upgrade of the
# packages alone is followed too. Each change is one line on stdout.
#******************************************************************************

ZYNTHIAN_CONFIG_DIR=${ZYNTHIAN_CONFIG_DIR:-/zynthian/config}
PHD_CONF=${PHD_CONF:-$ZYNTHIAN_CONFIG_DIR/plugin-hostd.conf}
QUALIFY_CONF=${QUALIFY_CONF:-/etc/omx/qualify.conf}
ENVARS=${ENVARS:-$ZYNTHIAN_CONFIG_DIR/zynthian_envars.sh}
ZYNTHIAN_CLAP_PATH=${ZYNTHIAN_CLAP_PATH:-/usr/local/lib/clap:/usr/lib/clap}

[ -n "$LV2_PATH" ] || LV2_PATH=$(sed -n "s/^export LV2_PATH=[\"']\{0,1\}\([^\"']*\).*/\1/p" "$ENVARS" 2>/dev/null | tail -n 1)

# The value of a key in a "key value" file, the last line winning
conf_get() {
	sed -n "s/^$2[[:space:]]\{1,\}//p" "$1" | tail -n 1
}
conf_set() {
	if grep -q "^$2[[:space:]]" "$1"; then
		sed -i "s|^$2[[:space:]].*|$2 $3|" "$1"
	else
		printf '%s %s\n' "$2" "$3" >>"$1"
	fi
}
# key's value in file set to value, saying so when it changes
put() {
	local old
	old=$(conf_get "$1" "$2")
	[ "$old" = "$3" ] && return 0
	conf_set "$1" "$2" "$3"
	echo "$2 ${old:-unset} -> $3 in $1"
}
# the directories of the list $2 that the list $1 lacks, colon-separated
missing_dirs() {
	local d out=
	local IFS=:
	for d in $2; do
		[ -n "$d" ] || continue
		case ":$1:$out:" in *":$d:"*) ;; *) out=${out:+$out:}$d ;; esac
	done
	echo "$out"
}

# two lists joined with a colon, either of them possibly empty
joined() { echo "$1${2:+${1:+:}$2}"; }

[ -f "$PHD_CONF" ] || { echo "no $PHD_CONF: nothing to write" >&2; exit 0; }
[ -n "$LV2_PATH" ] || { echo "no LV2_PATH in $ENVARS: $PHD_CONF left as it is" >&2; exit 1; }

# lv2_path is Zynthian's LV2_PATH; clap_path starts with Zynthian's CLAP
# directories and keeps any other one it holds (plugin-hostd has no clap_extra)
put "$PHD_CONF" lv2_path "$LV2_PATH"
put "$PHD_CONF" clap_path "$(joined "$ZYNTHIAN_CLAP_PATH" "$(missing_dirs "$ZYNTHIAN_CLAP_PATH" "$(conf_get "$PHD_CONF" clap_path)")")"

[ -f "$QUALIFY_CONF" ] || exit 0
put "$QUALIFY_CONF" hostd_conf "$PHD_CONF"
exit 0

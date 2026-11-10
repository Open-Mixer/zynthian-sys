#!/bin/bash
#******************************************************************************
# sbin/omx-search-paths.sh writes Zynthian's plugin directories into
# plugin-hostd's settings, and moves the search path lines out of
# qualify.conf once plugin-qualify reads them from plugin-hostd (0.20.3 and
# later); with an older plugin-qualify, qualify.conf holds the same lists.
# Run on copies of the files, with the installed plugin-qualify's version
# given, so it runs anywhere.
#
#   tests/omx-search-paths-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${SCRIPT:-$HERE/../sbin/omx-search-paths.sh}
CONFIG=$HERE/../config

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
conf() { sed -n "s/^$2[[:space:]]\{1,\}//p" "$1" | tail -n 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
LV2=/usr/lib/lv2:/usr/lib/aarch64-linux-gnu/lv2:/usr/local/lib/lv2:/zynthian/zynthian-plugins/lv2:/zynthian/zynthian-my-data/plugins/lv2
CLAP=/usr/local/lib/clap:/usr/lib/clap

# a device: Zynthian's envars, plugin-hostd.conf as installed, and qualify.conf as the Pi had it
setup() {
	rm -rf "$work/d"; mkdir -p "$work/d"
	echo "export LV2_PATH=\"$LV2\"" >"$work/d/zynthian_envars.sh"
	cp "$CONFIG/plugin-hostd.conf" "$work/d/plugin-hostd.conf"
	cat >"$work/d/qualify.conf" <<-EOF
	# the device's own
	lv2_path $LV2:/zynthian/zynthian-data/presets/lv2
	lv2_extra /zynthian/zynthian-my-data/plugins/lv2:/opt/mine/lv2
	clap_path /usr/lib/clap
	clap_extra /opt/mine/clap
	pin_file /var/lib/omx/qualified.pins
	hostd_port 0
	EOF
}
run() {
	env -u LV2_PATH ZYNTHIAN_CONFIG_DIR="$work/d" QUALIFY_CONF="$work/d/qualify.conf" QUALIFY_VERSION="$1" bash "$SCRIPT"
}
active_moved() { grep -E '^(lv2_path|lv2_extra|clap_path|clap_extra)([[:space:]]|$)' "$work/d/qualify.conf"; }

# plugin-qualify 0.20.3: the lines move to plugin-hostd.conf
setup
out=$(run 0.20.3-1); rc=$?
check "the run succeeds ($rc): $out" test "$rc" = 0
check "plugin-hostd.conf: lv2_path is Zynthian's LV2_PATH" test "$(conf "$work/d/plugin-hostd.conf" lv2_path)" = "$LV2"
check "plugin-hostd.conf: clap_path is Zynthian's CLAP directories, then the one clap_extra added" \
	test "$(conf "$work/d/plugin-hostd.conf" clap_path)" = "$CLAP:/opt/mine/clap"
check "plugin-hostd.conf: lv2_extra holds what qualify.conf named and LV2_PATH lacks ($(conf "$work/d/plugin-hostd.conf" lv2_extra))" \
	test "$(conf "$work/d/plugin-hostd.conf" lv2_extra)" = /zynthian/zynthian-data/presets/lv2:/opt/mine/lv2
check "qualify.conf: no line plugin-qualify 0.20.3 refuses is left: $(active_moved)" test -z "$(active_moved)"
check "qualify.conf: hostd_conf names plugin-hostd.conf" test "$(conf "$work/d/qualify.conf" hostd_conf)" = "$work/d/plugin-hostd.conf"
check "qualify.conf: each moved line is kept as a comment saying where it went" \
	test "$(grep -c "^# moved to $work/d/plugin-hostd.conf" "$work/d/qualify.conf")" = 4
check "qualify.conf: its other settings stay" test "$(conf "$work/d/qualify.conf" pin_file)" = /var/lib/omx/qualified.pins
check "plugin-hostd.conf: its other settings stay" test "$(conf "$work/d/plugin-hostd.conf" lv2_worker)" = omx-clap-host
cp "$work/d/plugin-hostd.conf" "$work/phd.1"; cp "$work/d/qualify.conf" "$work/q.1"
out=$(run 0.20.3-1)
check "a second run changes nothing and says nothing: $out" \
	sh -c "[ -z '$out' ] && cmp -s '$work/phd.1' '$work/d/plugin-hostd.conf' && cmp -s '$work/q.1' '$work/d/qualify.conf'"

# plugin-qualify 0.20.2: qualify.conf keeps its own lists, the same as plugin-hostd's
setup
run 0.20.2-1 >/dev/null
check "older plugin-qualify: lv2_path is plugin-hostd's" test "$(conf "$work/d/qualify.conf" lv2_path)" = "$(conf "$work/d/plugin-hostd.conf" lv2_path)"
check "older plugin-qualify: no lv2_extra plugin-hostd does not search" test -z "$(conf "$work/d/qualify.conf" lv2_extra)"
check "older plugin-qualify: clap_path is plugin-hostd's, clap_extra empty" \
	sh -c "[ '$(conf "$work/d/qualify.conf" clap_path)' = '$(conf "$work/d/plugin-hostd.conf" clap_path)' ] && [ -z '$(conf "$work/d/qualify.conf" clap_extra)' ]"
check "older plugin-qualify: no hostd_conf, a key it would refuse" test -z "$(grep '^hostd_conf' "$work/d/qualify.conf")"

# then plugin-qualify 0.20.3 arrives: the next run moves the lines
run 0.20.3-1 >/dev/null
check "after the upgrade the lines move: $(active_moved)" test -z "$(active_moved)"

# no LV2_PATH: nothing written
setup
cp "$work/d/plugin-hostd.conf" "$work/phd.0"
: >"$work/d/zynthian_envars.sh"
run 0.20.3-1 >/dev/null 2>&1; rc=$?
check "no LV2_PATH: exit 1 and plugin-hostd.conf untouched ($rc)" sh -c "[ $rc = 1 ] && cmp -s '$work/phd.0' '$work/d/plugin-hostd.conf'"

# the template qualify.conf names no search path: the script is the one writer
check "config/qualify.conf sets no search path key" sh -c "! grep -qE '^(lv2_path|lv2_extra|clap_path|clap_extra)[[:space:]]' '$CONFIG/qualify.conf'"

[ "$fails" = 0 ] && echo "omx-search-paths: all checks passed" || echo "omx-search-paths: $fails checks failed"
exit "$fails"

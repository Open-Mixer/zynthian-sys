#!/bin/bash
#******************************************************************************
# scripts/recipes/install_openmixer.sh on a device, with the package tools
# stubbed: a fresh install gets the defaults, and a config that already exists
# is not rewritten to match them. The recipe does not change a plugin-hostd.conf
# or a zynthian_envars.sh it finds; it does not rewrite lv2_worker; it enables
# the qualification sync units whenever plugin-qualify is installed.
#
# Container only (it writes /etc/tmpfiles.d), as root:
#
#   podman run --rm -v $PWD:/src:ro debian:trixie bash -c \
#     'cp -a /src /w && /w/tests/install-openmixer-check.sh'
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
SYS=$HERE/..
[ -f /run/.containerenv ] || [ -f /.dockerenv ] || [ -n "$OMX_CHECK_IN_CONTAINER" ] ||
	{ echo "container only: it writes /etc/tmpfiles.d"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run it as root"; exit 2; }

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
conf() { sed -n "s/^$2[[:space:]]\{1,\}//p" "$1" | tail -n 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" /var/lib/omx
stub() { printf '#!/bin/bash\n%s\n' "$2" >"$work/bin/$1"; chmod +x "$work/bin/$1"; }
stub dpkg 'case "$1" in --print-architecture) echo amd64 ;; esac'
stub dpkg-query 'case "$*" in *Status*) printf "install ok installed" ;; *) printf 1.0 ;; esac'
stub apt-get 'exit 0'
stub plugin-hostd 'exit 0'
stub omx-clap-scan 'exit 0'
stub systemd-tmpfiles 'exit 0'
stub systemctl 'echo "$*" >>"$SYSTEMCTL_LOG"; case "$1" in is-enabled) echo disabled; exit 1 ;; esac'

recipe() {
	PATH="$work/bin:$PATH" SYSTEMCTL_LOG="$work/systemctl.log" ZYNTHIAN_SYS_DIR=$SYS ZYNTHIAN_CONFIG_DIR=$work/config \
		QUALIFY_CONF=$work/qualify.conf SYSTEMD_UNIT_DIR=$work/units "$SYS/scripts/recipes/install_openmixer.sh" \
		>"$work/recipe.log" 2>&1
}
fresh() {
	rm -rf "$work/config" "$work/units" "$work/qualify.conf" "$work/systemctl.log"
	mkdir -p "$work/config" "$work/units"
}

echo "== a fresh install: no config yet"
fresh
recipe
check "plugin-hostd.conf is installed from config/plugin-hostd.conf" cmp -s "$SYS/config/plugin-hostd.conf" "$work/config/plugin-hostd.conf"
check "the packages step is marked done" grep -qx packages "$work/config/openmixer-defaults"

echo "== a config that already exists is left as it is"
fresh
printf 'export ZYNTHIAN_MODHOST_BACKEND="jack_load"\nexport LV2_PATH="/usr/lib/lv2"\n' >"$work/config/zynthian_envars.sh"
printf 'lv2_worker auto\nrequire_pins 0\nstate_root /run/plugin-hostd\n' >"$work/config/plugin-hostd.conf"
cp "$work/config/plugin-hostd.conf" "$work/phd.before"
recipe
check "lv2_worker auto is not rewritten" test "$(conf "$work/config/plugin-hostd.conf" lv2_worker)" = auto
check "require_pins 0 is not changed to 1" test "$(conf "$work/config/plugin-hostd.conf" require_pins)" = 0
check "no key is added to plugin-hostd.conf (only the plugin directories, written by omx-search-paths.sh)" \
	test "$(grep -c -e '^pin_mode' -e '^pin_file' -e '^qualification_dir' -e '^descriptor_dir' "$work/config/plugin-hostd.conf")" = 0
check "ZYNTHIAN_PLUGIN_ENGINE is not added to zynthian_envars.sh" bash -c '! grep -q ZYNTHIAN_PLUGIN_ENGINE "$1"' _ "$work/config/zynthian_envars.sh"
check "ZYNTHIAN_MODHOST_BACKEND is not rewritten" grep -qx 'export ZYNTHIAN_MODHOST_BACKEND="jack_load"' "$work/config/zynthian_envars.sh"
check "the envars and hostd-conf steps are not recorded" bash -c '! grep -q -e envars -e hostd-conf "$1"' _ "$work/config/openmixer-defaults"
check "the report says no restart is pending" bash -c '! grep -q "were not restarted" "$1"' _ "$work/recipe.log"

echo "== plugin-qualify installed: the sync units are enabled"
fresh
recipe
check "plugin-qualify-sync.timer is enabled" grep -qx 'enable plugin-qualify-sync.timer' "$work/systemctl.log"
check "plugin-qualify-sync.path is enabled" grep -qx 'enable plugin-qualify-sync.path' "$work/systemctl.log"
check "no message about a plugin-qualify with no sync" bash -c '! grep -q "no qualification sync" "$1"' _ "$work/recipe.log"
check "the step is marked done" grep -qx qualify-sync "$work/config/openmixer-defaults"

[ "$fails" = 0 ] && echo "install-openmixer: all checks passed" || echo "install-openmixer: $fails checks failed"
exit "$fails"

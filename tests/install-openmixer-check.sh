#!/bin/bash
#******************************************************************************
# scripts/recipes/install_openmixer.sh on a device, with the package tools
# stubbed: a fresh install gets the defaults, and a config that already exists
# is not rewritten to match them. The recipe adds ZYNTHIAN_PLUGIN_ENGINE and
# ZYNTHIAN_MODHOST_BACKEND to a zynthian_envars.sh it finds (a stock device);
# it does not change a plugin-hostd.conf it finds, nor rewrite lv2_worker; it enables
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
stub dpkg-query 'case "$*" in *Status*) printf "install ok installed" ;; *jackd2) printf "${JACKD2_VERSION:-1.0}" ;; *) printf 1.0 ;; esac'
stub apt-get 'echo "$*" >>"$APT_LOG"; exit 0'
stub plugin-hostd 'exit 0'
stub omx-clap-scan 'exit 0'
stub systemd-tmpfiles 'exit 0'
stub systemctl 'echo "$*" >>"$SYSTEMCTL_LOG"; case "$1" in is-enabled) echo disabled; exit 1 ;; esac'

recipe() {
	PATH="$work/bin:$PATH" SYSTEMCTL_LOG="$work/systemctl.log" APT_LOG="$work/apt.log" APT_PIN="$work/apt-pin" \
		ZYNTHIAN_SYS_DIR=$SYS ZYNTHIAN_CONFIG_DIR=$work/config \
		QUALIFY_CONF=$work/qualify.conf "$SYS/scripts/recipes/install_openmixer.sh" \
		>"$work/recipe.log" 2>&1
}
fresh() {
	rm -rf "$work/config" "$work/qualify.conf" "$work/systemctl.log" "$work/apt.log" "$work/apt-pin"
	mkdir -p "$work/config"
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
check "ZYNTHIAN_PLUGIN_ENGINE is added to the existing zynthian_envars.sh" grep -qx 'export ZYNTHIAN_PLUGIN_ENGINE="plugin-hostd"' "$work/config/zynthian_envars.sh"
check "ZYNTHIAN_MODHOST_BACKEND is set to plugin-hostd in it" grep -qx 'export ZYNTHIAN_MODHOST_BACKEND="plugin-hostd"' "$work/config/zynthian_envars.sh"
check "the other lines of zynthian_envars.sh stay" grep -qx 'export LV2_PATH="/usr/lib/lv2"' "$work/config/zynthian_envars.sh"
check "the envars step is recorded" grep -qx envars "$work/config/openmixer-defaults"
check "the report says mod-host was not restarted" grep -q "were not restarted" "$work/recipe.log"

echo "== plugin-qualify installed: the sync units are enabled"
fresh
recipe
check "plugin-qualify-sync.timer is enabled" grep -qx 'enable plugin-qualify-sync.timer' "$work/systemctl.log"
check "plugin-qualify-sync.path is enabled" grep -qx 'enable plugin-qualify-sync.path' "$work/systemctl.log"
check "no message about a plugin-qualify with no sync" bash -c '! grep -q "no qualification sync" "$1"' _ "$work/recipe.log"
check "the step is marked done" grep -qx qualify-sync "$work/config/openmixer-defaults"

echo "== jackd2: the apt pin, and Debian's jackd2 replaced by the channel's"
fresh
recipe
check "the apt pin is installed from etc/apt/preferences.d/openmixer-jackd2" cmp -s "$SYS/etc/apt/preferences.d/openmixer-jackd2" "$work/apt-pin"
check "the pin prefers the OpenMixer channel's jackd2 and libjack" \
	grep -qx 'Pin: release o=OpenMixer' "$work/apt-pin"
check "Debian's jackd2 (no +omx) is replaced from the channel" grep -q 'install jackd2 libjack-jackd2-0$' "$work/apt.log"
check "a channel with no fixed jackd2 yet is said, not hidden" grep -q "serves no jackd2 with the metadata fix yet" "$work/recipe.log"
fresh
JACKD2_VERSION=1.9.22~dfsg-4+omx1 recipe
check "the channel's jackd2 (+omx) is not installed again" bash -c '! grep -qs "install jackd2" "$1"' _ "$work/apt.log"
echo junk >"$work/apt-pin"
recipe
check "a changed apt pin is put back" cmp -s "$SYS/etc/apt/preferences.d/openmixer-jackd2" "$work/apt-pin"

[ "$fails" = 0 ] && echo "install-openmixer: all checks passed" || echo "install-openmixer: $fails checks failed"
exit "$fails"

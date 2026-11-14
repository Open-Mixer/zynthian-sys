#!/bin/bash
#******************************************************************************
# The cmdline.txt update_zynthian_sys.sh writes (configure_rbpi_boot) enables
# the memory cgroup controller, so services can carry memory limits: it ends
# with cgroup_enable=memory, after any cgroup_disable=memory put before it, and
# carries no cgroup_disable=memory of its own. The function is run over
# throwaway copies of config.txt and cmdline.txt. Its effect on a Pi needs a
# reboot; this checks only the file.
#
#   tests/boot-cmdline-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../scripts/update_zynthian_sys.sh

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

fn=$(sed -n '/^function configure_rbpi_boot()/,/^}/p' "$SCRIPT")
check "update_zynthian_sys.sh defines configure_rbpi_boot" test -n "$fn"

w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT

# cmdline.txt as configure_rbpi_boot writes it, from an earlier cmdline.txt and the envars given
generate() {
	printf '%s\n' "$1" >"$w/cmdline.txt"
	: >"$w/config.txt"
	shift
	(
		eval "$fn"
		BOOT_CONFIG_FPATH=$w/config.txt CMDLINE_CONFIG_FPATH=$w/cmdline.txt ZYNTHIAN_SYS_DIR=$HERE/.. \
			ZYNTHIAN_KIT_VERSION= NO_ZYNTHIAN_UPDATE=
		for kv in "$@"; do export "${kv?}"; done
		configure_rbpi_boot
	) >/dev/null 2>&1
	cat "$w/cmdline.txt"
}
words() { tr ' ' '\n' <<<"$1" | grep -c -x "$2"; }
last() { awk '{print $NF}' <<<"$1"; }

earlier="console=serial0,115200 console=tty1 root=PARTUUID=0a1b2c3d-02 rootfstype=ext4 fsck.repair=yes rootwait cgroup_disable=memory"
for case in "BOOTLOG=0" "BOOTLOG=1" "BOOTLOG=0 BOOT_SPLASH_ENABLED=1 ZYNTHIAN_LIMIT_USB_SPEED=1" \
	"BOOTLOG=0 ZYNTHIAN_CUSTOM_BOOT_CMDLINE=cgroup_disable=memory" "BOOTLOG=0 ZYNTHIAN_DISABLE_OTG=1"; do
	# shellcheck disable=SC2086 # one word per envar
	out=$(generate "$earlier" $case)
	echo "   | $case: $out"
	check "$case: the root of the earlier cmdline.txt is kept" test "$(words "$out" root=PARTUUID=0a1b2c3d-02)" = 1
	check "$case: cgroup_enable=memory, once" test "$(words "$out" cgroup_enable=memory)" = 1
	check "$case: it is the last word" test "$(last "$out")" = cgroup_enable=memory
	check "$case: no cgroup_disable=memory" test "$(words "$out" cgroup_disable=memory)" = 0
done

[ "$fails" = 0 ] && echo "-- all checks passed" || echo "-- $fails checks failed"
[ "$fails" = 0 ]

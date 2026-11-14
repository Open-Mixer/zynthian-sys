#!/bin/bash
#******************************************************************************
# The packages config/openmixer-packages lists install from the channel and
# carry what zynthian-ui imports at its start: plugin-hostd's Python client
# (plugin_hostd_protocol) and omx-contract's readers (omx_contract.scale,
# omx_contract.catalog). The recipe and the install check read that one
# list. The channel is added as the recipe adds it: the openmixer-release
# that scripts/omx-fetch-release.sh checks against the pinned archive key.
#
# Container only: it installs packages. Needs debian:trixie, root, gnupg,
# gpgv, curl and ca-certificates:
#
#   tests/omx-packages-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
LIST=$HERE/../config/openmixer-packages

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

[ -f /run/.containerenv ] || [ -f /.dockerenv ] || [ -n "$OMX_CHECK_IN_CONTAINER" ] ||
	{ echo "container only: it installs packages"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run it as root"; exit 2; }

for f in scripts/recipes/install_openmixer.sh tests/default-install-check.sh; do
	check "$f reads config/openmixer-packages" grep -q 'config/openmixer-packages' "$HERE/../$f"
	for p in $(sed 's/#.*//' "$LIST"); do
		check "$f names no $p in a list of its own" bash -c "! grep -Eq '^PACKAGES=.*[\" ]$p([\" ]|\$)' '$HERE/../$f'"
	done
done

packages=$(sed 's/#.*//' "$LIST" | xargs)
w=$(mktemp -d)
chmod 755 "$w"
if env -u BASE_URL -u SUITE -u ARCHIVE_KEYS -u FETCH "$HERE/../scripts/omx-fetch-release.sh" "$w/openmixer-release.deb" &&
	apt-get install -y -qq --no-install-recommends "$w/openmixer-release.deb" >/dev/null && apt-get update -qq; then
	ok "the channel is added (openmixer-release checked against the pinned key)"
else
	bad "the channel is added (openmixer-release checked against the pinned key)"
	echo "-- 0/0 further checks: no channel"; exit 1
fi
# python3 is on every Zynthian; the list must bring the rest
apt-get install -y -qq --no-install-recommends python3 >/dev/null
# shellcheck disable=SC2086 # one word per package
check "the list installs: $packages" apt-get install -y -qq --no-install-recommends $packages
dpkg-query -W $packages python3-plugin-hostd-protocol 2>/dev/null | sed 's/^/   | /'
check "python3 -c 'import plugin_hostd_protocol'" python3 -c 'import plugin_hostd_protocol'
check "its Protocol reads the installed table" python3 -c 'import plugin_hostd_protocol; plugin_hostd_protocol.Protocol()'
check "python3 -c 'import omx_contract.scale, omx_contract.catalog'" python3 -c 'import omx_contract.scale, omx_contract.catalog'

[ "$fails" = 0 ] && echo "-- all checks passed" || echo "-- $fails checks failed"
[ "$fails" = 0 ]

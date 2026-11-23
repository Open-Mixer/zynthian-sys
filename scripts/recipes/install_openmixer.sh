#!/bin/bash
#******************************************************************************
# Install OpenMixer on this Zynthian and make it the default:
#
#   install_openmixer.sh [--upgrade]
#
# - the OpenMixer apt repository (package openmixer-release, which carries the
#   signing key and one apt source per Debian release);
# - the packages config/openmixer-packages lists: plugin-hostd and its Python
#   client, omx-clap-host (with omx-clap-scan), omx-plugins, omx-panel and
#   plugin-qualify;
# - ZYNTHIAN_PLUGIN_ENGINE and ZYNTHIAN_MODHOST_BACKEND (plugin-hostd) added to an
#   existing zynthian_envars.sh;
# - /zynthian/config/plugin-hostd.conf, from config/plugin-hostd.conf, when the
#   device has none (the envars come from zynthian_envars.sh's defaults, which
#   update_zynthian_sys.sh copies when the device has no config);
# - the qualification sync (plugin-qualify-sync.timer and .path) with
#   Zynthian's plugin directories in /etc/omx/qualify.conf.
# - the OpenMixer vintage UI look and its font (fonts-inter), once; a colour
#   chosen by hand stays.
# - jackd2 from the OpenMixer channel, with the jack2 metadata fix, and the
#   apt pin that keeps it (etc/apt/preferences.d/openmixer-jackd2);
# - an apt hook that keeps the MOD GUI look chosen with
#   sbin/omx-modgui-look.sh after a package update (omx-modgui-sync), and now.
#
# Each of these is done once: the steps done are listed in
# $ZYNTHIAN_CONFIG_DIR/openmixer-defaults. A config that exists is not changed.
# --upgrade also upgrades the packages. No service is started, stopped or
# restarted: the last lines say what applies when.
#******************************************************************************

ZYNTHIAN_CONFIG_DIR=${ZYNTHIAN_CONFIG_DIR:-/zynthian/config}
ZYNTHIAN_SYS_DIR=${ZYNTHIAN_SYS_DIR:-/zynthian/zynthian-sys}
PACKAGES=$(sed 's/#.*//' "$ZYNTHIAN_SYS_DIR/config/openmixer-packages" | xargs)
ENVARS="$ZYNTHIAN_CONFIG_DIR/zynthian_envars.sh"
DONE_FILE="$ZYNTHIAN_CONFIG_DIR/openmixer-defaults"
PHD_CONF="$ZYNTHIAN_CONFIG_DIR/plugin-hostd.conf"
QUALIFY_CONF=${QUALIFY_CONF:-/etc/omx/qualify.conf}
SYNC_UNITS="plugin-qualify-sync.timer plugin-qualify-sync.path"
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

upgrade=0
case "$1" in
	--upgrade) upgrade=1 ;;
	"") ;;
	*) echo "Usage: $0 [--upgrade]" >&2; exit 2 ;;
esac

arch=$(dpkg --print-architecture)
case "$arch" in
	arm64) multiarch=aarch64-linux-gnu ;;
	amd64) multiarch=x86_64-linux-gnu ;;
	*)
		echo "OpenMixer packages are built for arm64 and amd64, not $arch. Skipping."
		exit 0
		;;
esac

changes=()
notes=()
failed=0
change() { changes+=("$1"); }
note() { notes+=("$1"); }

is_installed() {
	dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}
version_of() {
	dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

is_done() { grep -qx "$1" "$DONE_FILE" 2>/dev/null; }
mark_done() { is_done "$1" || echo "$1" >>"$DONE_FILE"; }

# The value of an exported variable in zynthian_envars.sh, quotes removed
envar_get() {
	sed -n "s/^export $1=[\"']\{0,1\}\([^\"']*\).*/\1/p" "$ENVARS" | tail -n 1
}
envar_set() {
	if grep -q "^export $1=" "$ENVARS"; then
		sed -i "s/^export $1=.*/export $1=\"$2\"/" "$ENVARS"
	else
		echo "export $1=\"$2\"" >>"$ENVARS"
	fi
}

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

#------------------------------------------------------------------------------
# Repository and packages
#------------------------------------------------------------------------------

if ! is_installed openmixer-release; then
	echo "Adding the OpenMixer repository ..."
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT
	# the package the channel's signed index lists, checked against the archive
	# key pinned in this checkout: apt does not check a local .deb
	if "$ZYNTHIAN_SYS_DIR/scripts/omx-fetch-release.sh" "$tmpdir/openmixer-release.deb" &&
		apt-get "${APT_OPTS[@]}" install "$tmpdir/openmixer-release.deb"; then
		change "added the OpenMixer repository (openmixer-release)"
	else
		note "could not add the OpenMixer repository: the next run tries again"
		failed=1
	fi
fi

missing=""
for p in $PACKAGES; do
	is_installed "$p" || missing="$missing $p"
done
missing=${missing# }

if [ "$failed" = 0 ] && { [ "$upgrade" = 1 ] || { [ -n "$missing" ] && ! is_done packages; }; }; then
	declare -A before
	for p in $PACKAGES; do before[$p]=$(is_installed "$p" && version_of "$p"); done
	# --upgrade takes them all to the newest; otherwise only the missing ones are installed
	todo=$missing
	[ "$upgrade" = 1 ] && todo=$PACKAGES
	echo "Installing OpenMixer packages: $todo ..."
	# shellcheck disable=SC2086
	if apt-get -y update && apt-get "${APT_OPTS[@]}" install $todo; then
		for p in $PACKAGES; do
			now=$(version_of "$p")
			if [ -z "${before[$p]}" ]; then
				change "installed $p $now"
			elif [ "${before[$p]}" != "$now" ]; then
				change "upgraded $p ${before[$p]} -> $now"
			fi
		done
		mark_done packages
	else
		note "the OpenMixer packages did not install: the next run tries again"
		failed=1
	fi
elif [ -z "$missing" ]; then
	mark_done packages
fi
if is_installed omx-clap-host && ! command -v omx-clap-scan >/dev/null; then
	note "omx-clap-scan is missing from omx-clap-host $(version_of omx-clap-host)"
fi

# jackd2 with the jack2 metadata fix (zynthian-sys#24): Debian's strands the
# Berkeley DB mutexes of every JACK client that dies without closing, until no
# client can open the metadata store (BDB2034). The apt pin prefers the
# channel's jackd2; it is put back at every run, and an installed Debian jackd2
# is replaced by the channel's as soon as the channel serves one.
APT_PIN=${APT_PIN:-/etc/apt/preferences.d/openmixer-jackd2}
jackd_changed=0
if [ "$failed" = 0 ] && is_installed openmixer-release; then
	if ! cmp -s "$ZYNTHIAN_SYS_DIR/etc/apt/preferences.d/openmixer-jackd2" "$APT_PIN"; then
		mkdir -p "$(dirname "$APT_PIN")"
		cp "$ZYNTHIAN_SYS_DIR/etc/apt/preferences.d/openmixer-jackd2" "$APT_PIN"
		change "apt pin $APT_PIN: jackd2 from the OpenMixer channel"
	fi
	if is_installed jackd2; then
		jackd_before=$(version_of jackd2)
		case "$jackd_before" in
		*+omx*) ;;
		*)
			if apt-get -y update >/dev/null && apt-get "${APT_OPTS[@]}" install jackd2 libjack-jackd2-0 >/dev/null; then
				jackd_now=$(version_of jackd2)
				if [ "$jackd_now" != "$jackd_before" ]; then
					change "jackd2 $jackd_before -> $jackd_now (the metadata fix)"
					jackd_changed=1
				else
					note "the OpenMixer channel serves no jackd2 with the metadata fix yet: jackd2 $jackd_before stays"
				fi
			else
				note "could not install jackd2 from the OpenMixer channel: the next run tries again"
			fi
			;;
		esac
	fi
fi

#------------------------------------------------------------------------------
# Zynthian settings
#------------------------------------------------------------------------------

mkdir -p "$ZYNTHIAN_CONFIG_DIR"

# The envars of a stock device: an existing zynthian_envars.sh gets the plugin
# engine and the MOD-UI backend, once. A device with no such file gets them from
# zynthian_envars.sh's defaults, which update_zynthian_sys.sh copies.
modhost_changed=0
engine_changed=0
if ! is_done envars && [ -f "$ENVARS" ] && command -v plugin-hostd >/dev/null; then
	old=$(envar_get ZYNTHIAN_MODHOST_BACKEND)
	if [ "$old" != plugin-hostd ]; then
		envar_set ZYNTHIAN_MODHOST_BACKEND plugin-hostd
		change "ZYNTHIAN_MODHOST_BACKEND ${old:-unset} -> plugin-hostd in $ENVARS"
		modhost_changed=1
	fi
	old=$(envar_get ZYNTHIAN_PLUGIN_ENGINE)
	if [ -z "$old" ]; then
		envar_set ZYNTHIAN_PLUGIN_ENGINE plugin-hostd
		change "ZYNTHIAN_PLUGIN_ENGINE unset -> plugin-hostd in $ENVARS"
		engine_changed=1
	fi
	mark_done envars
fi

# plugin-hostd.conf: a device that has none gets the one this tree ships; one
# that exists is not changed here.
phd_changed=0
if ! is_done hostd-conf && command -v plugin-hostd >/dev/null; then
	if [ ! -f "$PHD_CONF" ]; then
		cp "$ZYNTHIAN_SYS_DIR/config/plugin-hostd.conf" "$PHD_CONF"
		change "wrote $PHD_CONF"
		phd_changed=1
	fi
	mark_done hostd-conf
fi

# The pin file must exist for plugin-hostd to start: empty until the first sync.
# Not a step done once: it is put back at every boot and every run.
TMPFILES_CONF=/etc/tmpfiles.d/omx-qualified-pins.conf
if command -v plugin-hostd >/dev/null; then
	if ! cmp -s "$ZYNTHIAN_SYS_DIR/etc/tmpfiles.d/omx-qualified-pins.conf" "$TMPFILES_CONF"; then
		mkdir -p /etc/tmpfiles.d
		cp "$ZYNTHIAN_SYS_DIR/etc/tmpfiles.d/omx-qualified-pins.conf" "$TMPFILES_CONF"
		change "wrote $TMPFILES_CONF"
	fi
	if [ ! -e /var/lib/omx/qualified.pins ]; then
		systemd-tmpfiles --create "$TMPFILES_CONF"
		change "created an empty /var/lib/omx/qualified.pins"
	fi
fi

# qualify.conf: Zynthian's directories, unless the file already holds settings
if ! is_done qualify-conf && is_installed plugin-qualify; then
	rendered=$(sed "s/#MULTIARCH#/$multiarch/g" "$ZYNTHIAN_SYS_DIR/config/qualify.conf")
	if [ -f "$QUALIFY_CONF" ] && [ "$(cat "$QUALIFY_CONF")" = "$rendered" ]; then
		:
	elif [ -f "$QUALIFY_CONF" ] && grep -q '^[[:space:]]*[^#[:space:]]' "$QUALIFY_CONF"; then
		note "$QUALIFY_CONF holds settings of its own: left as it is"
	else
		mkdir -p "$(dirname "$QUALIFY_CONF")"
		echo "$rendered" >"$QUALIFY_CONF"
		change "wrote Zynthian's plugin directories to $QUALIFY_CONF"
	fi
	mark_done qualify-conf
fi

# Zynthian's plugin directories in plugin-hostd.conf, and qualify.conf naming
# it. Not a step done once: it follows LV2_PATH on every run.
if [ -f "$PHD_CONF" ]; then
	while IFS= read -r line; do
		[ -n "$line" ] && change "$line"
	done < <(ZYNTHIAN_CONFIG_DIR="$ZYNTHIAN_CONFIG_DIR" PHD_CONF="$PHD_CONF" QUALIFY_CONF="$QUALIFY_CONF" \
		"$ZYNTHIAN_SYS_DIR/sbin/omx-search-paths.sh")
fi

# The sync's units: enabled, not started. The timer's first run is two
# minutes after the next boot; the path unit runs it when a plugin is installed.
if ! is_done qualify-sync && is_installed plugin-qualify; then
	for u in $SYNC_UNITS; do
		if [ "$(systemctl is-enabled "$u" 2>/dev/null)" != enabled ]; then
			systemctl enable "$u" >/dev/null 2>&1 && change "enabled $u" || { note "could not enable $u"; failed=1; }
		fi
	done
	[ "$failed" = 0 ] && mark_done qualify-sync
fi

# The UI look: OpenMixer vintage (config/ui-looks/openmixer-vintage.sh, the
# console's colours and its font Inter), set once; a colour chosen by hand
# stays. fonts-inter carries the font. The web configurator's UI page changes it.
look_changed=0
if ! is_installed fonts-inter; then
	if apt-get "${APT_OPTS[@]}" install fonts-inter >/dev/null; then
		change "installed fonts-inter $(version_of fonts-inter)"
	else
		note "fonts-inter did not install: the UI falls back to another font until the next run"
	fi
fi
if ! is_done ui-look && [ -f "$ENVARS" ]; then
	while IFS= read -r line; do
		case "$line" in
		kept\ *) note "UI look: $line" ;;
		"look openmixer-vintage: 0 "*) ;;
		look\ *) change "UI $line"; look_changed=1 ;;
		esac
	done < <(ZYNTHIAN_SYS_DIR="$ZYNTHIAN_SYS_DIR" "$ZYNTHIAN_SYS_DIR/sbin/omx-ui-look.sh" --keep-changed openmixer-vintage "$ENVARS")
	mark_done ui-look
fi

# The MOD GUI look (sbin/omx-modgui-look.sh, /etc/omx/modgui-look): omx-plugins
# ships no MOD GUI; omx-modgui-sync (omx-panel) writes the bundles in
# /usr/local/lib/lv2 in the recorded look. After every dpkg run apt runs
# --apply, which runs omx-modgui-sync when omx-plugins-lv2 changed (its plugins
# come and go) and does nothing otherwise; the package's own bundles are never
# written, and it never fails apt. Not a step done once: the hook names this
# tree, and is put back at every run.
APT_HOOK=${APT_HOOK:-/etc/apt/apt.conf.d/90omx-modgui-look}
hook="DPkg::Post-Invoke { \"if [ -x $ZYNTHIAN_SYS_DIR/sbin/omx-modgui-look.sh ]; then $ZYNTHIAN_SYS_DIR/sbin/omx-modgui-look.sh --apply || true; fi\"; };"
if [ "$(cat "$APT_HOOK" 2>/dev/null)" != "$hook" ]; then
	if echo "$hook" > "$APT_HOOK"; then
		change "apt hook $APT_HOOK: the MOD GUI look survives package updates"
	else
		note "could not write $APT_HOOK: a package update leaves new omx-plugins without a MOD GUI until omx-modgui-sync runs"
	fi
fi
if out=$("$ZYNTHIAN_SYS_DIR/sbin/omx-modgui-look.sh" --apply 2>&1); then
	case "$out" in *applied*) change "$out" ;; esac
else
	note "MOD GUI look: $out"
fi

#------------------------------------------------------------------------------
# Report
#------------------------------------------------------------------------------

if [ ${#changes[@]} = 0 ]; then
	echo "OpenMixer defaults: nothing to change"
else
	echo "OpenMixer defaults: ${#changes[@]} changed"
	for c in "${changes[@]}"; do echo "  $c"; done
fi
for n in "${notes[@]}"; do echo "  note: $n"; done
if [ "$modhost_changed" = 1 ] || [ "$phd_changed" = 1 ]; then
	echo "  mod-host and mod-ui were not restarted: the change applies at their next start"
	echo "  (a reboot, or now: $ZYNTHIAN_SYS_DIR/sbin/set_modhost_backend.sh plugin-hostd)"
fi
if [ "$jackd_changed" = 1 ]; then
	echo "  jackd was not restarted: the new jackd2 applies from its next start (a reboot)"
fi
if [ "$look_changed" = 1 ]; then
	echo "  zynthian was not restarted: the UI look applies from its next start"
fi
if [ "$engine_changed" = 1 ]; then
	echo "  zynthian was not restarted: the menus offer plugin-hostd from its next start"
fi
exit "$failed"

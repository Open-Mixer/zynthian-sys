# Zynthian System Scripts & Configuration files

[Zynthian](http://zynthian.org) is an Open Synth Platform based on Raspberry Pi, Linux and Free Software Synthesizers.

The [ZynthianOS SD-image](https://os.zynthian.org/zynthianos-last-stable.zip) has all the software you need for building a ZynthianBox, including a good amount of sound libraries and presets.

This repository contains system scripts & configuration files.

## OpenMixer repository

This fork adds the OpenMixer apt repository. It brings plugin-hostd (it answers mod-host's protocol and runs plugins in worker processes it restarts), omx-clap-host (CLAP and LV2 plugins driven like mod-host), omx-plugins (OpenMixer effects as CLAP and LV2) and omx-panel (panels and MOD GUIs generated from what each plugin declares).

The repository comes from the `openmixer-release` package, which installs the signing key in `/usr/share/keyrings` and links the apt source for the running Debian release (bookworm or trixie) in `/etc/apt/sources.list.d/openmixer.sources`. Packages are built for arm64 and amd64.

From `openmixer-release` 1-11 it also installs the testing source, `/etc/apt/sources.list.d/openmixer-testing.sources`, disabled: the builds a release wave has proved on the Pi (Debian trixie arm64) before their release, as Fedora's updates-testing. `install_openmixer.sh` brings `openmixer-release` up to 1-11 and never changes that file's `Enabled` line. To take the testing builds, then to stop:

```
sudo sed -i 's/^Enabled: no$/Enabled: yes/' /etc/apt/sources.list.d/openmixer-testing.sources && sudo apt-get update && sudo apt-get upgrade
sudo sed -i 's/^Enabled: yes$/Enabled: no/' /etc/apt/sources.list.d/openmixer-testing.sources && sudo apt-get update
```

No apt pin: enabled, the newer build wins; disabled, the next released version replaces a testing build at the next upgrade.

The system setup scripts install `openmixer-release` with the other repositories and then run `scripts/recipes/install_openmixer.sh`. On a running Zynthian, run the recipe by hand:

```
$ZYNTHIAN_RECIPE_DIR/install_openmixer.sh
```

It adds the repository if missing and installs the missing packages, so running it again is safe; `--upgrade` also upgrades them. `scripts/update_system_image.sh` runs it with `--upgrade`, so an updated image carries the newest versions.

The first `openmixer-release` is fetched by `scripts/omx-fetch-release.sh`, which installs nothing unless the package is the newest one in the channel's index for this Debian release, and that index is signed by a key in `keys/openmixer-archive-keyring.asc`. apt does not check the signature of a local `.deb`, so this check stands in for one until the package has installed the key.

## Following the fork

This repository is a fork of [zynthian/zynthian-sys](https://github.com/zynthian/zynthian-sys). Its `vangelis` is upstream's, kept as upstream has it; the OpenMixer work is the branch `openmixer`, and that is the branch a device is on.

PRs merge into `openmixer`, not the default branch: close the issue by hand at merge.

A device follows the fork with Zynthian's own updater, `scripts/update_zynthian.sh`. With `ZYNTHIAN_STABLE_TAG` set to `last`, it moves each repository to the newest release tag. Our releases are signed tags of the form `<branch>-<release>-omx.<serial>`: `vangelis-2610-omx.3` is our third release on upstream's `vangelis-2610`. The updater takes a tag only if it meets all of these:

- it contains the tip the device runs, so an update never rewinds a device;
- in zynthian-ui and zynthian-sys, it is one of ours, signed by a key in `keys/track-signing-keys.asc` (read from the checkout the device runs), and names the repository it is for.

Anything else leaves the repository where it is, with a line in the update log saying why. That covers an upstream tag that does not have our work yet, a commit pushed without a tag, a tag signed by another key and a device with no key file. The key file changes only through a signed tag. The repositories we do not fork take upstream's tags under the first rule alone. The same update upgrades the OpenMixer packages through apt.

The updater fetches every remote and keeps only the tags of the one it fetched last, so the target script takes the fork's tags again before it chooses.

`scripts/omx-release-target.sh <checkout> <branch>` prints the tag the updater takes, or the reasons there is none. Maintainers publish a release with:

```
scripts/omx-release-tag.sh <checkout> [<commit>] --push <remote>
```

## OpenMixer in this Zynthian

On this fork OpenMixer is part of the default install; in the series offered upstream each part stays off until a user switches it on. No file that configures JACK changes: Zynthian stays on jackd. How to install and use it, and where it stands: <https://openmixer.org/docs/zynthian>. A new image built from this fork, and an existing Zynthian on its next `update_zynthian_sys.sh` (or `update_system_image.sh`), end up with:

- the OpenMixer repository and plugin-hostd, omx-clap-host (with omx-clap-scan), omx-plugins, omx-panel and plugin-qualify;
- plugin-hostd as the mod-host of MOD-UI (`ZYNTHIAN_MODHOST_BACKEND=plugin-hostd`) and as the engine the UI menus offer LV2 plugins through (`ZYNTHIAN_PLUGIN_ENGINE=plugin-hostd`);
- `/zynthian/config/plugin-hostd.conf` with `require_pins 1`, `pin_mode first-use`, `pin_file /var/lib/omx/qualified.pins` and `lv2_worker omx-clap-host`: a plugin the sync qualified in-process shares a worker and chains, one it refused loads only when the user chooses it, alone in a worker of its own, and one it has not reached yet still loads, in a worker of its own. A plugin our host cannot run is reported with its reason and never handed to mod-host or jalv;
- the qualification sync: `plugin-qualify-sync.timer` runs it two minutes after every boot at the lowest CPU and disk priority, and `plugin-qualify-sync.path` when a plugin directory changes. A plugin whose files are unchanged is skipped, so only the first boot after install (or after new plugins) takes long. Zynthian's plugin directories (its `LV2_PATH`, and `/usr/local/lib/clap:/usr/lib/clap`) are written into `/zynthian/config/plugin-hostd.conf` by `sbin/omx-search-paths.sh`, at every update and before every sync; the sync scans what `plugin-hostd --search-path` prints for that file, which `/etc/omx/qualify.conf` names as `hostd_conf`. Each run starts omx-panel's `omx-panel-sync.service` (omx-panel's own drop-in on the sync).

All of it is done by `scripts/recipes/install_openmixer.sh`, which the setup scripts and `update_zynthian_sys.sh` run. Each step is done once and listed in `/zynthian/config/openmixer-defaults`, so a setting changed by hand afterwards stays. It starts and restarts nothing: its report says what changed and what applies at the next start of mod-host, mod-ui or zynthian. `tests/default-install-check.sh` checks all of it in a container.

To go back, as root:

```
/zynthian/zynthian-sys/sbin/set_modhost_backend.sh jack_load      # MOD-UI on mod-host in JACK
sed -i 's/^export ZYNTHIAN_PLUGIN_ENGINE=.*/export ZYNTHIAN_PLUGIN_ENGINE="jalv"/' /zynthian/config/zynthian_envars.sh
systemctl disable --now plugin-qualify-sync.timer plugin-qualify-sync.path
sed -i 's/^require_pins .*/require_pins 0/' /zynthian/config/plugin-hostd.conf
```

An image builder can ship the image already qualified: after the setup script, run `scripts/omx_prequalify_image.sh` on the assembled system. It runs the sync once and writes the pin file, records and descriptors where the services read them; it packages nothing. It must run natively on arm64 (a Raspberry Pi): the results are keyed by the hashes of the plugin files and measured on the CPU, so it refuses to run elsewhere or under emulation. Without it, the first boot does the same work in the background.

How the published image is built from upstream's release: [docs/openmixer-image.md](docs/openmixer-image.md).

## plugin-hostd as the mod-host of MOD-UI

MOD-UI talks to a mod-host on port 5555. `ZYNTHIAN_MODHOST_BACKEND` in `zynthian_envars.sh` picks what answers there:

- `plugin-hostd` (the default): plugin-hostd on ports 5555 and 5556, each plugin in a worker process of its own, so a plugin that crashes takes only its own worker down. It runs LV2 and CLAP plugins. Without plugin-hostd installed, `jack_load` is used.
- `jack_load`: mod-host loaded into JACK as an internal client, as before.

`mod-host.service` runs `sbin/mod-host-backend.sh`, which honours the setting, removes the other backend before it starts and on stop removes whichever one runs. It starts plugin-hostd with `sbin/plugin-hostd-start.sh <port> [<feedback port>]`, the one place a plugin-hostd is started on this image: the UI's plugin-hostd engine starts its own daemon, on `ZYNTHIAN_PLUGIN_HOSTD_PORT`, with it too. The script leaves a daemon already running on the port as it is, and otherwise returns once the daemon prints the line it declares for ready in its protocol file (`/usr/share/plugin-hostd-protocol/plugin-hostd.json`). To switch, as root:

```
/zynthian/zynthian-sys/sbin/set_modhost_backend.sh plugin-hostd
/zynthian/zynthian-sys/sbin/set_modhost_backend.sh jack_load
```

It stops MOD-UI and mod-host, writes the setting and starts MOD-UI again if it was running, saying each step. Without an argument it prints the setting and what runs. plugin-hostd reads `/zynthian/config/plugin-hostd.conf`, copied from `config/plugin-hostd.conf` once; that file explains each setting. `tests/modhost-backend-check.sh` checks the plugin-hostd backend end to end.

## MOD GUIs from omx-panel

MOD-UI draws a plugin with the MOD GUI the plugin ships. For an LV2 plugin that ships none, `omx-modgui-sync` (a command of the omx-panel package) makes one with `omx-panel modgui` from the plugin's descriptor, so MOD-UI shows a panel for every plugin.

- Each GUI is a bundle of its own (`omx-modgui-<name>.lv2`) in `/usr/local/lib/lv2`, which is on `LV2_PATH` already. Its `manifest.ttl` holds the GUI triples and declares no plugin, so lilv adds the GUI to the installed plugin and the plugin's own bundle is never touched.
- The descriptor is the plugin's declaration in omx-contract for our own plugins, else one written by plugin-hostd or plugin-qualify in `/var/lib/omx/descriptors`, else one made by `plugin-hostd-probe describe` and kept in `/var/lib/omx/modgui-sync`.
- A bundle newer than its descriptor is left as it is. A bundle without the sync's marker file is never written or removed. A generated GUI goes away when its plugin is removed or starts shipping its own.
- A plugin that cannot get a GUI never fails the run; the summary names it.
- `omx-panel-sync.service` comes with omx-panel 0.17 and later (it replaced `omx-modgui-sync.service` and `omx-complement-sync.service`), enabled by the package; this image gives it Zynthian's `LV2_PATH` and enables it again if it was turned off. It runs at boot and after each `plugin-qualify-sync`, and runs `omx-modgui-sync` among its steps. On Debian trixie that step reads the plugins through python3-lilv, whose `lilv.py` (0.24.26-1, line 35) opens `liblilv-0.so`, a file only liblilv-dev ships; omx-panel 0.17.2 only suggests python3-lilv and needs neither, so on an image without liblilv-dev the MOD GUIs are not made (found by the default-install job, 2026-11-28: `omx-modgui-sync: python3-lilv is not installed` with python3-lilv installed). The fix belongs to omx-panel. `omx-modgui-sync --check` says whether MOD-UI reads the folder. MOD-UI shows new GUIs the next time it starts.

The OpenMixer plugins (omx-plugins-lv2) ship their MOD GUI inside their bundles in `/usr/lib/lv2`, listed in each `manifest.ttl`. MOD-UI reads them from there like any other plugin's, and the sync leaves them alone. The script, its unit and its tests live in the omx-panel repository.

You can learn more about the Zynthian Project in any of our sites: 

+ [website](https://zynthian.org)
+ [wiki](https://wiki.zynthian.org)
+ [user's guide](https://help.zynthian.org)
+ [blog](https://blog.zynthian.org)
+ [forum](https://discourse.zynthian.org) => Join the conversation!!

You can buy official kits in the zynthian shop:

+ [shop](https://shop.zynthian.org)

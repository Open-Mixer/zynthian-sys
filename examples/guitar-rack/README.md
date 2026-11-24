# A guitar rack, hosted in plugin-hostd

A whole guitar rack as one Zynthian chain, run by plugin-hostd: Hex Chain (guitaramp-suite.lv2, by rpowell5064,
<https://github.com/rpowell5064/guitar-amp-mod>, GPL-3.0). Two snapshots:

- `001-Hex Chain guitar rack.zss`: one audio chain from audio input 1, seven plugins in series:

  ```
  Input Trim -> Drive -> Amp -> Cabinet -> Modulation -> Delay -> Reverb -> mixer
  ```

  The trim's hum filter is on, the drive is set to a light crunch, the amp is set for a clean-to-crunch tone with its
  master at 0.25, and the cabinet cuts below 80 Hz and above 7.5 kHz. The chorus is at a quarter mix, and the delay
  (380 ms, 30 % feedback) and reverb (1.8 s) are both at a fifth.
- `002-Hex Forge.zss`: the same rack as one plugin, Hex Forge, which runs every block of the suite inside it in an
  order of its own.

Every processor is a `PH/` one: plugin-hostd runs it.

## What it needs

- OpenMixer on the Zynthian (`scripts/recipes/install_openmixer.sh`), which also copies these snapshots, once, into
  the snapshot bank `001-OpenMixer examples`.
- The bundle, installed by Zynthian's own recipe: `scripts/recipes/install_guitaramp-suite_prebuilt.sh` (release
  zynthian-1.21.1, aarch64: a Raspberry Pi 4 or 5). No OpenMixer package carries it.
- The plugins qualified, as every plugin plugin-hostd runs under Zynthian's settings (`require_pins 1`): the
  qualification sync does it for a newly installed bundle.

## Load it

Snapshots -> `001-OpenMixer examples` -> `Hex Chain guitar rack`. Plug the guitar into audio input 1. The chain's
audio input is the only setting outside the plugins; change it in the chain's options when the guitar is on another
input.

## Proof

`rack-proof.py` runs a snapshot's chain on the device without touching Zynthian's own JACK server or plugin-hostd. It
starts a plugin-hostd of its own under the device's settings (its pins and search path) on a private JACK server,
adds each plugin, sets the snapshot's controllers and connects the plugins in the chain's order. It then plays a
1 kHz tone at -20 dBFS through the chain and reads the level. Finally it moves one control the chain must obey, and the
level must fall by 20 dB or more.

```
python3 rack-proof.py '001-Hex Chain guitar rack.zss' --lever 'Hex Chain Amp:master=0'
python3 rack-proof.py '002-Hex Forge.zss' --lever 'Hex Forge:out_level=-60'
```

On a Raspberry Pi 5 (Zynthian vangelis, plugin-hostd 0.20.7), every plugin was added in 0.15 to 0.27 s with all its
controllers set. The rack's output read -17.2 dBFS (L) and -16.6 dBFS (R); with the amp's master at 0 it fell 44.0 dB.
Hex Forge read -15.1 dBFS, and with its output at -60 dB it fell silent.

`tests/guitar-rack-example-check.sh` holds both snapshots to the bundle of the recipe's release: every plugin name is
in the bundle, and every controller is an input control port of its plugin, set inside its range.

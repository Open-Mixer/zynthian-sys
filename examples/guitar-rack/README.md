# A guitar rack, hosted in plugin-hostd

A whole guitar rack as one Zynthian chain, run by plugin-hostd: Hex Chain (guitaramp-suite.lv2, by rpowell5064,
<https://github.com/rpowell5064/guitar-amp-mod>, GPL-3.0). Three snapshots:

- `001-Hex Chain guitar rack.zss`: one audio chain from audio input 1, seven plugins in series:

  ```
  Input Trim -> Drive -> Amp -> Cabinet -> Modulation -> Delay -> Reverb -> mixer
  ```

  The trim's hum filter is on, the drive is set to a light crunch, the amp is set for a clean-to-crunch tone with its
  master at 0.25, and the cabinet cuts below 80 Hz and above 7.5 kHz. The chorus is at a quarter mix, and the delay
  (380 ms, 30 % feedback) and reverb (1.8 s) are both at a fifth.
- `002-Hex Forge.zss`: the same rack as one plugin, Hex Forge, which runs every block of the suite inside it in an
  order of its own.
- `003-Stomp pedalboard.zss`: a footswitch pedalboard, the one riban set up on a V4 with a Behringer FCB1010
  (<https://discourse.zynthian.org/t/a-pedalboard-zynthian/4325/151>): an input stage with the 50 Hz hum filter, then
  stompable overdrive, wah, phaser, delay and reverb, a tuner, and the two expression pedals on volume and wah. The
  post names the effects and the Hex plugins; the order, the values, the tuner plugin and which footswitch does what
  are this example's. See [The stomp pedalboard](#the-stomp-pedalboard).

Every processor is a `PH/` one: plugin-hostd runs it.

## What it needs

- OpenMixer on the Zynthian (`scripts/recipes/install_openmixer.sh`), which also copies these snapshots, once, into
  the snapshot bank `001-OpenMixer examples`.
- The bundle, installed by Zynthian's own recipe: `scripts/recipes/install_guitaramp-suite_prebuilt.sh` (release
  zynthian-1.21.1, aarch64: a Raspberry Pi 4 or 5). No OpenMixer package carries it.
- The plugins qualified, as every plugin plugin-hostd runs under Zynthian's settings (`require_pins 1`): the
  qualification sync does it for a newly installed bundle.

## The stomp pedalboard

One audio chain from audio input 1, `Pedalboard`:

```
x42 Instrument Tuner -> Input Trim (hum filter on, mains 50 Hz) -> Drive -> Wah (fixed: the pedal moves it)
  -> Modulation (Phaser) -> Delay -> Reverb -> mixer strip
```

The tuner comes first, so it reads the guitar before any effect. The snapshot carries the bindings, so nothing has to
be learnt on the device. They match the FCB1010 with riban's firmware (<https://github.com/riban-bw/FCB1010_Firmware>)
out of the box: footswitches 1 to 10 send CC 21 to 30 (127 ON, 0 OFF), pedal A sends CC 7 and pedal B CC 11. Every
binding listens on any MIDI channel.

| Control | CC | Binds | Does |
|---|---|---|---|
| Footswitch 1 | 21 | Drive `enabled` | overdrive on / off |
| Footswitch 2 | 22 | Wah `enabled` | wah on / off |
| Footswitch 3 | 23 | Modulation `enabled` | phaser on / off |
| Footswitch 4 | 24 | Delay `enabled` | delay on / off |
| Footswitch 5 | 25 | Reverb `enabled` | reverb on / off |
| Footswitch 6 | 26 | mixer strip `mute` | tuner mode: the chain is muted and the tuner, before the mute, still reads |
| Pedal A | 7 | mixer strip `level` | volume |
| Pedal B | 11 | Wah `freq` | wah sweep |

Footswitches 7 to 10 are spare. Every stomp loads OFF. The pedal also powers on with every switch OFF and sends
nothing until one is pressed, so its LEDs and the chain start in step.

These are chain bindings, so they act while `Pedalboard` is the active chain, as it is when the snapshot loads.
Another pedal works the same way once it sends those CCs. To use other CCs, learn them over these bindings.

### Two Zynthian issues it steps around

- [zynthian-issue-tracking#1839](https://github.com/zynthian/zynthian-issue-tracking/issues/1839), "Ability to invert
  CC binding". A pedal sending 127 for ON and bound to a plugin's `bypass` turns the effect OFF when its LED says ON.
  Zynthian sets a toggle from the CC alone (64 or more is the maximum) and ignores the binding's range for a toggle, so
  neither a snapshot nor the binding menu can turn it round. Every Hex Chain plugin also has an `enabled` port (1 =
  processing), and the snapshot binds that, so ON is ON. This holds under both hosts: jalv and plugin-hostd both
  serve `enabled`. The issue still stands for a plugin with nothing but a bypass, and for riban's other case: one
  pedal that mutes the chain AND turns the tuner on needs one of the two bindings inverted. That is why the tuner here
  is always on and placed before the mute.
- [zynthian-issue-tracking#1840](https://github.com/zynthian/zynthian-issue-tracking/issues/1840), "Can't access
  MIDI binding menu on a V4". Nothing has to be bound on the device: the bindings load with the snapshot, so a V4
  needs neither the menu nor a bold touch. Changing a binding still goes through that menu, which this example does
  not fix.

### On a stock Zynthian (no OpenMixer)

The same chain runs under jalv, Zynthian's own LV2 host, with every processor `JV/` instead of `PH/`. To make that
snapshot and put it in the user's bank, on the Zynthian:

```
cd /zynthian/zynthian-sys/examples/guitar-rack       # or wherever this directory is copied
mkdir -p "/zynthian/zynthian-my-data/snapshots/001-OpenMixer examples"
python3 stock-snapshot.py '003-Stomp pedalboard.zss' \
    "/zynthian/zynthian-my-data/snapshots/001-OpenMixer examples/003-Stomp pedalboard (jalv).zss"
```

It needs the guitaramp-suite bundle (`scripts/recipes/install_guitaramp-suite_prebuilt.sh`) and the x42 tuner
(`scripts/recipes/install_x42_plugins.sh`), each run when the image has not got it, and the plugins enabled in webconf's LV2
plugin list (Hex Chain Input Trim, Drive, Wah, Modulation, Delay, Reverb and x42 Instrument Tuner). Then Snapshots ->
`001-OpenMixer examples` -> `003-Stomp pedalboard (jalv)`.

### Measured: the same board under three hosts

The chain runs as plugin-hostd's house benchmark, scenario `pedal7` (`bench/` in Open-Mixer/plugin-hostd), every stomp
on. The hosts are plugin-hostd (H2: one worker per plugin, `individual`; or a chain, `chain-add`), mod-host (H3: every
plugin in one process) and jalv (H4: one process per plugin, as stock Zynthian runs them). The run used the house
conditions: governor `performance`, Zynthian's `zynthian` and `jack2` stopped, and a private JACK server at priority 70.
Each cell was repeated 3 times, with the hosts interleaved, and 10 s were measured per repeat. Two documents, checked
together by `validate.sh` and `gate.sh` (12 cells, none unstable):

- `alsa`: the Topping D10s (`--alsa hw:3 --periods 3`, as Zynthian's jackd), 48 kHz, 128 frames.
- `dummy`: the dummy driver, 48 kHz, 128 and 64 frames. This is the twin of the ALSA run, and the only 64-frame figures.

Raspberry Pi 5 (4 GB, Debian 13, kernel 6.18.50+rpt-rpi-2712), plugin-hostd 0.20.7, omx-clap-host 0.32.5, mod-host
0.10.6-595-g6c1cdd8, jalv 1.6.9, JACK 1.9.22. Medians of 3, with [min-max] where the repeats differ.

| driver | frames | host (mode) | DSP % avg / max | xruns in 10 s | load ms | processes | RSS / PSS MB |
|---|---|---|---|---|---|---|---|
| alsa | 128 | plugin-hostd (individual) | 11.91 / 12.07 | 0 | 754 | 8 | 833 / 118 |
| alsa | 128 | plugin-hostd (chain-add) | 11.38 / 11.63 | 0 [0-3] | 1020 | 6 | 602 / 104 |
| alsa | 128 | mod-host | 10.99 / 11.14 | 0 | 186 | 1 | 146 / 62 |
| alsa | 128 | jalv | 11.47 / 11.53 | 0 | 2755 | 7 | 875 / 192 |
| dummy | 128 | plugin-hostd (individual) | 11.61 / 11.69 | 0 | 729 | 8 | 833 / 117 |
| dummy | 128 | plugin-hostd (chain-add) | 11.04 / 11.12 | 0 [0-5] | 997 | 6 | 602 / 103 |
| dummy | 128 | mod-host | 10.75 / 10.89 | 0 | 170 | 1 | 146 / 62 |
| dummy | 128 | jalv | 11.14 / 11.34 | 2 [0-7] | 2678 | 7 | 875 / 192 |
| dummy | 64 | plugin-hostd (individual) | 19.61 / 19.68 | 7 [0-7] | 723 | 8 | 833 / 117 |
| dummy | 64 | plugin-hostd (chain-add) | 18.64 / 18.82 | 0 [0-13] | 972 | 6 | 602 / 103 |
| dummy | 64 | mod-host | 18.15 / 18.24 | 0 | 179 | 1 | 146 / 62 |
| dummy | 64 | jalv | 18.63 / 18.81 | 11 [7-14] | 2754 | 7 | 875 / 192 |

- **load ms** runs from the first plugin's add to the last reply, with its controls set. For jalv it runs until the
  last client is in the graph.
- **plugin-hostd `chain`** cannot hold this board. The tuner heads the chain and is mono, and it does not take the
  stereo plugins (`resp -501`). `chain-add` puts four of them in workers of their own, so the board runs as 5 workers.
- **The D10s at 64 frames:** no ALSA figure. Both times it was asked for 64 frames that day, JACK did not start and the
  DAC stopped answering on USB (`err -71`) until it was re-plugged. Two times is not a proof of cause, but avoid 64
  frames on this DAC.
- **Not measured here:** the round trip through converters (this DAC has no input) and the time from a footswitch to
  the sound (the MIDI hop is zynthian-ui's, the same under every host).

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

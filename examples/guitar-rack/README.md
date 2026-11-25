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
python3 pedalboard-bench.py '003-Stomp pedalboard.zss' \
    --stock "/zynthian/zynthian-my-data/snapshots/001-OpenMixer examples/003-Stomp pedalboard (jalv).zss"
```

It needs the guitaramp-suite bundle (`scripts/recipes/install_guitaramp-suite_prebuilt.sh`) and the x42 tuner
(`scripts/recipes/install_x42_plugins.sh`), each run when the image has not got it, and the plugins enabled in webconf's LV2
plugin list (Hex Chain Input Trim, Drive, Wah, Modulation, Delay, Reverb and x42 Instrument Tuner). Then Snapshots ->
`001-OpenMixer examples` -> `003-Stomp pedalboard (jalv)`.

### Measured: the same board under both hosts

`pedalboard-bench.py` runs the chain under jalv (one jalv per plugin, driven as Zynthian's JV engine drives it) and
under plugin-hostd (under the device's settings, as the PH engine drives it). Each host gets its own JACK server
(dummy driver, 48 kHz, realtime at Zynthian's priority 70), at a period of 128 and then 64. Zynthian's own JACK
server and engines are not touched.

```
python3 pedalboard-bench.py '003-Stomp pedalboard.zss'      # about 45 minutes: 10 per row
```

- **load s**: from the first plugin started to the last one answering, with its controllers set.
- **DSP %**: JACK's load with every stomp on, the heaviest the board gets.
- **xruns**: counted over the 10 minutes.
- **RTL ms**: what the guitar hears through Zynthian's ALSA setting (3 periods: one in, two out) plus the chain's own
  delay, measured with an impulse. The run fails unless the impulse rings on through the delay and reverb, which
  proves every stomp is on. The converters' delay is not in it: add the interface's.
- **stomp ms**: from the overdrive's `enabled` being set, as a bound footswitch sets it, to the first period whose
  output carries the overdrive's harmonics. The MIDI hop before that is zynthian-ui's own and the same under both
  hosts, so it is not counted.

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

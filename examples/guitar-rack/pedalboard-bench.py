#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ******************************************************************************
# The pedalboard, measured under both hosts: a snapshot's chain run the stock way (one jalv per plugin, driven on
# its console as Zynthian's JV engine drives it) and the OpenMixer way (plugin-hostd under the device's settings, as
# the PH engine drives it), each on a private JACK server (dummy driver, 48 kHz, realtime at Zynthian's priority),
# at each period asked. One table, one row per host and period:
#
#   load s     the chain loaded: the first plugin started to the last one answering, its controllers set
#   DSP %      JACK's DSP load over the run, mean and peak, every stomp ON (the heaviest the board gets)
#   xruns      over the run (--minutes, 10 by default)
#   RTL ms     what a guitar hears through Zynthian's ALSA setting (nperiods 3, so 3 periods: one in, two out)
#              plus the chain's own delay, measured with an impulse through it
#   stomp ms   a stomp sent (the overdrive's enabled control, as a bound footswitch sets it) to the first period
#              whose output carries the overdrive's harmonics, mean and worst of --stomps tries
#
#   pedalboard-bench.py SNAPSHOT [--hosts jalv,ph] [--periods 128,64] [--minutes 10] [--stomps 20] [--stock FILE]
#
# --stock FILE writes the snapshot for a stock Zynthian (every PH/ processor JV/) and exits: the drop-in.
#
# The MIDI hop from the footswitch to the control is Zynthian's own (zynthian-ui maps the CC, then hands the value
# to the engine) and the same under both hosts, so it is not in "stomp ms": that column is what the host adds. With
# no loopback cable (this Pi's DAC has no capture) the converters' delay is not in RTL either: add the interface's.
#
# Needs a Zynthian with OpenMixer (plugin-hostd, python3-jack-client, numpy), jalv, guitaramp-suite.lv2 and
# tuna.lv2. Zynthian's own JACK server, jalv engines and plugin-hostd are not touched. Exit 1 when a host fails to
# load the chain or a stomp is never heard.
#
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
# ******************************************************************************

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("rack_proof", os.path.join(HERE, "rack-proof.py"))
rp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rp)

SERVER = "omx-pedalboard-bench"
RATE = 48000
NPERIODS = 3  # Zynthian's jackd: -d alsa ... -n 3
PRIORITY = 70  # Zynthian's jackd: -P 70
TONE_HZ = 1000.0
TONE = 0.1  # -20 dBFS
STOMP = ("Hex Chain Drive", "enabled")
STOMP_DB = 20.0  # the overdrive's harmonics: this far over the clean chain's


def stock(snapshot, out):
    snap = json.load(open(snapshot, encoding="utf-8"))
    for chain in snap["chains"].values():
        for slot in chain.get("slots", []):
            for proc_id, code in slot.items():
                if code.startswith("PH/"):
                    slot[proc_id] = "JV/" + code[3:]
    json.dump(snap, open(out, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print(f"wrote {out}: the same chain, every processor JV/ (jalv), for a stock Zynthian")


class PluginHostd:
    """The chain in plugin-hostd, under the device's settings (rack-proof's daemon)."""

    def __init__(self, work, env, conf, port):
        with open(conf, encoding="utf-8") as src, open(os.path.join(work, "ph.conf"), "w", encoding="utf-8") as dst:
            for line in src:
                if not re.match(r"\s*state_root\b", line):
                    dst.write(line)
            dst.write(f"state_root {work}/state\n")
        self.log = open(os.path.join(work, "plugin-hostd.log"), "w")
        self.proc = subprocess.Popen(["plugin-hostd", "-n", "-p", str(port), "-f", str(port + 1), "-c", dst.name],
                                     stdout=self.log, stderr=subprocess.STDOUT, env=env)
        deadline = time.monotonic() + 30
        while not rp.answers(port):
            if time.monotonic() > deadline or self.proc.poll() is not None:
                raise RuntimeError(f"plugin-hostd did not answer on port {port} (log {self.log.name})")
            time.sleep(0.2)
        self.d = rp.Daemon(port)
        self.names = {}

    def add(self, n, uri, ctrls):
        inst = rp.FIRST_INSTANCE + n
        reply = self.d.call(f"add {uri} {inst}", timeout=120)
        if rp.status(reply) is None or rp.status(reply) < 0:
            raise RuntimeError(f"add {uri}: {reply!r}")
        for sym, value in ctrls.items():
            self.set(n, sym, value)
        self.names[n] = f"effect_{inst}"
        return self.names[n]

    def set(self, n, sym, value):
        r = self.d.call(f"param_set {rp.FIRST_INSTANCE + n} {sym} {value}")
        if rp.status(r) is None or rp.status(r) < 0:
            raise RuntimeError(f"param_set {sym} {value}: {r!r}")

    def close(self):
        self.proc.terminate()


class Jalv:
    """The chain as stock Zynthian runs it: one jalv per plugin (jalv -n NAME URI), controls written to its console."""

    def __init__(self, work, env):
        self.work, self.env, self.procs = work, env, {}

    def add(self, n, uri, ctrls):
        name = f"bench_jv_{n}"
        p = subprocess.Popen(["jalv", "-n", name, uri], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, env=self.env, text=True, bufsize=1)
        self.procs[n] = p
        threading.Thread(target=lambda: [None for _ in p.stdout], daemon=True).start()  # drain its console
        for sym, value in ctrls.items():
            self.set(n, sym, value)
        return name

    def set(self, n, sym, value):
        self.procs[n].stdin.write("%s=%.6f\n" % (sym, float(value)))  # zynthian_engine_jalv's own form
        self.procs[n].stdin.flush()

    def close(self):
        for p in self.procs.values():
            p.terminate()


def run(host_kind, snapshot, period, args):
    import jack
    import numpy as np

    uris = rp.uris_of(*rp.BUNDLES)
    chain = rp.chain_of(json.load(open(snapshot, encoding="utf-8")))
    work = tempfile.mkdtemp(prefix="pedalboard-bench-", dir=os.path.expanduser("~"))
    env = dict(os.environ, JACK_DEFAULT_SERVER=SERVER)
    jackd = subprocess.Popen(["jackd", "-R", "-P", str(PRIORITY), "-n", SERVER, "-d", "dummy", "-r", str(RATE),
                              "-p", str(period)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    host = None
    row = {"host": host_kind, "period": period}
    try:
        time.sleep(1.5)
        # a source and a sink of their own, so the chain is no cycle in JACK's graph (a cycle costs a period)
        src = jack.Client("pedalboard-bench-src", servername=SERVER)
        sink = jack.Client("pedalboard-bench-sink", servername=SERVER)
        tone_out = src.outports.register("tone")
        ins = [sink.inports.register("l"), sink.inports.register("r")]
        state = {"phase": 0, "impulse": None, "rec": None, "blocks": None, "xruns": 0}

        @sink.set_xrun_callback
        def xrun(delay):
            state["xruns"] += 1

        @src.set_process_callback
        def source(frames):
            out = tone_out.get_array()
            if state["impulse"] == "send":
                out[:] = 0.0
                out[0] = 1.0
                state["impulse"] = src.last_frame_time  # the frame the impulse left at
            elif state["impulse"] is not None:
                out[:] = 0.0
            else:
                t = (state["phase"] + np.arange(frames)) / RATE
                out[:] = TONE * np.sin(2 * np.pi * TONE_HZ * t)
                state["phase"] += frames

        @sink.set_process_callback
        def listen(frames):
            a = ins[0].get_array()
            if state["rec"] is not None and isinstance(state["impulse"], int) and len(state["rec"]) < state["rec_len"]:
                state["rec"].append((sink.last_frame_time, a.copy()))
            if state["blocks"] is not None:
                # the energy outside the 1 kHz tone: what the overdrive's harmonics add (the projection on the tone's
                # sine and cosine taken out, so the phase the chain gives the tone does not count)
                t = np.arange(frames) / RATE
                s, c = np.sin(2 * np.pi * TONE_HZ * t), np.cos(2 * np.pi * TONE_HZ * t)
                basis = np.vstack([s, c])
                coef = np.linalg.lstsq(basis.T, a, rcond=None)[0]
                resid = a - basis.T @ coef
                state["blocks"].append((time.monotonic(), float(np.dot(resid, resid)) / frames))

        src.activate()
        sink.activate()
        client = sink

        t0 = time.monotonic()
        host = PluginHostd(work, env, args.conf, args.port) if host_kind == "ph" else Jalv(work, env)
        names = []
        for n, (_, name, ctrls) in enumerate(chain):
            if name not in uris:
                raise RuntimeError(f"{name}: not in {', '.join(rp.BUNDLES)}")
            names.append((name, host.add(n, uris[name], ctrls)))
        def ports(client_name, out):
            return [p.name for p in client.get_ports(f"^{re.escape(client_name)}:", is_audio=True, is_output=out,
                                                     is_input=not out)]
        deadline = time.monotonic() + 120
        while not all(ports(c, True) and ports(c, False) for _, c in names):
            if time.monotonic() > deadline:
                raise RuntimeError("the chain's ports did not all appear in 120 s")
            time.sleep(0.05)
        row["load_s"] = time.monotonic() - t0

        prev = [tone_out.name]
        for _, c in names:
            dsts = ports(c, False)
            pairs = [(prev[0], d) for d in dsts] if len(prev) == 1 else (
                [(s, dsts[0]) for s in prev] if len(dsts) == 1 else list(zip(prev, dsts)))
            for s, d in pairs:
                client.connect(s, d)
            prev = ports(c, True)
        for s, d in zip(prev * 2 if len(prev) == 1 else prev, [p.name for p in ins]):
            client.connect(s, d)
        index = {name: n for n, (name, _) in enumerate(names)}

        # the stomp: clean chain (every stomp off, as the snapshot loads), then the overdrive on, --stomps times
        times = []
        for _ in range(args.stomps):
            host.set(index[STOMP[0]], STOMP[1], 0)
            time.sleep(1.0)
            state["blocks"] = []
            time.sleep(0.5)
            base = np.median([e for _, e in state["blocks"]]) or 1e-20
            sent = time.monotonic()
            host.set(index[STOMP[0]], STOMP[1], 1)
            time.sleep(1.0)
            heard = next((t for t, e in state["blocks"] if t > sent and e > base * 10 ** (STOMP_DB / 10)), None)
            state["blocks"] = None
            if heard is None:
                raise RuntimeError(f"the overdrive was never heard after {STOMP[0]}:{STOMP[1]}=1")
            times.append((heard - sent) * 1000)
        row["stomp_ms"] = (sum(times) / len(times), max(times))

        # every stomp on: the chain's delay (an impulse), then the run
        for n, (name, _) in enumerate(names):
            if name.startswith("Hex "):
                host.set(n, "enabled", 1)
        time.sleep(1.0)
        state.update(rec=[], rec_len=int(RATE * 0.7 / period) + 2, impulse="send")
        time.sleep(1.0)
        sent_at = state["impulse"]
        rec = state["rec"]
        state.update(impulse=None, rec=None)
        if not rec or not isinstance(sent_at, int):
            raise RuntimeError("the impulse was not recorded")
        first = rec[0][0]
        audio = np.concatenate([blk for _, blk in rec])
        start = sent_at - first
        if start < 0:
            raise RuntimeError("the sink began recording after the impulse left")
        row["chain_frames"] = int(np.argmax(np.abs(audio[start:])))
        # every stomp is on, the delay and the reverb with them: the impulse must ring on (100-500 ms after it)
        tail = audio[start + RATE // 10:start + RATE // 2]
        row["tail_db"] = 10 * np.log10(max(float(np.dot(tail, tail)), 1e-30))
        if row["tail_db"] < -60:
            raise RuntimeError(f"the impulse does not ring ({row['tail_db']:.1f} dB): the delay and reverb are not on")
        row["rtl_ms"] = (NPERIODS * period + row["chain_frames"]) * 1000.0 / RATE

        state["xruns"] = 0
        loads = []
        end = time.monotonic() + args.minutes * 60
        while time.monotonic() < end:
            time.sleep(1.0)
            loads.append(client.cpu_load())
        row["dsp"] = (sum(loads) / len(loads), max(loads))
        row["xruns"] = state["xruns"]
        for c in (src, sink):
            c.deactivate()
            c.close()
    except Exception as e:
        row["error"] = f"{type(e).__name__}: {e}"
    finally:
        if host:
            host.close()
        jackd.terminate()
        try:
            jackd.wait(10)
        except subprocess.TimeoutExpired:
            jackd.kill()
        time.sleep(1.0)
        shutil.rmtree(work, ignore_errors=True)
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("snapshot")
    ap.add_argument("--hosts", default="jalv,ph")
    ap.add_argument("--periods", default="128,64")
    ap.add_argument("--minutes", type=float, default=10.0)
    ap.add_argument("--stomps", type=int, default=20)
    ap.add_argument("--conf", default="/zynthian/config/plugin-hostd.conf")
    ap.add_argument("--port", type=int, default=5592)
    ap.add_argument("--stock", metavar="FILE", help="write the stock (JV/) snapshot to FILE and exit")
    args = ap.parse_args()
    if args.stock:
        stock(args.snapshot, args.stock)
        return 0

    governor = open("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor").read().strip() \
        if os.path.exists("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor") else "?"
    model = open("/proc/device-tree/model").read().strip("\0\n") if os.path.exists("/proc/device-tree/model") else "?"
    print(f"{os.path.basename(args.snapshot)} on {model}, governor {governor}, 48 kHz, {args.minutes:g} min a row")
    print()
    print("| host | period | load s | DSP % mean / peak | xruns | RTL ms (chain frames, impulse tail) | stomp ms mean / worst |")
    print("|---|---|---|---|---|---|---|")
    fails = 0
    for host in args.hosts.split(","):
        for period in [int(p) for p in args.periods.split(",")]:
            r = run(host, args.snapshot, period, args)
            label = "plugin-hostd (OpenMixer)" if host == "ph" else "jalv (stock)"
            if "error" in r:
                fails += 1
                print(f"| {label} | {period} | FAIL {r['error']} | | | | |", flush=True)
                continue
            print(f"| {label} | {period} | {r['load_s']:.2f} | {r['dsp'][0]:.1f} / {r['dsp'][1]:.1f} | {r['xruns']} | "
                  f"{r['rtl_ms']:.2f} ({r['chain_frames']}, tail {r['tail_db']:.0f} dB) | {r['stomp_ms'][0]:.1f} / {r['stomp_ms'][1]:.1f} |",
                  flush=True)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

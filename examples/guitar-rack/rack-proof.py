#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ******************************************************************************
# The guitar rack, run: each plugin of a snapshot's chain is added to a plugin-hostd of its own, under the device's
# plugin-hostd settings (its pins, its search path), its controllers set to the snapshot's values, and the plugins
# connected in the chain's order on a private JACK server (dummy driver, 48 kHz, 256 frames). A 1 kHz tone at
# -20 dBFS goes in and the level comes out; then one control the chain must obey (the lever) is moved and the level
# must fall by 20 dB or more, so the tone is known to go through the plugins and not around them.
#
#   rack-proof.py SNAPSHOT --lever 'Hex Chain Amp:master=0' [--lever ...] [--bundle DIR ...] [--conf FILE] [--port N]
#
# Zynthian's mixer strip (MI) closing a chain is Zynthian's, not a plugin: it is left out. Every --lever is moved at
# once. Needs a Zynthian with OpenMixer (plugin-hostd, python3-jack-client, numpy), guitaramp-suite.lv2 and, for a
# chain with the tuner, tuna.lv2. Zynthian's
# own JACK server and plugin-hostd are not touched. Exit 1 when a plugin is refused, the output is silent or the
# lever moves nothing.
#
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
# ******************************************************************************

import argparse
import glob
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

SERVER = "omx-rack-proof"
RATE = 48000
FIRST_INSTANCE = 1000
TONE_HZ = 1000.0
TONE = 0.1  # -20 dBFS
MEASURE_S = 2.0


BUNDLES = ["/zynthian/zynthian-plugins/lv2/guitaramp-suite.lv2", "/usr/local/lib/lv2/tuna.lv2"]


def uris_of(*bundles):
    """name -> URI of each plugin in the bundles' .ttl files; a subject is <uri> or prefix:name."""
    out = {}
    for bundle in bundles:
        for ttl in glob.glob(os.path.join(bundle, "*.ttl")):
            # long literals may hold unindented lines: out first; then one statement per unindented line
            text = re.sub(r'""".*?"""', '""', open(ttl, encoding="utf-8").read(), flags=re.S)
            prefixes = dict(re.findall(r"@prefix\s+([\w-]*):\s*<([^>]*)>", text))
            for body in re.split(r"\n(?=\S)", text):
                m = re.match(r"(?:<([^>]+)>|([\w-]*):(\S+))\s+a\s+lv2:Plugin\b", body)
                name = re.search(r'doap:name\s+"([^"]+)"', body)
                if m and name:
                    out[name.group(1)] = m.group(1) or prefixes.get(m.group(2), "") + m.group(3)
    return out


def chain_of(snapshot):
    """[(processor id, plugin name, {symbol: value})] of the first chain that has processors, in order."""
    procs = snapshot["zs3"]["zs3-0"]["processors"]
    for chain in snapshot["chains"].values():
        if chain.get("slots"):
            out = []
            for slot in chain["slots"]:
                for proc_id, code in slot.items():
                    if "/" not in code:
                        continue  # Zynthian's own mixer strip (MI)
                    ctrls = procs.get(proc_id, {}).get("controllers", {})
                    out.append((proc_id, code.split("/", 1)[1], {k: v["value"] for k, v in ctrls.items()}))
            return out
    return []


class Daemon:
    def __init__(self, port):
        self.port = port
        self.sock = None
        self.buf = b""

    def call(self, line, timeout=30.0):
        if self.sock is None:
            # the daemon serves commands once its feedback port has a reader, as mod-host does; then hello opens the
            # session (protocol 0.3, no extensions asked: plain 'resp N' replies)
            self.feedback = socket.create_connection(("127.0.0.1", self.port + 1), timeout=5)
            self.sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
            self._send("hello 1")
            hello = self._reply(10.0)
            if status(hello) != 0:
                raise ConnectionError(f"the daemon on port {self.port} does not answer hello: {hello!r}")
        self._send(line)
        return self._reply(timeout)

    def _send(self, line):
        self.sock.sendall(line.encode() + b"\0")

    def _reply(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\0" not in self.buf:
            self.sock.settimeout(max(0.1, deadline - time.monotonic()))
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionResetError("plugin-hostd closed the connection")
            self.buf += chunk
        reply, _, self.buf = self.buf.partition(b"\0")
        return reply.decode(errors="replace")


def answers(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


def status(reply):
    """The status number of a 'resp N ...' reply, or None."""
    m = re.match(r"\s*(?:@\S+\s+)?resp\s+(-?\d+)", reply)
    return int(m.group(1)) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("snapshot")
    ap.add_argument("--lever", required=True, action="append",
                    help="'Plugin Name:symbol=value': controls that, moved together, must silence the chain")
    ap.add_argument("--bundle", action="append", help="an LV2 bundle the chain's plugins are read from (repeatable)")
    ap.add_argument("--conf", default="/zynthian/config/plugin-hostd.conf")
    ap.add_argument("--port", type=int, default=5590)
    args = ap.parse_args()

    import jack
    import numpy as np

    levers = []
    for lever in args.lever:
        name, rest = lever.split(":", 1)
        levers.append((name,) + tuple(rest.split("=", 1)))
    bundles = args.bundle or BUNDLES
    uris = uris_of(*bundles)
    chain = chain_of(json.load(open(args.snapshot, encoding="utf-8")))
    if not chain:
        print(f"FAIL {args.snapshot} has no chain with processors")
        return 1
    work = tempfile.mkdtemp(prefix="rack-proof-", dir=os.path.expanduser("~"))
    env = dict(os.environ, JACK_DEFAULT_SERVER=SERVER)
    procs = []
    fails = 0
    try:
        procs.append(subprocess.Popen(["jackd", "-n", SERVER, "-d", "dummy", "-r", str(RATE), "-p", "256"],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env))
        time.sleep(1.5)
        conf = os.path.join(work, "plugin-hostd.conf")
        with open(args.conf, encoding="utf-8") as src, open(conf, "w", encoding="utf-8") as dst:
            for line in src:
                if not re.match(r"\s*state_root\b", line):
                    dst.write(line)
            dst.write(f"state_root {work}/state\n")
        log = open(os.path.join(work, "plugin-hostd.log"), "w")
        procs.append(subprocess.Popen(["plugin-hostd", "-n", "-p", str(args.port), "-f", str(args.port + 1), "-c", conf],
                                      stdout=log, stderr=subprocess.STDOUT, env=env))
        deadline = time.monotonic() + 30
        while not answers(args.port):
            if time.monotonic() > deadline or procs[-1].poll() is not None:
                print(f"FAIL plugin-hostd did not answer on port {args.port} (log {log.name})")
                return 1
            time.sleep(0.2)
        d = Daemon(args.port)

        instances = []
        for n, (proc_id, name, ctrls) in enumerate(chain):
            inst = FIRST_INSTANCE + n
            uri = uris.get(name)
            if not uri:
                print(f"FAIL {name}: not in {', '.join(bundles)}")
                return 1
            t0 = time.monotonic()
            reply = d.call(f"add {uri} {inst}", timeout=120)
            took = time.monotonic() - t0
            if status(reply) is None or status(reply) < 0:
                print(f"FAIL add {name} ({uri}): {reply!r}")
                fails += 1
                continue
            bad = []
            for sym, value in ctrls.items():
                r = d.call(f"param_set {inst} {sym} {value}")
                if status(r) is None or status(r) < 0:
                    bad.append(f"{sym}: {r}")
            print(f"{'ok  ' if not bad else 'FAIL'} {name}: added as effect_{inst} in {took:.2f} s, "
                  f"{len(ctrls) - len(bad)}/{len(ctrls)} controllers set" + (f" ({'; '.join(bad)})" if bad else ""))
            fails += bool(bad)
            instances.append((inst, name))
        if fails:
            return 1

        client = jack.Client("rack-proof", servername=SERVER)
        tone_out = client.outports.register("tone")
        ins = [client.inports.register("l"), client.inports.register("r")]
        phase = [0.0]
        acc = {"sum": np.zeros(2), "n": 0, "on": False}

        @client.set_process_callback
        def process(frames):
            t = (phase[0] + np.arange(frames)) / RATE
            tone_out.get_array()[:] = TONE * np.sin(2 * np.pi * TONE_HZ * t)
            phase[0] += frames
            if acc["on"]:
                for i, p in enumerate(ins):
                    a = p.get_array()
                    acc["sum"][i] += float(np.dot(a, a))
                acc["n"] += frames

        client.activate()

        def ports(inst, out):
            return [p.name for p in client.get_ports(f"^effect_{inst}:", is_audio=True, is_output=out, is_input=not out)]

        def wire(srcs, dsts):
            if len(srcs) == 1:
                pairs = [(srcs[0], d) for d in dsts]
            elif len(dsts) == 1:
                pairs = [(s, dsts[0]) for s in srcs]
            else:
                pairs = list(zip(srcs, dsts))
            for s, t in pairs:
                client.connect(s, t)

        prev = [tone_out.name]
        for inst, name in instances:
            wire(prev, ports(inst, False))
            prev = ports(inst, True)
        wire(prev, [p.name for p in ins])

        def level():
            time.sleep(1.0)  # the tails settle
            acc.update(sum=np.zeros(2), n=0, on=True)
            time.sleep(MEASURE_S)
            acc["on"] = False
            rms = np.sqrt(acc["sum"] / max(acc["n"], 1))
            return [20 * np.log10(max(x, 1e-12)) for x in rms]

        on = level()
        print(f"     out L {on[0]:.1f} dBFS, R {on[1]:.1f} dBFS with the tone at -20.0 dBFS")
        if max(on) < -80 or not all(np.isfinite(on)):
            print("FAIL the rack's output is silent")
            return 1
        r = []
        for name, sym, val in levers:
            inst = next((i for i, n in instances if n == name), None)
            r.append(d.call(f"param_set {inst} {sym} {val}"))
        off = level()
        drop = max(on) - max(off)
        print(f"{'ok  ' if drop >= 20 else 'FAIL'} lever {' + '.join(args.lever)}: out L {off[0]:.1f}, "
              f"R {off[1]:.1f} dBFS, {drop:.1f} dB down ({'; '.join(r)})")
        client.deactivate()
        client.close()
        return 0 if drop >= 20 else 1
    except Exception as e:
        fails += 1
        print(f"FAIL {type(e).__name__}: {e}")
        return 1
    finally:
        tail = os.path.join(work, "plugin-hostd.log")
        if os.path.exists(tail) and fails:
            print("plugin-hostd log:\n" + "".join(open(tail, errors="replace").readlines()[-20:]))
        for p in reversed(procs):
            p.terminate()
            try:
                p.wait(10)
            except subprocess.TimeoutExpired:
                p.kill()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

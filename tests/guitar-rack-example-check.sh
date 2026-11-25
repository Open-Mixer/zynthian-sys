#!/bin/bash
#******************************************************************************
# The guitar rack example (examples/guitar-rack) is held to the bundle it runs:
# guitaramp-suite.lv2 at the release scripts/recipes/install_guitaramp-suite_
# prebuilt.sh installs. Each snapshot's chain is run by plugin-hostd (every
# processor PH/), names only plugins of the bundles, each once, and sets only
# input control ports of its plugin, inside their range. The x42 tuner
# (tuna.lv2, installed by scripts/recipes/install_x42_plugins.sh) is the one
# plugin from outside the suite; Zynthian's mixer strip (MI) may close a chain.
# Each MIDI binding names a CC, a processor of its chain and a control of it.
# The README names each snapshot. The judge refuses a wrong symbol, a value out
# of range, a jalv processor, a plugin the bundles have not and a binding to a
# control the processor has not, so a pass is not an empty one.
#
# The bundles are fetched from the recipes' URLs and their sums checked, or read
# from BUNDLE_DIR (a guitaramp-suite.lv2 directory) and TUNA_DIR (a tuna.lv2
# directory) when given.
#
#   tests/guitar-rack-example-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
EXAMPLE=${EXAMPLE:-$HERE/../examples/guitar-rack}
RECIPE=$HERE/../scripts/recipes/install_guitaramp-suite_prebuilt.sh
# sha256 of guitaramp-suite-zynthian-v1.21.1-aarch64.tar.gz, the recipe's release
SUM=9886dba55fadc2f2c6c3de9539bfcfe89a16446f56cdaa591aa8c941e2cd2eba
X42_RECIPE=$HERE/../scripts/recipes/install_x42_plugins.sh
# sha256 of tuna.lv2.tar.xz as the x42 recipe fetches it (Last-Modified 2024-04-30)
TUNA_SUM=93d15486d6772c75dac2ef8db5f11c0a7362ac6f81f3dceb6906df1f79d77103

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

bundle=$BUNDLE_DIR
if [ -z "$bundle" ]; then
	url=$(bash -c 'eval "$(grep -E "^(VERSION|FVERSION|BASE_NAME|FILE_NAME|URL_DOWNLOAD)=" "$1")"; echo "$URL_DOWNLOAD"' _ "$RECIPE")
	if [ -z "$url" ]; then echo "FAIL the recipe $RECIPE names no URL_DOWNLOAD"; exit 1; fi
	if ! curl -sSfL --retry 3 -o "$work/b.tgz" "$url"; then echo "FAIL cannot fetch the bundle the recipe installs: $url"; exit 1; fi
	got=$(sha256sum "$work/b.tgz" | cut -d' ' -f1)
	if [ "$got" != "$SUM" ]; then echo "FAIL $url has sha256 $got, not the $SUM this check was written against"; exit 1; fi
	tar -xzf "$work/b.tgz" -C "$work" || { echo "FAIL cannot unpack $url"; exit 1; }
	bundle=$(find "$work" -maxdepth 2 -type d -name guitaramp-suite.lv2 | head -n 1)
fi
[ -d "$bundle" ] || { echo "FAIL no guitaramp-suite.lv2 bundle at '$bundle'"; exit 1; }

tuna=$TUNA_DIR
if [ -z "$tuna" ]; then
	base=$(sed -n 's/^BASE_URL_DOWNLOAD="\(.*\)"$/\1/p' "$X42_RECIPE")
	grep -q 'wget "$BASE_URL_DOWNLOAD/tuna.lv2.tar.xz"' "$X42_RECIPE" || { echo "FAIL $X42_RECIPE no longer fetches tuna.lv2.tar.xz"; exit 1; }
	url="$base/tuna.lv2.tar.xz"
	if ! curl -sSfL --retry 3 -o "$work/t.txz" "$url"; then echo "FAIL cannot fetch the tuner the x42 recipe installs: $url"; exit 1; fi
	got=$(sha256sum "$work/t.txz" | cut -d' ' -f1)
	if [ "$got" != "$TUNA_SUM" ]; then echo "FAIL $url has sha256 $got, not the $TUNA_SUM this check was written against"; exit 1; fi
	tar -xJf "$work/t.txz" -C "$work" || { echo "FAIL cannot unpack $url"; exit 1; }
	tuna=$work/tuna.lv2
fi
[ -d "$tuna" ] || { echo "FAIL no tuna.lv2 bundle at '$tuna'"; exit 1; }

python3 - "$bundle" "$tuna" "$EXAMPLE" <<'EOF'
import copy, glob, json, os, re, sys

bundle, tuna, example = sys.argv[1:4]
# Zynthian's mixer strip (zynthian_engine_audio_mixer): the controls a snapshot may set or bind
MIXER = {"gain": (0.0, 2.0), "level": (0.0, 1.0), "balance": (-1.0, 1.0), "mute": (0, 1), "solo": (0, 1),
         "pfl": (0, 1), "mono": (0, 1), "ms": (0, 1)}
fails = 0


def ok(what):
    print(f"ok   {what}")


def bad(what):
    global fails
    fails += 1
    print(f"FAIL {what}")


def blocks(text):
    """The outermost [ ... ] blocks of a Turtle text, each with its nested blocks (scale points) cut out."""
    out, depth, start, cut = [], 0, 0, []
    for i, ch in enumerate(text):
        if ch == "[":
            depth += 1
            if depth == 1:
                start, cut = i + 1, []
            elif depth == 2:
                cut.append(i)
        elif ch == "]" and depth:
            depth -= 1
            if depth == 1:
                cut.append(i + 1)
            elif depth == 0:
                inner, pos = [], start
                for a, b in zip(cut[::2], cut[1::2]):
                    inner.append(text[pos:a])
                    pos = b
                out.append("".join(inner) + text[pos:i])
    return out


def plugins_of(*bundles):
    """name -> {symbol: (min, max)} of each plugin's input control ports, read from the bundles' .ttl files: one
    entry per plugin subject (a file may describe several), enumeration ports included."""
    out = {}
    for bundle in bundles:
        for ttl in sorted(glob.glob(os.path.join(bundle, "*.ttl"))):
            # long literals ("""...""") may hold unindented lines and brackets: out first
            text = re.sub(r'""".*?"""', '""', open(ttl, encoding="utf-8").read(), flags=re.S)
            # one statement per unindented line; a plugin's subject is <uri> or prefix:name
            for body in re.split(r"\n(?=\S)", text):
                if not re.match(r"(<[^>]+>|[\w-]*:\S+)\s+a\s+lv2:Plugin\b", body):
                    continue
                name = re.search(r'doap:name\s+"([^"]+)"', body)
                if not name:
                    continue
                ports = {}
                for port in blocks(body):
                    if "lv2:ControlPort" not in port or "lv2:InputPort" not in port or "lv2:symbol" not in port:
                        continue
                    symbol = re.search(r'lv2:symbol\s+"([^"]+)"', port).group(1)
                    lo = re.search(r"lv2:minimum\s+([-0-9.eE]+)", port)
                    hi = re.search(r"lv2:maximum\s+([-0-9.eE]+)", port)
                    ports[symbol] = (float(lo.group(1)) if lo else None, float(hi.group(1)) if hi else None)
                out[name.group(1)] = ports
    return out


def judge(snapshot, plugins):
    """Every fault of a snapshot against the bundles, as sentences."""
    faults = []
    if snapshot.get("schema_version") != 5:
        faults.append(f"schema_version is {snapshot.get('schema_version')}, not 5")
    names = {}
    chain_of = {}
    for chain_id, chain in snapshot.get("chains", {}).items():
        for slot in chain.get("slots", []):
            for proc_id, code in slot.items():
                chain_of[proc_id] = chain_id
                if code == "MI":
                    names[proc_id] = "MI"
                    continue
                if not code.startswith("PH/"):
                    faults.append(f"processor {proc_id} is {code}: plugin-hostd runs the rack, so every processor is PH/")
                    continue
                name = code[3:]
                if name not in plugins:
                    faults.append(f"processor {proc_id} names {name}, which the bundles have not")
                elif name in names.values():
                    faults.append(f"{name} is in the rack twice")
                names[proc_id] = name
    if not [n for n in names.values() if n != "MI"]:
        faults.append("the snapshot runs no plugin")
    zs3 = snapshot.get("zs3", {}).get("zs3-0", {})
    for proc_id, state in zs3.get("processors", {}).items():
        ports = MIXER if names.get(proc_id) == "MI" else plugins.get(names.get(proc_id), {})
        for symbol, ctrl in state.get("controllers", {}).items():
            if symbol not in ports:
                faults.append(f"{names.get(proc_id)}: {symbol} is no input control port of the plugin")
                continue
            lo, hi = ports[symbol]
            value = ctrl.get("value")
            if not isinstance(value, (int, float)) or (lo is not None and value < lo) or (hi is not None and value > hi):
                faults.append(f"{names.get(proc_id)}: {symbol} = {value} is outside {lo}..{hi}")
    for chain_id, chain in zs3.get("chains", {}).items():
        if not chain.get("audio_in"):
            faults.append(f"chain {chain_id} takes no audio input")
        # a binding's key is (MIDI channel << 8) | CC, channel 0xff for any; it names [processor id, symbol]
        for key, targets in chain.get("midi_learn", {}).items():
            try:
                chan, cc = int(key) >> 8, int(key) & 0xff
            except ValueError:
                chan, cc = -1, -1
            if not (chan == 0xff or 0 <= chan < 16) or not 0 <= cc < 128:
                faults.append(f"chain {chain_id}: binding {key} is no MIDI channel and CC")
                continue
            for proc_id, symbol in targets:
                proc_id = str(proc_id)
                if chain_of.get(proc_id) != chain_id:
                    faults.append(f"chain {chain_id}: CC {cc} binds processor {proc_id}, which is not in the chain")
                    continue
                ports = MIXER if names.get(proc_id) == "MI" else plugins.get(names.get(proc_id), {})
                if symbol not in ports:
                    faults.append(f"chain {chain_id}: CC {cc} binds {names.get(proc_id)}:{symbol}, no control of it")
    return faults


plugins = plugins_of(bundle, tuna)
suite = [n for n in plugins if n.startswith("Hex ")]
if len(suite) < 10 or "x42 Instrument Tuner" not in plugins:
    bad(f"the bundles read as {len(suite)} suite plugins and {sorted(set(plugins) - set(suite))}: the reader is blind")
    sys.exit(1)
# enumeration ports (their scale points nest a [ ] in the port's) are read too
if plugins["Hex Chain Modulation"].get("mod_type") != (0.0, 8.0) or plugins["x42 Instrument Tuner"].get("mode") != (-128.0, 8000.0):
    bad("the reader misses enumeration ports (mod_type, tuner mode)")
    sys.exit(1)
ok(f"the bundles read as {len(plugins)} plugins, enumeration ports included")

files = sorted(glob.glob(os.path.join(example, "*.zss")))
if not files:
    bad(f"no snapshot in {example}")
    sys.exit(1)
readme = open(os.path.join(example, "README.md"), encoding="utf-8").read() if os.path.exists(os.path.join(example, "README.md")) else ""
first = None
for path in files:
    base = os.path.basename(path)
    snap = json.load(open(path, encoding="utf-8"))
    first = first or snap
    faults = judge(snap, plugins)
    if faults:
        bad(f"{base}: " + "; ".join(faults))
    else:
        ok(f"{base}: every processor is a plugin of the bundle run by plugin-hostd, every controller a port in range")
    if base in readme:
        ok(f"the README names {base}")
    else:
        bad(f"the README does not name {base}")

# the judge refuses what it must (on copies of the first snapshot)
def arm(what, edit, expect):
    snap = copy.deepcopy(first)
    edit(snap)
    faults = judge(snap, plugins)
    if any(expect in f for f in faults):
        ok(f"judge: {what} is refused")
    else:
        bad(f"judge: {what} passed ({faults})")


def first_proc(snap):
    procs = snap["zs3"]["zs3-0"]["processors"]
    return procs[sorted(procs)[0]]


def first_proc_id(snap):
    return sorted(snap["zs3"]["zs3-0"]["processors"])[0]


def first_slot(snap):
    chain = next(c for c in snap["chains"].values() if c["slots"])
    return chain["slots"][0]


arm("a symbol the plugin has not", lambda s: first_proc(s)["controllers"].update({"no_such_port": {"value": 0.0}}),
    "is no input control port")
arm("a value out of range", lambda s: first_proc(s)["controllers"].update(
    {next(iter(first_proc(s)["controllers"])): {"value": 1e9}}), "is outside")
arm("a jalv processor", lambda s: first_slot(s).update({k: "JV/" + v[3:] for k, v in first_slot(s).items()}),
    "every processor is PH/")
arm("a plugin the bundles have not", lambda s: first_slot(s).update({k: "PH/No Such Plugin" for k in first_slot(s)}),
    "which the bundles have not")


def bind(snap, key, target):
    chain = next(c for c in snap["zs3"]["zs3-0"]["chains"].values())
    chain.setdefault("midi_learn", {})[key] = [target]


arm("a binding to a control the plugin has not",
    lambda s: bind(s, str(0xff << 8 | 21), [int(first_proc_id(s)), "no_such_port"]),
    "no control of it")
arm("a binding to a processor of no chain", lambda s: bind(s, str(0xff << 8 | 22), [999, "enabled"]), "not in the chain")
arm("a binding with no CC", lambda s: bind(s, str(0xff << 8 | 200), [int(first_proc_id(s)), "enabled"]),
    "is no MIDI channel and CC")
arm("an enumeration value out of range", lambda s: first_proc(s)["controllers"].clear() or first_slot(s).update(
    {k: "PH/Hex Chain Modulation" for k in first_slot(s)}) or first_proc(s)["controllers"].update(
    {"mod_type": {"value": 9}}), "is outside")
sys.exit(1 if fails else 0)
EOF

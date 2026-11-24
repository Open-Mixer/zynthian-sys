#!/bin/bash
#******************************************************************************
# The guitar rack example (examples/guitar-rack) is held to the bundle it runs:
# guitaramp-suite.lv2 at the release scripts/recipes/install_guitaramp-suite_
# prebuilt.sh installs. Each snapshot's chain is run by plugin-hostd (every
# processor PH/), names only plugins of the bundle, each once, and sets only
# input control ports of its plugin, inside their range. The README names each
# snapshot. The judge refuses a wrong symbol, a value out of range, a jalv
# processor and a plugin the bundle has not, so a pass is not an empty one.
#
# The bundle is fetched from the recipe's URL and its sum checked, or read from
# BUNDLE_DIR (a guitaramp-suite.lv2 directory) when given.
#
#   tests/guitar-rack-example-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
EXAMPLE=${EXAMPLE:-$HERE/../examples/guitar-rack}
RECIPE=$HERE/../scripts/recipes/install_guitaramp-suite_prebuilt.sh
# sha256 of guitaramp-suite-zynthian-v1.21.1-aarch64.tar.gz, the recipe's release
SUM=9886dba55fadc2f2c6c3de9539bfcfe89a16446f56cdaa591aa8c941e2cd2eba

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

python3 - "$bundle" "$EXAMPLE" <<'EOF'
import copy, glob, json, os, re, sys

bundle, example = sys.argv[1:3]
fails = 0


def ok(what):
    print(f"ok   {what}")


def bad(what):
    global fails
    fails += 1
    print(f"FAIL {what}")


def plugins_of(bundle):
    """name -> {symbol: (min, max)} of each plugin's input control ports, read from the bundle's .ttl files."""
    out = {}
    for ttl in sorted(glob.glob(os.path.join(bundle, "*.ttl"))):
        text = open(ttl, encoding="utf-8").read()
        name = re.search(r'doap:name\s+"([^"]+)"', text)
        if not name or "lv2:Plugin" not in text:
            continue
        ports = {}
        for port in re.findall(r"\[([^\[\]]*?lv2:symbol[^\[\]]*?)\]", text, re.S):
            if "lv2:ControlPort" not in port or "lv2:InputPort" not in port:
                continue
            symbol = re.search(r'lv2:symbol\s+"([^"]+)"', port).group(1)
            lo = re.search(r"lv2:minimum\s+([-0-9.eE]+)", port)
            hi = re.search(r"lv2:maximum\s+([-0-9.eE]+)", port)
            ports[symbol] = (float(lo.group(1)) if lo else None, float(hi.group(1)) if hi else None)
        out[name.group(1)] = ports
    return out


def judge(snapshot, plugins):
    """Every fault of a snapshot against the bundle, as sentences."""
    faults = []
    if snapshot.get("schema_version") != 5:
        faults.append(f"schema_version is {snapshot.get('schema_version')}, not 5")
    names = {}
    for chain_id, chain in snapshot.get("chains", {}).items():
        for slot in chain.get("slots", []):
            for proc_id, code in slot.items():
                if not code.startswith("PH/"):
                    faults.append(f"processor {proc_id} is {code}: plugin-hostd runs the rack, so every processor is PH/")
                    continue
                name = code[3:]
                if name not in plugins:
                    faults.append(f"processor {proc_id} names {name}, which the bundle has not")
                elif name in names.values():
                    faults.append(f"{name} is in the rack twice")
                names[proc_id] = name
    if not names:
        faults.append("the snapshot runs no plugin")
    zs3 = snapshot.get("zs3", {}).get("zs3-0", {})
    for proc_id, state in zs3.get("processors", {}).items():
        ports = plugins.get(names.get(proc_id), {})
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
    return faults


plugins = plugins_of(bundle)
if len(plugins) < 10:
    bad(f"the bundle at {bundle} reads as {len(plugins)} plugins: the reader is blind")
    sys.exit(1)
ok(f"the bundle reads as {len(plugins)} plugins")

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


def first_slot(snap):
    chain = next(c for c in snap["chains"].values() if c["slots"])
    return chain["slots"][0]


arm("a symbol the plugin has not", lambda s: first_proc(s)["controllers"].update({"no_such_port": {"value": 0.0}}),
    "is no input control port")
arm("a value out of range", lambda s: first_proc(s)["controllers"].update(
    {next(iter(first_proc(s)["controllers"])): {"value": 1e9}}), "is outside")
arm("a jalv processor", lambda s: first_slot(s).update({k: "JV/" + v[3:] for k, v in first_slot(s).items()}),
    "every processor is PH/")
arm("a plugin the bundle has not", lambda s: first_slot(s).update({k: "PH/No Such Plugin" for k in first_slot(s)}),
    "which the bundle has not")
sys.exit(1 if fails else 0)
EOF

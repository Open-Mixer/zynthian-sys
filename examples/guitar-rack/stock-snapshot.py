#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ******************************************************************************
# A snapshot of this example for a stock Zynthian (no OpenMixer): the same chain, with every plugin-hostd processor
# (PH/) run by jalv (JV/), Zynthian's own LV2 host instead.
#
#   stock-snapshot.py SNAPSHOT OUT
#
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
# ******************************************************************************

import json
import sys


def main():
    if len(sys.argv) != 3:
        print("usage: stock-snapshot.py SNAPSHOT OUT")
        return 2
    snap = json.load(open(sys.argv[1], encoding="utf-8"))
    for chain in snap["chains"].values():
        for slot in chain.get("slots", []):
            for proc_id, code in slot.items():
                if code.startswith("PH/"):
                    slot[proc_id] = "JV/" + code[3:]
    json.dump(snap, open(sys.argv[2], "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print(f"wrote {sys.argv[2]}: the same chain, every processor JV/ (jalv), for a stock Zynthian")
    return 0


if __name__ == "__main__":
    sys.exit(main())

# The UI looks: generated from omx-panel's skins

A look is one file in `config/ui-looks/`, named after its skin: `stock.sh`, `vintage.sh`. It sets the
`ZYNTHIAN_UI_*` variables zynthian-ui reads when it starts: the sixteen colours, the font, the main menu grid's six
colours, `ZYNTHIAN_UI_LOOK` (how the controllers are drawn: `stock` is upstream's arc, `vintage` the Tk drawing) and,
for a look that draws `vintage`, the drawing's seven colours and its 42 geometry tokens (the knob's tick ring, rim,
shade, knurl, cap and pointer, the pickup marker, the switch's pill, the selector's strip, the display's glass, the
selection frame). `sbin/omx-ui-look.sh` writes a look into `zynthian_envars.sh`.

**These files are generated, never edited by hand** (the owner, 2026-11-28: Zynthian's look is configurable like a
skin, one skin definition, everything generated from it). The source of each is a skin file in omx-panel,
`skins/<skin id>/tk.json`; omx-panel declares every token it may carry, with its type, unit and range, in
`schema/tk-skin.json`, and renders the file with `omx-panel skin --library tk <skin id>` (omx-panel
`docs/looks-widget-library-and-skin.md`, section 11). The rendering's header says so and carries its pin, the sha-256
of its `KEY=value` lines, which the generator computes.

Two checks hold them:

- `tests/ui-looks-check.sh` (no omx-panel needed): each look names itself, says it is generated from its own skin,
  and its pin recomputes from its lines; `stock.sh` is zynthian-ui's own defaults; applying a look with
  `omx-ui-look.sh` writes it whole.
- `tests/ui-looks-generated-check.sh` (omx-panel needed: the installed `omx-panel`, or `OMX_PANEL` naming the command):
  every file is byte for byte what the generator prints for its skin, every skin omx-panel ships has its file and
  every file its skin. A hand edit is red, and so is a skin changed in omx-panel and not generated here again.

## Making a new look

1. **One skin file, in omx-panel.** Copy `skins/vintage/` to `skins/<id>/` (a word: `a-z`, `0-9`, `-`), set `skin`
   to `<id>` and `title` to the line the web configurator lists it by, and change the values. Every token the
   declaration names for the drawing the skin selects must be there, and no other; a missing token, an unknown one, a
   value off its type or range is refused by its name: `omx-panel skin --library tk skins/<id>` says which.
   omx-panel's `examples/house-skins/brass/tk.json` is a worked example (seven ticks over 300 degrees, a brass cap).
2. **Generate it here**, from that omx-panel:

   ```
   OMX_PANEL="node <omx-panel checkout>/bin/omx-panel.mjs" tests/ui-looks-generated-check.sh --write
   tests/ui-looks-generated-check.sh   # the same OMX_PANEL: every file equal, every skin a file
   ```

   `--write` writes `config/ui-looks/<id>.sh` for every skin that omx-panel ships with a `tk` file, and names any file
   here whose skin is gone (remove it with `git rm`). Commit the files it wrote.
3. **Select it.** On the device, `sbin/omx-ui-look.sh <id>` writes every key of the look into `zynthian_envars.sh`
   (`--keep-changed` leaves a colour set by hand); the UI reads it at its next start. The web configurator's UI page
   lists every look by its title under "Colour preset", read from this directory.

   Today the web configurator's preset carries only the sixteen colours and the font
   (zynthian-webconf `lib/ui_looks.py`, `LOOK_KEYS`): the grid's colours, `ZYNTHIAN_UI_LOOK`, the drawing's colours
   and its geometry are not written by it. Until it carries every key of the file, a look is applied whole by
   `omx-ui-look.sh`.

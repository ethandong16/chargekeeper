# Omarchy plugin

`chargekeeper.omarchy` is an Omarchy shell plugin with a bar widget
(`Panel.qml`) and a service (`Service.qml`). The service applies the automatic
charge policy; the widget shows the current mode and switches it.

## Install

From the repository root, the user-local installer copies the plugin into
place:

```bash
./install.sh
omarchy plugin enable chargekeeper.omarchy --section right
omarchy restart shell
```

From the `chargekeeper-git` package, the plugin source is at
`/usr/share/chargekeeper/omarchy`:

```bash
mkdir -p ~/.config/omarchy/plugins
cp -a /usr/share/chargekeeper/omarchy ~/.config/omarchy/plugins/chargekeeper.omarchy
omarchy plugin enable chargekeeper.omarchy --section right
omarchy restart shell
```

The installer does not edit `~/.config/omarchy/shell.json`; run
`omarchy plugin enable` yourself. Automation also needs a service record:

```json
"plugins": [{ "id": "chargekeeper.omarchy" }]
```

`omarchy plugin enable` adds the bar entry but not that second record, so keep
both. Set `"enabled": false` in `~/.config/chargekeeper/config.json` to turn
automation off without removing the service.

The plugin service and the systemd user timer apply the same policy and share
the same config and manual-override files. Run one automation owner; both at
once is redundant but idempotent.

## Bar placement

```bash
omarchy plugin enable chargekeeper.omarchy --section right
omarchy bar move chargekeeper.omarchy --section centerEnd
omarchy bar set chargekeeper.omarchy showLabel true
```

Valid sections are `left`, `centerBegin`, `center`, `centerEnd`, `tray`, and
`right`. `showLabel` adds `FAST` / `STD` / `LIFE` beside the heart glyph; the
default is `false` because the built-in power widget already shows percentage.

Mouse and keyboard controls:

- Left click opens the panel. `1` `2` `3` choose a mode, `↑`/`↓` move, `Enter`
  applies, `Esc` closes, `R` re-reads.
- Right click cycles `Standard` ↔ `Long_Life`.
- Middle click re-reads the mode.

## IPC

```bash
omarchy-shell chargekeeper.omarchy status
omarchy-shell chargekeeper.omarchy setLongLife
omarchy-shell chargekeeper.omarchy setStandard
omarchy-shell chargekeeper.omarchy setFast
omarchy-shell chargekeeper.omarchy cycle
omarchy-shell chargekeeper.omarchy open
omarchy-shell chargekeeper.omarchy refresh
```

`status` returns JSON:

```json
{
  "mode": "Standard",
  "available": ["Fast", "Standard", "Long_Life"],
  "percentage": 64,
  "onAc": true,
  "state": "charging",
  "fastAvailable": true
}
```

The setters take no argument so the IPC surface stays stable across plugin
reloads. `fastAvailable` is true only when `sudo -n -l` permits the helper
invocation. Without the helper, `setFast` reports an error and the Fast row is
dimmed.

## Settings

| Setting | Type | Default | Meaning |
|---|---|---|---|
| `showLabel` | boolean | `false` | Show the short mode label next to the bar glyph |

Set it with `omarchy bar set chargekeeper.omarchy showLabel true`, or in
`~/.config/omarchy/shell.json` under the widget's settings.

## Files

| Path | Purpose |
|---|---|
| `~/.config/omarchy/plugins/chargekeeper.omarchy/` | installed plugin |
| `~/.config/chargekeeper/config.json` | shared automation config |
| `~/.local/state/chargekeeper/manual-until` | manual override epoch |
| `/usr/lib/chargekeeper/chargekeeper-helper` | root helper used by Fast mode |

The plugin reads `/sys/class/power_supply/BAT*/charge_types` directly for the
active mode and uses UPower for `Standard` and `Long_Life`. It never writes
sysfs itself. It handles L1 only: firmware modes. Numeric thresholds and
`charge_behaviour` are CLI-only in 0.1.

## Uninstall

```bash
omarchy plugin disable chargekeeper.omarchy
./install.sh --uninstall
```

For a package install, remove the plugin folder and the shell.json entries
manually:

```bash
rm -rf ~/.config/omarchy/plugins/chargekeeper.omarchy
```

Config and state are kept by `--uninstall`. Delete
`~/.config/chargekeeper` and `~/.local/state/chargekeeper` if you want a clean
slate.

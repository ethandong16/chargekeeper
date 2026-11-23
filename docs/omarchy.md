# Omarchy plugin

`io.github.ethandong16.chargekeeper` is an Omarchy shell plugin with a bar
widget (`Panel.qml`) and a service (`Service.qml`). The service applies the
automatic charge policy; the widget shows the current mode and switches it.
The plugin lives at the repository root, so `omarchy plugin add` can install it
straight from the ChargeKeeper Git URL.

## Install

With the Omarchy plugin command:

```bash
omarchy plugin add https://github.com/ethandong16/chargekeeper --enable
omarchy restart shell
```

The repository root is the plugin folder; `omarchy plugin add` clones it to
`~/.config/omarchy/plugins/io.github.ethandong16.chargekeeper` and validates the
manifest before enabling it.

From a source checkout, the user-local installer copies the plugin files into
place together with the CLI and systemd units:

```bash
./install.sh
omarchy plugin enable io.github.ethandong16.chargekeeper --section right
omarchy restart shell
```

Fast mode needs the root helper. Either install it once from the checkout:

```bash
./install.sh --with-helper
```

or use `omarchy plugin add` for the widget and install only the helper:

```bash
sudo install -d -m 0755 /usr/lib/chargekeeper
sudo install -m 0755 -o root -g root lib/chargekeeper-helper /usr/lib/chargekeeper/chargekeeper-helper
echo '%wheel ALL=(root) NOPASSWD: /usr/lib/chargekeeper/chargekeeper-helper' \
  | sudo tee /etc/sudoers.d/chargekeeper >/dev/null
sudo chmod 0440 /etc/sudoers.d/chargekeeper
sudo visudo -cf /etc/sudoers.d/chargekeeper
```

From the `chargekeeper-git` package, the plugin source is at
`/usr/share/chargekeeper/omarchy`:

```bash
mkdir -p ~/.config/omarchy/plugins
cp -a /usr/share/chargekeeper/omarchy \
  ~/.config/omarchy/plugins/io.github.ethandong16.chargekeeper
omarchy plugin enable io.github.ethandong16.chargekeeper --section right
omarchy restart shell
```

The installer does not edit `~/.config/omarchy/shell.json`; run
`omarchy plugin enable` yourself. Automation also needs a service record:

```json
"plugins": [{ "id": "io.github.ethandong16.chargekeeper" }]
```

`omarchy plugin enable` adds the bar entry but not that second record, so keep
both. Set `"enabled": false` in `~/.config/chargekeeper/config.json` to turn
automation off without removing the service.

The plugin service and the systemd user timer apply the same policy and share
the same config and manual-override files. Run one automation owner; both at
once is redundant but idempotent.

## Bar placement

```bash
omarchy plugin enable io.github.ethandong16.chargekeeper --section right
omarchy bar move io.github.ethandong16.chargekeeper --section centerEnd
omarchy bar set io.github.ethandong16.chargekeeper showLabel true
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
omarchy-shell io.github.ethandong16.chargekeeper status
omarchy-shell io.github.ethandong16.chargekeeper setLongLife
omarchy-shell io.github.ethandong16.chargekeeper setStandard
omarchy-shell io.github.ethandong16.chargekeeper setFast
omarchy-shell io.github.ethandong16.chargekeeper cycle
omarchy-shell io.github.ethandong16.chargekeeper open
omarchy-shell io.github.ethandong16.chargekeeper refresh
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

Set it with
`omarchy bar set io.github.ethandong16.chargekeeper showLabel true`, or in
`~/.config/omarchy/shell.json` under the widget's settings.

## Files

| Path | Purpose |
|---|---|
| `~/.config/omarchy/plugins/io.github.ethandong16.chargekeeper/` | installed plugin |
| `~/.config/chargekeeper/config.json` | shared automation config |
| `~/.local/state/chargekeeper/manual-until` | manual override epoch |
| `/usr/lib/chargekeeper/chargekeeper-helper` | root helper used by Fast mode |

The plugin reads `/sys/class/power_supply/BAT*/charge_types` directly for the
active mode and uses UPower for `Standard` and `Long_Life`. It never writes
sysfs itself. It handles L1 only: firmware modes. Numeric thresholds and
`charge_behaviour` are CLI-only in 0.1.

When installed from the Git repository, the plugin folder also contains the
CLI, helper, docs, and tests from the same checkout. Only `manifest.json`,
`Panel.qml`, `Service.qml`, `Model.js`, `Policy.js`, and `i18n/` are loaded by
the shell.

## Uninstall

```bash
omarchy plugin remove io.github.ethandong16.chargekeeper
```

For a source checkout, `./install.sh --uninstall` also removes the CLI and the
systemd user units; add `--with-helper` to remove the root helper and its
sudoers rule:

```bash
./install.sh --uninstall
./install.sh --uninstall --with-helper
```

For a package install, remove the plugin folder and the `shell.json` entries
manually:

```bash
rm -rf ~/.config/omarchy/plugins/io.github.ethandong16.chargekeeper
```

Config and state are kept by `--uninstall`. Delete `~/.config/chargekeeper` and
`~/.local/state/chargekeeper` if you want a clean slate.

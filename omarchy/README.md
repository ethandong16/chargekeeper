# ChargeKeeper for Omarchy

Bar widget and service for battery charge modes and the automatic charge
policy. The panel reads modes from the kernel's `charge_types` attribute and
re-reads it after every change.

| Mode | Effect on a Lenovo ThinkBook |
|---|---|
| `Fast` | 0-80% in under an hour, 0-100% under two hours |
| `Standard` | 0-100% in 2-4 hours |
| `Long_Life` | firmware holds the battery at 75-80% |

The widget handles L1 only: it shows the firmware modes from `charge_types`.
Numeric thresholds are CLI-only in 0.1.

## Controls

- Left click: open the panel. `1` `2` `3` pick a mode, `↑`/`↓` move, `Enter`
  applies, `Esc` closes.
- Right click: cycle `Standard` ↔ `Long_Life` (never `Fast`).
- Middle click: re-read the mode.
- The bar shows a heart and no charge percentage; the built-in power widget
  already shows the level. Set `showLabel` to `true` with
  `omarchy bar set chargekeeper.omarchy showLabel true` to add `FAST` / `STD` /
  `LIFE` beside it.

`Standard` and `Long_Life` use UPower's
`org.freedesktop.UPower.Device.EnableChargeThreshold` method. UPower runs as
root, the polkit action is `allow_active=yes`, and no password is asked.

## Fast charge

UPower has no "Fast" verb, so `Fast` needs the root helper from ChargeKeeper's
core package. Install it once from the repository root:

```bash
./install.sh --with-helper
```

This installs `/usr/lib/chargekeeper/chargekeeper-helper` (root, 0755) and
`/etc/sudoers.d/chargekeeper`, validated with `visudo -cf`. The helper validates
every mode against the live `charge_types` list, writes it, and verifies the
readback. The panel probes `sudo -n -l ... mode BAT1 Fast` at startup and
disables the Fast row when the helper is absent.

Without the helper, the panel still switches `Standard` and `Long_Life`.

## Automatic policy

The service applies a policy on AC/battery transitions, inside a night window,
and once a minute. It only sets `Standard` or `Long_Life`; `Fast` remains a user
action. Manual changes from the panel write
`~/.local/state/chargekeeper/manual-until` and suppress automation for
`manualMinutes` (default 120).

Optional config at `~/.config/chargekeeper/config.json`:

```json
{
  "enabled": true,
  "acMode": "Long_Life",
  "batteryMode": "Standard",
  "acDelayMinutes": 10,
  "nightStart": "",
  "nightEnd": "",
  "manualMinutes": 120
}
```

- `acMode` / `batteryMode`: `Long_Life` or `Standard`.
- `acDelayMinutes`: wait this long after AC is attached before applying
  `acMode`; `0` applies immediately.
- `nightStart` / `nightEnd`: `HH:MM`, may cross midnight. Both empty disables
  the window; inside it the service forces `Long_Life`.
- `enabled: false`: automation off, manual control only.

The built-in `omarchy.battery` service already restores the power profile per
AC/battery (`~/.local/state/omarchy/powerprofiles/`); this plugin does not
touch power profiles.

## IPC

```bash
omarchy-shell chargekeeper.omarchy status
omarchy-shell chargekeeper.omarchy setLongLife
omarchy-shell chargekeeper.omarchy setStandard
omarchy-shell chargekeeper.omarchy setFast
omarchy-shell chargekeeper.omarchy cycle
omarchy-shell chargekeeper.omarchy open
```

The mode setters take no argument because Quickshell registers the IPC surface
once per shell process; argument-less methods stay stable across plugin reloads.

`status` returns JSON with `mode`, `available`, `percentage`, `onAc`, `state`,
and `fastAvailable`.

## Enabling and reloads

`omarchy plugin enable chargekeeper.omarchy --section right` adds the bar entry.
Automation also needs the plugin in the `plugins[]` array:

```json
"plugins": [{ "id": "chargekeeper.omarchy" }]
```

`omarchy plugin enable` does not add that second record for a plugin whose bar
entry already exists, so keep both. Set `"enabled": false` in the policy config
to switch automation off without removing the service record.

Quickshell caches plugin components and IPC handlers for the life of the shell
process. Saving QML reloads some surfaces, but a changed IPC signature or a
renamed entry point needs `omarchy restart shell` (no logout or reboot).

## Files and permissions

- `/sys/class/power_supply/BAT*/charge_types` is root-writable and
  world-readable.
- UPower device path: `/org/freedesktop/UPower/devices/battery_BAT1`, built
  from `UPower.displayDevice.nativePath` after an allowlist check.
- ChargeKeeper never uses the deprecated `conservation_mode` file.

## Tests

```bash
node --test tests/
omarchy plugin validate .
```

## Limits

- There is no numeric charge threshold when the firmware offers only modes.
  The widget also has no battery temperature or overnight-charge control.
- The service does not verify that the mode survives a reboot; the EC usually
  keeps it, but treat that as unverified.
- The panel marks a manual change for two hours. The service reasserts its
  policy at the next AC transition or night window.

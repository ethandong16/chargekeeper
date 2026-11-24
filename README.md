# ChargeKeeper

Battery charge policy for Linux laptops. ChargeKeeper has a CLI, a root helper
that validates every write, and an optional Omarchy bar widget.

The tool reports the charge controls the firmware and kernel expose. Machines
differ: some offer `Fast`, `Standard`, and `Long_Life`; others take a numeric
start and end percentage; others only expose `charge_behaviour`.

Linux only. There is no Windows or macOS support. Version 0.1 targets the
standard `power_supply` sysfs attributes and UPower.

## Scope

ChargeKeeper works at two levels:

- L1, firmware modes: `charge_types` with `Fast`, `Standard`, and `Long_Life`.
  The limit is fixed by firmware, commonly 75-80% on Lenovo non-ThinkPads.
- L2, numeric controls: `charge_control_start_threshold`,
  `charge_control_end_threshold`, and `charge_behaviour`.

A device may expose one level, both, or neither. `chargekeeper probe` reports
which; `docs/capabilities.md` explains the classes and per-vendor notes.

## What it does

- `probe`: enumerate batteries and their capabilities (human or JSON).
- `status`: charge level, power state, AC, active mode/limit/behaviour, backend.
- `mode`: set `Fast`, `Standard`, or `Long_Life`. `Standard` and `Long_Life`
  use UPower when it reports threshold support; `Fast` and any UPower fallback
  go through the root helper.
- `limit`: set an end threshold, optionally a start threshold, through the helper.
- `behaviour`: set `auto`, `inhibit-charge`, or `force-discharge` through the helper.
- `on` / `off`: toggle UPower charge-threshold limiting, unprivileged.
- `auto --once`: apply the AC/battery/night policy once; the included systemd
  user timer runs it every minute.

Every write is validated against the live supported values, read back, and
reported as a failure on mismatch. Only the helper writes sysfs directly; UPower
handles the unprivileged threshold path.

## Install

Requirements: Linux, bash 5, `jq`, UPower (for `on`/`off`, the
`Standard`/`Long_Life` preference, and device state), and a kernel driver that
exposes the battery attributes. The Omarchy plugin also needs Omarchy's
Quickshell shell; the CLI runs without Omarchy.

### Omarchy plugin

The repository root is the plugin folder: `manifest.json`, `Panel.qml`,
`Service.qml`, `Model.js`, `Policy.js`, and `i18n/`. Omarchy can add the widget
straight from this repository:

```bash
omarchy plugin add https://github.com/ethandong16/chargekeeper --enable
omarchy restart shell
```

The plugin ID is `io.github.ethandong16.chargekeeper`. `Standard` and
`Long_Life` switch through UPower without a password. `Fast`, the numeric
limit commands, and `charge_behaviour` need the root helper, which the CLI also
uses; install it once from a checkout:

```bash
./install.sh --with-helper
```

If you installed the widget with `omarchy plugin add`, the checkout is
`~/.config/omarchy/plugins/io.github.ethandong16.chargekeeper`;
`./install.sh` detects that the plugin is already in place instead of copying
over it. To install only the helper from any checkout:

```bash
sudo install -d -m 0755 /usr/lib/chargekeeper
sudo install -m 0755 -o root -g root lib/chargekeeper-helper \
  /usr/lib/chargekeeper/chargekeeper-helper
printf '%s\n' '%wheel ALL=(root) NOPASSWD: /usr/lib/chargekeeper/chargekeeper-helper' \
  | sudo tee /etc/sudoers.d/chargekeeper >/dev/null
sudo chmod 0440 /etc/sudoers.d/chargekeeper
sudo visudo -cf /etc/sudoers.d/chargekeeper
```

Remove the widget with:

```bash
omarchy plugin remove io.github.ethandong16.chargekeeper
```

Then remove the helper and sudoers rule if you installed them:

```bash
sudo rm -f /etc/sudoers.d/chargekeeper /usr/lib/chargekeeper/chargekeeper-helper
```

See `docs/omarchy.md` for controls, IPC, settings, and the automation service
record.

### Arch Linux package

```bash
cd packaging
makepkg -si
```

`chargekeeper-git` installs the CLI to `/usr/bin/chargekeeper`, the helper to
`/usr/lib/chargekeeper/chargekeeper-helper`, the plugin source to
`/usr/share/chargekeeper/omarchy`, docs to `/usr/share/doc/chargekeeper`, and
the user units to `/usr/lib/systemd/user`. It does not install a sudoers rule;
the post-install message shows the one-line rule and how to validate it with
`visudo -cf`.

### User-local install (any distribution)

From the repository root:

```bash
./install.sh               # CLI, plugin, user units, example config; no root
./install.sh --with-helper # also installs the root helper and sudoers rule
./install.sh --uninstall   # removes the user-local files
```

`install.sh` never downloads anything and fails if source files are missing.
It installs the CLI to `~/.local/bin/chargekeeper`, the plugin to
`~/.config/omarchy/plugins/io.github.ethandong16.chargekeeper`, units to
`~/.config/systemd/user`, and `~/.config/chargekeeper/config.json` if absent.
Missing directories are created with mode 0755; directories that already exist
keep their current permissions.

`--with-helper` installs `/usr/lib/chargekeeper/chargekeeper-helper` (0755
root:root) and `/etc/sudoers.d/chargekeeper`, then runs `visudo -cf`. If
validation fails it removes both files and aborts.

### Enable automation

```bash
systemctl --user daemon-reload
systemctl --user enable --now chargekeeper-auto.timer
```

The timer invokes `chargekeeper auto --once` every minute.

### Enable the Omarchy widget

`install.sh` places the plugin in the user plugin directory:

```bash
omarchy plugin enable io.github.ethandong16.chargekeeper --section right
omarchy restart shell
```

For a package install, copy the shipped source first:

```bash
mkdir -p ~/.config/omarchy/plugins
cp -a /usr/share/chargekeeper/omarchy \
  ~/.config/omarchy/plugins/io.github.ethandong16.chargekeeper
omarchy plugin enable io.github.ethandong16.chargekeeper --section right
omarchy restart shell
```

Automation through the widget also needs the plugin's service record; see
`docs/omarchy.md`. The widget service and the systemd timer read the same
config and override file. Running both is harmless but redundant; choose one
automation owner.

## CLI examples

```bash
chargekeeper probe
chargekeeper probe --json | jq '.batteries[0].capabilities'
chargekeeper status

chargekeeper mode Long_Life
chargekeeper mode Standard --battery BAT1
chargekeeper limit 80
chargekeeper limit 80 --start 75
chargekeeper behaviour inhibit-charge

chargekeeper on       # enable UPower charge threshold limiting
chargekeeper off      # allow full charge
chargekeeper auto --once
```

Exit codes: `0` success, `1` write or readback failure, `2` usage error,
`3` no supported backend.

## Configuration

`~/.config/chargekeeper/config.json`:

```json
{
  "enabled": true,
  "acMode": "Long_Life",
  "batteryMode": "Standard",
  "acLimit": 80,
  "batteryLimit": 100,
  "acDelayMinutes": 10,
  "nightStart": "",
  "nightEnd": "",
  "manualMinutes": 120
}
```

- When firmware modes exist, the policy uses `acMode` / `batteryMode`.
- When only an end threshold exists, it uses `acLimit` / `batteryLimit`.
- `acDelayMinutes` waits after AC is attached; `0` applies immediately.
- `nightStart` / `nightEnd` use `HH:MM` and may cross midnight. Inside the
  window the policy forces `Long_Life`, or `acLimit` on numeric-only hardware.
- `manualMinutes` suppresses automation after a manual change. The marker lives
  in `~/.local/state/chargekeeper/manual-until`.
- `enabled: false` disables automation.

The policy only ever applies `Standard` / `Long_Life` or a numeric limit.
`Fast` and `charge_behaviour` stay deliberate commands.

## Privilege model

- `probe` and `status` run as the user.
- `on`, `off`, and `mode Standard|Long_Life` when UPower reports threshold
  support run as the user. UPower performs the write; its polkit action is
  `allow_active=yes`, so an active local session is not prompted.
- `mode Fast`, `limit`, `behaviour`, and the `mode` fallback when UPower cannot
  write invoke `/usr/lib/chargekeeper/chargekeeper-helper` through `sudo -n`.
  The packaged rule is:

  ```
  %wheel ALL=(root) NOPASSWD: /usr/lib/chargekeeper/chargekeeper-helper
  ```

  The rule passes arguments straight to the helper, so the helper enforces the
  boundary. It accepts only `mode BAT MODE`, `limit BAT END [START]`, and
  `behaviour BAT VALUE`, validates the battery against
  `/sys/class/power_supply`, checks the value against the live supported list,
  writes the one matching attribute, and verifies the readback.
- It does not use a setuid binary or daemon, and there is no arbitrary sysfs
  write path.
- The package never installs a sudoers rule automatically.

## Capability classes and support

| Class | Surface | What ChargeKeeper can set |
|---|---|---|
| A | `charge_types` | `Fast`, `Standard`, `Long_Life` |
| B | `charge_control_end_threshold` | numeric end threshold |
| C | start + end threshold | numeric start and end thresholds |
| D | `charge_behaviour` | `auto`, `inhibit-charge`, `force-discharge` |
| E | fixed firmware limit | usually nothing numeric; modes only |

Support below comes from the kernel drivers and the TLP vendor matrix. Only the
ThinkBook in the verified table has been tested for this release.

| Vendor / family | Typical surface | ChargeKeeper support | Verified here |
|---|---|---|---|
| Lenovo ThinkPad | start + end threshold; `charge_behaviour` on many | C, D | No |
| Lenovo ThinkBook / IdeaPad | `charge_types` modes, fixed 75-80% | A (no numeric limit) | Yes |
| ASUS | end threshold 1-100; some models accept only 40/60/80 | B | No |
| Dell | start 50-95 and end 55-100; driver switches to Dell `Custom` mode | C | No |
| HP | no standard threshold in mainline for most models; BIOS-only charge control | unsupported unless `probe` shows an attribute | No |
| Huawei | TLP uses a vendor platform attribute; standard BAT attributes are not guaranteed | only if standard attributes appear | No |
| MSI | end 10-100; firmware enforces start = stop - 10; only specific models/BIOS | B | No |
| Framework / Chromebook | `cros_charge-control`: start+end and `charge_behaviour` on EC v2/v3 | C, D | No |
| LG Gram | end threshold, 80 or 100 | B (fixed values) | No |
| Samsung | vendor `battery_life_extender` at 80%, not a standard BAT attribute | not supported in 0.1 | No |

For an unlisted device, `chargekeeper probe --json` is the authoritative
answer. It reports what that machine exposes, which may differ from the table.

## Limitations

- Lenovo non-ThinkPads: the 75-80% limit is firmware-fixed. There is no numeric
  threshold to configure.
- UPower flags can lie. `ChargeThresholdSupported=true` together with
  `ChargeThresholdSettingsSupported=4` means firmware-controlled limiting only
  (no start/end percentage). UPower may also report generic values that do not
  match the firmware's real limit. ChargeKeeper treats readable sysfs values as
  the source of truth and verifies every write.
- Readback is mandatory. If the firmware accepts a write and ignores it, the
  command fails instead of reporting success.
- No recalibration, force-discharge-by-time, or `chargeonce`. Those TLP
  features are outside 0.1 scope.
- Persistence varies. Some firmware resets thresholds on boot or resume; the
  timer re-applies the policy, but only while the user session runs.
- No Windows or macOS support.
- No battery-health or temperature control.

## Verified hardware

| Model | Kernel | UPower | Surface | Result |
|---|---|---|---|---|
| Lenovo ThinkBook 16 G7+ IAH | 7.2.15-1-omarchy | 1.91.5 | `charge_types = Fast [Standard] Long_Life`; no start/end threshold; `ChargeThresholdSettingsSupported = 4` | `probe`, `status`, and Standard/Long_Life switching via UPower; `Fast` requires the helper |

## Troubleshooting

- No capabilities reported: check `ls /sys/class/power_supply/BAT*/` and the
  kernel driver. `chargekeeper probe --json` shows exactly which attributes and
  values were found.
- Fast mode unavailable: the helper or the sudoers rule is missing. Check with
  `sudo -n -l /usr/lib/chargekeeper/chargekeeper-helper mode BAT1 Fast`. Re-run
  `./install.sh --with-helper` and fix `visudo -cf` errors.
- `on` / `off` exit 3: UPower is not running or the device does not expose
  threshold support. Try `systemctl status upower`.
- Limit write fails: the requested value may be outside the driver's range or
  step (for example ASUS models that accept only 40/60/80). The error names the
  value that did not stick.
- `auto` does nothing: confirm `enabled` is true, a supported capability
  exists, and no manual override is active. Inspect with
  `journalctl --user -u chargekeeper-auto`.
- Omarchy widget missing: run `omarchy plugin validate` on the installed
  folder, then
  `omarchy plugin enable io.github.ethandong16.chargekeeper --section right`,
  and `omarchy restart shell`. Quickshell caches IPC handlers for its lifetime.
- Password prompt on every mode change: the `NOPASSWD` rule for `%wheel` is
  absent or not validated. Check `/etc/sudoers.d/chargekeeper` with
  `sudo visudo -cf`.

## Contributing

Bug reports need the output of:

```bash
chargekeeper probe --json
```

Remove serial numbers or other machine identifiers before posting. Hardware
support claims must name the model, kernel version, driver, and the exact
attributes found; do not add a vendor to the matrix from a spec sheet alone.
Shell changes must pass `bash -n`, `shellcheck`, and `tests/run.sh`.

## References

- UPower `org.freedesktop.UPower.Device`:
  <https://upower.freedesktop.org/docs/Device.html>
- TLP battery-care vendor specifics:
  <https://linrunner.de/tlp/settings/bc-vendors.html>
- Omarchy shell plugins manual:
  <https://omarchy.org/manual/shell-plugins/>

## License

MIT. See [LICENSE](LICENSE).

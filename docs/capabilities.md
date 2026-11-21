# Capabilities and hardware support

ChargeKeeper reads the kernel's standard `power_supply` attributes. If a vendor
driver does not expose them, ChargeKeeper cannot control the battery, even when
the laptop firmware has a setting in the BIOS.

## Capability classes

| Class | Attribute | How to read it | How ChargeKeeper writes it |
|---|---|---|---|
| A: firmware modes | `charge_types` | `Fast [Standard] Long_Life`; brackets mark the active mode | UPower for `Standard`/`Long_Life` when supported; helper for `Fast` or fallback |
| B: end threshold | `charge_control_end_threshold` | integer percentage | helper: `limit BAT END` |
| C: start + end threshold | `charge_control_start_threshold` and `charge_control_end_threshold` | two integers | helper: `limit BAT END START` |
| D: charge behaviour | `charge_behaviour` | `[auto] inhibit-charge force-discharge`; brackets mark the active value | helper: `behaviour BAT auto\|inhibit-charge\|force-discharge` |
| E: fixed firmware limit | no numeric attribute; a vendor mode or conservation flag | often unreadable | modes only, if class A is also present |

A machine can have more than one class. A ThinkPad may expose C and D, for
example; a ThinkBook exposes A with a firmware-fixed limit (a class E property
with no separate switch).

### Class A: modes

`charge_types` lists the offered modes with the active mode in brackets. Some
drivers omit the brackets when nothing is selected; `probe` then reports an
empty active mode rather than guessing.

UPower has no Fast verb. `Standard` and `Long_Life` can also go through UPower's
`EnableChargeThreshold(bool)` when it supports thresholds; `Fast` always needs
the helper.

### Class B/C: numeric thresholds

The driver decides the valid range and step. ChargeKeeper accepts an integer
`0..100` at the CLI, then requires the attribute to exist, writes the value,
and reads it back. A value the firmware silently ignores fails the readback.

Some drivers require a start threshold as well. `--start` is optional in the
CLI because many devices only expose an end threshold.

### Class D: charge behaviour

`charge_behaviour` is read as a space-separated list, active value bracketed.
`inhibit-charge` stops charging without changing the configured limit;
`force-discharge` discharges while on AC (hardware support varies).

### Class E: fixed firmware limits

Lenovo non-ThinkPad conservation mode, Samsung's battery-life extender, and LG's
battery-care limit are fixed values. Some appear as a numeric end threshold
(LG, class B), some as a vendor attribute, and some only as an unreadable mode.
ChargeKeeper never invents the missing percentage.

## Detection order

1. UPower. Device presence, native path, state, percentage, and
   `ChargeThresholdSupported` / `ChargeThresholdSettingsSupported`. Also the
   backend for `on`/`off`.
2. sysfs. The authoritative list of writable capabilities: `charge_types`,
   `charge_control_*_threshold`, `charge_behaviour`, and the offered values.
3. helper. Never used for detection. ChargeKeeper consults it for writes and
   probes its availability separately, so `probe` can say whether a capability
   is currently actionable. A missing helper is an installation or privilege
   problem, not a missing hardware capability.

`ChargeThresholdSettingsSupported` is a bitmask: bit 1 = start threshold, bit 2
= end threshold, bit 4 = firmware-controlled optimized charging. A value of `4`
means firmware chooses the limit, so there is no numeric threshold to set. The
ThinkBook is this case.

## Readback and trust

The active value in sysfs takes priority over UPower's generic properties:

- `charge_types` active mode is the bracketed token.
- `charge_control_end_threshold` is the written percentage.
- `charge_behaviour` active value is the bracketed token.

Every write sleeps briefly and re-reads the attribute. A mismatch exits with
code 1. UPower's `ChargeEndThreshold` may report a generic value, often 100,
even when the firmware enforces 80; it is not proof of the actual limit.

## Per-vendor notes

These notes come from Linux driver behaviour documented in the TLP vendor
matrix. They are not test results for every model.

### Lenovo ThinkPad

`thinkpad_acpi` exposes start and end thresholds on Sandy Bridge (2011) and
newer models, and `charge_behaviour` on many. Start range is 0-99, end 1-100;
0/100 disable the respective threshold. Use class C, optionally D.

### Lenovo ThinkBook / IdeaPad

`ideapad_laptop` exposes `charge_types` on kernel 6.17 and newer, and the
conservation flag on older kernels. The fixed limit is 60% or 80% depending on
the model, and Linux cannot read which one. Use class A only. This is the
verified device for 0.1.

### ASUS

`asus_wmi` exposes a stop threshold, range 1-100, 0 = off. Some laptops accept
only 40, 60, or 80 and ignore other values; the readback catches that. ASUS
resets thresholds on power-on, so the timer restores them.

### Dell

`dell_laptop` exposes start 50-95 and end 55-100; the driver switches the
battery to Dell's `Custom` charge type. The kernel requires start to be at
least 5 below stop. A BIOS admin password can block writes.

### HP

Mainline Linux generally does not expose battery charge control for HP
laptops; the setting lives in the BIOS ("Battery Health Manager"). An RFC for
`hp-wmi` charge-behaviour support was still under review in 2026. Treat HP as
unsupported unless `chargekeeper probe` finds a standard attribute.

### Huawei

TLP drives Huawei MateBooks through a vendor platform attribute
(`/sys/devices/platform/huawei-wmi/charge_control_thresholds`), and the
per-battery standard attributes are not guaranteed. ChargeKeeper 0.1 supports
the standard attributes only. Treat Huawei as unsupported unless your kernel
also exposes `charge_control_*` on `BAT*`.

### MSI

`msi_ec` exposes end threshold 10-100 and firmware enforces start = stop - 10.
Only specific models and BIOS versions are supported by the driver; an
unsupported model shows no attributes.

### Framework / Chromebook

`cros_charge-control` (kernel 6.12+, possibly 6.17 for Framework) exposes start
and end thresholds and `charge_behaviour` on EC firmware command v2/v3; v1 has
no threshold support. Framework's EC changes have broken the driver on some
firmware revisions, and `framework_tool`/`ectool` must not run simultaneously.
Check `probe` before assuming support.

### LG

`lg_laptop` exposes a standard end threshold with two useful values: 80 (on)
and 100 (off). Use `chargekeeper limit 80` or `limit 100`. Kernel 6.9 has a
regression; use 6.10.7 or newer.

### Samsung

`samsung_laptop` exposes `battery_life_extender` (80% on/off) under
`/sys/devices/platform/samsung/`, not `charge_control_end_threshold`.
ChargeKeeper 0.1 does not write vendor platform attributes, so Samsung is
unsupported.

## Verified and unverified

| Device | Kernel | UPower | Classes found | Status |
|---|---|---|---|---|
| Lenovo ThinkBook 16 G7+ IAH | 7.2.15-1-omarchy | 1.91.5 | A (fixed limit), no B/C | Verified for probe/status and Standard/Long_Life switching |
| Lenovo ThinkPad (various) | not tested | not tested | C, sometimes D | Unverified; class from driver/TLP docs |
| ASUS (various) | not tested | not tested | B | Unverified |
| Dell (various) | not tested | not tested | C | Unverified |
| HP (various) | not tested | not tested | none in mainline (BIOS-only) | Unsupported |
| Huawei MateBook | not tested | not tested | vendor attribute | Unsupported unless standard attributes appear |
| MSI (selected models) | not tested | not tested | B | Unverified |
| Framework / Chromebook | not tested | not tested | C, D | Unverified |
| LG Gram | not tested | not tested | B (80/100) | Unverified |
| Samsung | not tested | not tested | vendor attribute | Unsupported |

When reporting a new device, include the full `chargekeeper probe --json`
output: it records the attributes, ranges, and active values that matter.

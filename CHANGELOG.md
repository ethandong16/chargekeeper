# Changelog

## 0.1.0 (2026-11-21)

First release. Linux only.

- `chargekeeper` CLI: `probe`, `status`, `mode`, `limit`, `behaviour`, `on`,
  `off`, `auto --once`.
- Capability detection across `charge_types` (firmware modes),
  `charge_control_start_threshold` / `charge_control_end_threshold`, and
  `charge_behaviour`, with UPower as an additional source.
- Root helper `chargekeeper-helper` with argument validation and readback
  verification.
- Automatic AC/battery, delayed-AC, night-window, and manual-override policy,
  run by a systemd user timer.
- Omarchy bar widget and service (`chargekeeper.omarchy`): mode switching,
  status, Fast mode when the helper is installed, `showLabel` setting.
- `install.sh` for user-local installation and optional helper/sudoers setup.
- `chargekeeper-git` PKGBUILD for Arch Linux.
- Verified on a Lenovo ThinkBook 16 G7+ IAH (kernel 7.2.15, UPower 1.91.5).

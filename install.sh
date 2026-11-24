#!/usr/bin/env bash
# ChargeKeeper 0.1.0 installer.
#
# Default: user-local CLI, Omarchy plugin, systemd user units, example config.
# --with-helper: additionally installs the root helper and its sudoers rule.
# --uninstall: removes the user-local files; combine with --with-helper to
#              remove the system helper and sudoers rule too.
#
# No network access. Nothing outside $HOME is touched unless --with-helper is
# given, and then only /usr/lib/chargekeeper and /etc/sudoers.d/chargekeeper.

set -euo pipefail

readonly VERSION="0.1.1"
SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC_DIR

readonly HELPER_DEST="/usr/lib/chargekeeper/chargekeeper-helper"
readonly HELPER_DIR="/usr/lib/chargekeeper"
readonly SUDOERS_DEST="/etc/sudoers.d/chargekeeper"
readonly SUDOERS_RULE="%wheel ALL=(root) NOPASSWD: ${HELPER_DEST}"

with_helper=0
uninstall=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [--with-helper] [--uninstall]

  (no options)   Install the CLI to ~/.local/bin, the Omarchy plugin to
                 ~/.config/omarchy/plugins/io.github.ethandong16.chargekeeper,
                 the systemd user units to ~/.config/systemd/user, and an
                 example config to ~/.config/chargekeeper/config.json if absent.
  --with-helper  Also install the root helper (0755 root:root) and a
                 /etc/sudoers.d/chargekeeper rule, validated with visudo.
                 Needs sudo.
  --uninstall    Remove the user-local CLI, plugin, and units. Keeps the
                 config and state directory. Combine with --with-helper to
                 remove the system helper and sudoers rule as well.
  -h, --help     Show this help.

Nothing is downloaded; run this from the ChargeKeeper repository root.
EOF
}

fail() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

# Create each missing directory with mode 0755, leaving existing directories
# untouched. GNU `install -d -m` would also chmod directories that already
# exist, and `mkdir -p -m` only applies the mode to the deepest component.
ensure_dir() {
  local dir
  for dir in "$@"; do
    if [[ ! -d ${dir} ]]; then
      mkdir -p -- "${dir}"
      chmod 0755 -- "${dir}"
    fi
  done
}

while (($# > 0)); do
  case "$1" in
    --with-helper) with_helper=1 ;;
    --uninstall) uninstall=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
  shift
done

[[ -n ${HOME:-} ]] || fail "HOME is not set"

readonly BIN_DEST="${HOME}/.local/bin/chargekeeper"
readonly PLUGIN_DEST="${HOME}/.config/omarchy/plugins/io.github.ethandong16.chargekeeper"
readonly UNIT_DEST="${HOME}/.config/systemd/user"
readonly CONFIG_DIR="${HOME}/.config/chargekeeper"
readonly CONFIG_DEST="${CONFIG_DIR}/config.json"

require_sources() {
  local file
  for file in \
    bin/chargekeeper \
    systemd/user/chargekeeper-auto.service \
    systemd/user/chargekeeper-auto.timer \
    examples/config.json
  do
    [[ -f "${SRC_DIR}/${file}" ]] \
      || fail "missing ${file}; run install.sh from the ChargeKeeper repository root"
  done
  for file in manifest.json Panel.qml Service.qml Model.js Policy.js \
    i18n/en.json i18n/zh-CN.json
  do
    [[ -f "${SRC_DIR}/${file}" ]] \
      || fail "missing ${file}; run install.sh from the ChargeKeeper repository root"
  done
  if ((with_helper)); then
    [[ -f "${SRC_DIR}/lib/chargekeeper-helper" ]] \
      || fail "missing lib/chargekeeper-helper; run install.sh from the repository root"
  fi
}

remove_user_install() {
  if [[ -f "${UNIT_DEST}/chargekeeper-auto.timer" ]]; then
    systemctl --user disable --now chargekeeper-auto.timer >/dev/null 2>&1 || true
  fi
  rm -f -- "${BIN_DEST}" \
    "${UNIT_DEST}/chargekeeper-auto.service" \
    "${UNIT_DEST}/chargekeeper-auto.timer"
  rm -rf -- "${PLUGIN_DEST}"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  note "removed: ${BIN_DEST}"
  note "removed: ${PLUGIN_DEST}"
  note "removed: ${UNIT_DEST}/chargekeeper-auto.service"
  note "removed: ${UNIT_DEST}/chargekeeper-auto.timer"
  note "kept:    ${CONFIG_DEST} and ${HOME}/.local/state/chargekeeper"
}

remove_helper() {
  command -v sudo >/dev/null 2>&1 || fail "--with-helper needs sudo"
  if [[ -e ${SUDOERS_DEST} || -e ${HELPER_DEST} ]]; then
    sudo rm -f -- "${SUDOERS_DEST}" "${HELPER_DEST}"
    sudo rmdir --ignore-fail-on-non-empty "${HELPER_DIR}" 2>/dev/null || true
    note "removed: ${SUDOERS_DEST}"
    note "removed: ${HELPER_DEST}"
  else
    note "system helper is not installed"
  fi
}

install_user() {
  ensure_dir \
    "$(dirname -- "${BIN_DEST}")" \
    "${UNIT_DEST}" \
    "${CONFIG_DIR}" \
    "${HOME}/.config/omarchy/plugins"
  install -m 0755 "${SRC_DIR}/bin/chargekeeper" "${BIN_DEST}"

  if [[ "$(cd -- "${SRC_DIR}" && pwd -P)" == "$(cd -- "${PLUGIN_DEST}" 2>/dev/null && pwd -P)" ]]; then
    # Installed with `omarchy plugin add`: the plugin folder is this checkout.
    note "plugin already installed in place: ${PLUGIN_DEST}"
  else
    rm -rf -- "${PLUGIN_DEST}"
    ensure_dir "${PLUGIN_DEST}" "${PLUGIN_DEST}/i18n"
    install -m 0644 \
      "${SRC_DIR}/manifest.json" \
      "${SRC_DIR}/Panel.qml" \
      "${SRC_DIR}/Service.qml" \
      "${SRC_DIR}/Model.js" \
      "${SRC_DIR}/Policy.js" \
      "${PLUGIN_DEST}/"
    install -m 0644 "${SRC_DIR}/i18n/"*.json "${PLUGIN_DEST}/i18n/"
  fi

  # The packaged units use /usr/bin/chargekeeper; the user-local CLI is under
  # ~/.local/bin, so rewrite ExecStart in the installed copy.
  sed "s#/usr/bin/chargekeeper#${BIN_DEST}#g" \
    "${SRC_DIR}/systemd/user/chargekeeper-auto.service" \
    > "${UNIT_DEST}/chargekeeper-auto.service"
  install -m 0644 "${SRC_DIR}/systemd/user/chargekeeper-auto.timer" \
    "${UNIT_DEST}/chargekeeper-auto.timer"
  chmod 0644 "${UNIT_DEST}/chargekeeper-auto.service"

  if [[ -e ${CONFIG_DEST} ]]; then
    note "kept existing config: ${CONFIG_DEST}"
  else
    install -m 0644 "${SRC_DIR}/examples/config.json" "${CONFIG_DEST}"
    note "installed example config: ${CONFIG_DEST}"
  fi

  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

install_helper() {
  command -v sudo >/dev/null 2>&1 || fail "--with-helper needs sudo"
  command -v visudo >/dev/null 2>&1 || fail "visudo not found; install sudo first"

  sudo install -d -m 0755 -o root -g root "${HELPER_DIR}"
  sudo install -m 0755 -o root -g root \
    "${SRC_DIR}/lib/chargekeeper-helper" "${HELPER_DEST}"

  local tmp
  tmp=$(mktemp)
  {
    printf '# ChargeKeeper: let the wheel group run the validating root helper.\n'
    printf '# No command arguments follow the helper path, so sudoers permits any\n'
    printf '# arguments; the helper validates every action and value.\n'
    printf '%s\n' "${SUDOERS_RULE}"
  } > "${tmp}"

  if ! sudo install -m 0440 -o root -g root "${tmp}" "${SUDOERS_DEST}"; then
    rm -f -- "${tmp}"
    sudo rm -f -- "${HELPER_DEST}"
    fail "could not install ${SUDOERS_DEST}; removed ${HELPER_DEST}"
  fi
  rm -f -- "${tmp}"

  if ! sudo visudo -cf "${SUDOERS_DEST}"; then
    sudo rm -f -- "${SUDOERS_DEST}" "${HELPER_DEST}"
    fail "sudoers validation failed; removed ${SUDOERS_DEST} and ${HELPER_DEST}"
  fi

  note "installed: ${HELPER_DEST} (root:root 0755)"
  note "installed: ${SUDOERS_DEST} (root:root 0440, visudo checked)"
}

if ((uninstall)); then
  remove_user_install
  if ((with_helper)); then
    remove_helper
  fi
  note "ChargeKeeper uninstalled."
  exit 0
fi

require_sources
install_user
if ((with_helper)); then
  install_helper
fi

note ""
note "ChargeKeeper ${VERSION} installed."
note "  CLI:    ${BIN_DEST}"
note "  plugin: ${PLUGIN_DEST}"
note "  units:  ${UNIT_DEST}/chargekeeper-auto.service, .timer"
note "  config: ${CONFIG_DEST}"
note ""
note "Check the hardware: chargekeeper probe"
note "Enable automation: systemctl --user enable --now chargekeeper-auto.timer"
note "Enable the bar widget: omarchy plugin enable io.github.ethandong16.chargekeeper --section right"
case ":${PATH}:" in
  *":${HOME}/.local/bin:"*) ;;
  *) note "Add ${HOME}/.local/bin to PATH if the chargekeeper command is not found." ;;
esac
if ((with_helper == 0)); then
  note "Fast mode and numeric limits need the root helper: ./install.sh --with-helper"
fi

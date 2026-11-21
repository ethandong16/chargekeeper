#!/usr/bin/env bash
# ChargeKeeper test harness. No root, no real sysfs writes: every run points
# CHARGEKEEPER_SYSFS at a fake tree and CHARGEKEEPER_HELPER at a fake helper.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI=$ROOT/bin/chargekeeper
REAL_HELPER=$ROOT/lib/chargekeeper-helper
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$*" >&2
  if [ -n "${OUT:-}" ]; then
    printf '  output: %s\n' "$(printf '%s' "$OUT" | tr '\n' '|')" >&2
  fi
}

assert_rc() {
  local name=$1 want=$2
  if [ "$RC" -eq "$want" ]; then pass; else fail "$name: rc=$RC want=$want"; fi
}

assert_contains() {
  local name=$1 needle=$2
  case $OUT in
    *"$needle"*) pass ;;
    *) fail "$name: missing '$needle'" ;;
  esac
}

assert_eq() {
  local name=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then pass; else fail "$name: got '$got' want '$want'"; fi
}

assert_jq() {
  local name=$1 filter=$2
  if jq -e "$filter" >/dev/null 2>&1 <<< "$OUT"; then
    pass
  else
    fail "$name: jq '$filter' false"
  fi
}

SYS=""
CFG=""
STATE=""
NOW=""
OUT=""
RC=0

ck() {
  OUT=$(CHARGEKEEPER_SYSFS="$SYS" \
    CHARGEKEEPER_CONFIG="$CFG" \
    CHARGEKEEPER_STATE_DIR="$STATE" \
    CHARGEKEEPER_HELPER="$TMP/fake-helper" \
    CHARGEKEEPER_UPOWER=0 \
    CHARGEKEEPER_SUDO='' \
    CHARGEKEEPER_NOW="$NOW" \
    "$CLI" "$@" 2>&1)
  RC=$?
}

# Like ck, but UPower is enabled and comes from the fake tools. The helper is a
# script that fails if invoked, proving the UPower path was taken.
ck_upower() {
  OUT=$(PATH="$TMP/fake-upower-bin:$PATH" \
    CHARGEKEEPER_SYSFS="$SYS" \
    CHARGEKEEPER_CONFIG="$CFG" \
    CHARGEKEEPER_STATE_DIR="$STATE" \
    CHARGEKEEPER_HELPER="$TMP/upower-helper" \
    CHARGEKEEPER_SUDO='' \
    CHARGEKEEPER_NOW="$NOW" \
    FAKE_UPOWER_STATE="$TMP/upower-enabled" \
    "$CLI" "$@" 2>&1)
  RC=$?
}

# UPower fails, so the write must fall through to the bracket-rewriting helper.
ck_upower_fallback() {
  OUT=$(PATH="$TMP/fake-upower-fail-bin:$PATH" \
    CHARGEKEEPER_SYSFS="$SYS" \
    CHARGEKEEPER_CONFIG="$CFG" \
    CHARGEKEEPER_STATE_DIR="$STATE" \
    CHARGEKEEPER_HELPER="$TMP/fake-helper" \
    CHARGEKEEPER_SUDO='' \
    CHARGEKEEPER_NOW="$NOW" \
    FAKE_UPOWER_STATE="$TMP/upower-enabled" \
    "$CLI" "$@" 2>&1)
  RC=$?
}

add_battery() {
  local root=$1 name=$2 model=$3 capacity=$4 status=$5 power=$6
  mkdir -p "$root/$name"
  printf 'Battery\n' > "$root/$name/type"
  printf '%s\n' "$model" > "$root/$name/model_name"
  printf '1\n' > "$root/$name/present"
  printf '%s\n' "$capacity" > "$root/$name/capacity"
  printf '%s\n' "$status" > "$root/$name/status"
  printf '%s\n' "$power" > "$root/$name/power_now"
}

add_ac() {
  local root=$1 dir=$2 online=$3
  mkdir -p "$root/$dir"
  printf 'Mains\n' > "$root/$dir/type"
  printf '%s\n' "$online" > "$root/$dir/online"
}

make_lenovo() {
  local root=$1 active=${2:-Long_Life}
  add_battery "$root" BAT1 L24X4PG7 96 "Not charging" 0
  case $active in
    Fast) printf '[Fast] Standard Long_Life\n' > "$root/BAT1/charge_types" ;;
    Standard) printf 'Fast [Standard] Long_Life\n' > "$root/BAT1/charge_types" ;;
    *) printf 'Fast Standard [Long_Life]\n' > "$root/BAT1/charge_types" ;;
  esac
  add_ac "$root" ACAD 1
  printf '%s' "$root"
}

make_asus() {
  local root=$1 end=${2:-100}
  add_battery "$root" BAT0 "ASUS Battery" 55 Discharging 12345000
  printf '0\n' > "$root/BAT0/charge_control_start_threshold"
  printf '%s\n' "$end" > "$root/BAT0/charge_control_end_threshold"
  add_ac "$root" ACAD 0
  printf '%s' "$root"
}

make_framework() {
  local root=$1
  add_battery "$root" BAT0 "FRANMAC" 80 Charging 5000000
  printf '[auto] inhibit-charge force-discharge\n' > "$root/BAT0/charge_behaviour"
  add_ac "$root" ACAD 0
  printf '%s' "$root"
}

make_unsupported() {
  local root=$1
  add_battery "$root" BAT0 "Generic" 50 Unknown 0
  add_ac "$root" ACAD 1
  printf '%s' "$root"
}

write_config() {
  local file=$1
  shift
  jq -n "$@" > "$file"
}

# Fake root helper: validates nothing the CLI has not already checked, writes
# only inside CHARGEKEEPER_SYSFS, and honours FAKE_HELPER_NOOP=1 to simulate a
# firmware that ignores the write.
cat > "$TMP/fake-helper" <<'HELPER'
#!/usr/bin/env bash
set -u
action=${1:-}
name=${2:-}
value=${3:-}
extra=${4:-}
dir="${CHARGEKEEPER_SYSFS:?}/$name"
[ "${FAKE_HELPER_NOOP:-0}" = "1" ] && exit 0
rewrite_bracket() {
  local file=$1 want=$2 token bare out=""
  local -a tokens=()
  read -ra tokens <<< "$(cat "$file")"
  for token in "${tokens[@]}"; do
    if [[ $token == \[*\] ]]; then bare=${token:1:${#token}-2}; else bare=$token; fi
    if [ "$bare" = "$want" ]; then token="[$bare]"; else token=$bare; fi
    out+="${out:+ }$token"
  done
  printf '%s\n' "$out" > "$file"
}
case $action in
  mode) rewrite_bracket "$dir/charge_types" "$value" ;;
  limit)
    printf '%s\n' "$value" > "$dir/charge_control_end_threshold"
    if [ -n "$extra" ]; then printf '%s\n' "$extra" > "$dir/charge_control_start_threshold"; fi
    ;;
  behaviour) rewrite_bracket "$dir/charge_behaviour" "$value" ;;
  *) exit 2 ;;
esac
HELPER
chmod +x "$TMP/fake-helper"

# Fake UPower + busctl: enough surface for cmd_mode to prefer UPower. The
# EnableChargeThreshold call rewrites the fake charge_types so the CLI's
# readback succeeds; the helper below fails loudly if it is used instead.
mkdir -p "$TMP/fake-upower-bin"
cat > "$TMP/fake-upower-bin/upower" <<'UPOWER'
#!/usr/bin/env bash
case ${1:-} in
  -e) printf '%s\n' /org/freedesktop/UPower/devices/battery_BAT1 ;;
  -i)
    cat <<'INFO'
  native-path:          BAT1
  model:                Fake
  percentage:           50%
  state:                charging
  charge-threshold-supported: yes
  charge-threshold-enabled: no
INFO
    ;;
  *) exit 1 ;;
esac
UPOWER
cat > "$TMP/fake-upower-bin/busctl" <<'BUSCTL'
#!/usr/bin/env bash
action=${2:-}
last=""
for arg in "$@"; do last=$arg; done
case $action in
  call)
    printf '%s' "$last" > "${FAKE_UPOWER_STATE:?}"
    file="${CHARGEKEEPER_SYSFS:?}/BAT1/charge_types"
    case $last in
      true) printf 'Fast Standard [Long_Life]\n' > "$file" ;;
      false) printf 'Fast [Standard] Long_Life\n' > "$file" ;;
      *) exit 1 ;;
    esac
    ;;
  get-property)
    case $last in
      ChargeThresholdEnabled) printf 'b %s\n' "$(cat "${FAKE_UPOWER_STATE:?}")" ;;
      ChargeThresholdSettingsSupported) printf 'u 6\n' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
BUSCTL
cat > "$TMP/upower-helper" <<'UPHELPER'
#!/usr/bin/env bash
printf 'helper must not run when UPower handles the mode\n' >&2
exit 99
UPHELPER
chmod +x "$TMP/fake-upower-bin/upower" "$TMP/fake-upower-bin/busctl" "$TMP/upower-helper"

# Same fake UPower, but EnableChargeThreshold fails so the CLI must fall back.
mkdir -p "$TMP/fake-upower-fail-bin"
cp "$TMP/fake-upower-bin/upower" "$TMP/fake-upower-fail-bin/upower"
cat > "$TMP/fake-upower-fail-bin/busctl" <<'BUSCTLFAIL'
#!/usr/bin/env bash
if [ "${2:-}" = "get-property" ] && [ "${@: -1}" = "ChargeThresholdSettingsSupported" ]; then
  printf 'u 6\n'
  exit 0
fi
exit 1
BUSCTLFAIL
chmod +x "$TMP/fake-upower-fail-bin/upower" "$TMP/fake-upower-fail-bin/busctl"

# Static checks.
for script in "$CLI" "$REAL_HELPER"; do
  if bash -n "$script"; then pass; else fail "bash -n $script"; fi
done

# --- CLI basics -------------------------------------------------------------
SYS=$TMP/sys-none
CFG=$TMP/config-none.json
STATE=$TMP/state-none
NOW=""
OUT=$("$CLI" --version 2>&1); RC=$?
assert_rc "version" 0
assert_contains "version text" "0.1.0"
OUT=$("$CLI" --help 2>&1); RC=$?
assert_rc "help" 0
assert_contains "help usage" "chargekeeper probe"

# --- Lenovo: charge_types ---------------------------------------------------
SYS=$(make_lenovo "$TMP/sys-lenovo")
CFG=$TMP/config-none.json
STATE=$TMP/state-lenovo
ck probe --json
assert_rc "lenovo probe rc" 0
assert_jq "lenovo schema" '.schema==1'
assert_jq "lenovo backend" '.backend=="sysfs"'
assert_jq "lenovo ac" '.ac_online==true'
assert_jq "lenovo battery" '.batteries[0].name=="BAT1" and .batteries[0].model=="L24X4PG7"'
assert_jq "lenovo percentage" '.batteries[0].percentage==96'
assert_jq "lenovo modes" '.batteries[0].capabilities.modes.supported==["Fast","Standard","Long_Life"]'
assert_jq "lenovo active" '.batteries[0].capabilities.modes.active=="Long_Life"'
assert_jq "lenovo writable capability" '.batteries[0].capabilities.modes.writable==true'
assert_jq "lenovo no numeric limit" '.batteries[0].capabilities.end_threshold.supported==false'
assert_jq "lenovo no upower" '.batteries[0].upower.native_path==null'

ck status
assert_rc "lenovo status rc" 0
assert_contains "lenovo status mode" "Long_Life"
assert_contains "lenovo status percent" "96%"
ck status --json
assert_rc "lenovo status json rc" 0
assert_jq "lenovo status json mode" '.mode=="Long_Life" and .percent==96 and .ac_online==true'

ck mode Fast --battery BAT1
assert_rc "lenovo set Fast" 0
assert_eq "lenovo Fast applied" "[Fast] Standard Long_Life" "$(cat "$SYS/BAT1/charge_types")"
ck mode Standard --battery BAT1
assert_rc "lenovo set Standard" 0
assert_eq "lenovo Standard applied" "Fast [Standard] Long_Life" "$(cat "$SYS/BAT1/charge_types")"
ck mode Nonsense
assert_rc "lenovo bad mode" 2

# --- UPower preference for Standard/Long_Life -------------------------------
SYS=$(make_lenovo "$TMP/sys-upower" Standard)
CFG=$TMP/config-none.json
STATE=$TMP/state-upower
printf 'false\n' > "$TMP/upower-enabled"

ck_upower mode Long_Life --battery BAT1
assert_rc "upower mode Long_Life rc" 0
assert_contains "upower mode backend" "(UPower)"
assert_eq "upower Long_Life applied" "Fast Standard [Long_Life]" "$(cat "$SYS/BAT1/charge_types")"
assert_eq "upower enabled state" "true" "$(cat "$TMP/upower-enabled")"

ck_upower mode Standard --battery BAT1
assert_rc "upower mode Standard rc" 0
assert_eq "upower Standard applied" "Fast [Standard] Long_Life" "$(cat "$SYS/BAT1/charge_types")"
assert_eq "upower disabled state" "false" "$(cat "$TMP/upower-enabled")"

SYS=$(make_lenovo "$TMP/sys-upower-fallback" Long_Life)
CFG=$TMP/config-none.json
STATE=$TMP/state-upower-fallback
ck_upower_fallback mode Standard --battery BAT1
assert_rc "upower fallback rc" 0
assert_contains "upower fallback warning" "falling back to the helper"
assert_eq "upower fallback applied" "Fast [Standard] Long_Life" "$(cat "$SYS/BAT1/charge_types")"

# --- ASUS: numeric thresholds ----------------------------------------------
SYS=$(make_asus "$TMP/sys-asus")
CFG=$TMP/config-none.json
STATE=$TMP/state-asus
ck probe --json
assert_rc "asus probe rc" 0
assert_jq "asus end supported" '.batteries[0].capabilities.end_threshold.supported==true and .batteries[0].capabilities.end_threshold.value==100'
assert_jq "asus start supported" '.batteries[0].capabilities.start_threshold.supported==true and .batteries[0].capabilities.start_threshold.value==0'
assert_jq "asus range unknown" '.batteries[0].capabilities.end_threshold.min==null and .batteries[0].capabilities.end_threshold.max==null and .batteries[0].capabilities.start_threshold.min==null and .batteries[0].capabilities.start_threshold.max==null'
assert_jq "asus no modes" '(.batteries[0].capabilities.modes.supported|length)==0'
ck status --json
assert_jq "asus status limit" '.limit==100 and .mode==null'

ck limit 80 --battery BAT0
assert_rc "asus limit 80" 0
assert_eq "asus end 80" "80" "$(cat "$SYS/BAT0/charge_control_end_threshold")"
ck limit 080 --battery BAT0
assert_rc "asus limit 080" 0
assert_eq "asus end 080 -> 80" "80" "$(cat "$SYS/BAT0/charge_control_end_threshold")"
ck limit 100 --battery BAT0
assert_rc "asus limit 100" 0
assert_eq "asus end 100" "100" "$(cat "$SYS/BAT0/charge_control_end_threshold")"
ck limit 60 --start 20 --battery BAT0
assert_rc "asus limit start" 0
assert_eq "asus end 60" "60" "$(cat "$SYS/BAT0/charge_control_end_threshold")"
assert_eq "asus start 20" "20" "$(cat "$SYS/BAT0/charge_control_start_threshold")"

ck limit 101 --battery BAT0
assert_rc "asus limit 101" 2
assert_eq "asus unchanged after invalid" "60" "$(cat "$SYS/BAT0/charge_control_end_threshold")"
ck limit abc --battery BAT0
assert_rc "asus limit non-integer" 2
ck limit 999999999999999999999999 --battery BAT0
assert_rc "asus limit overflow" 2
assert_eq "asus unchanged after overflow" "60" "$(cat "$SYS/BAT0/charge_control_end_threshold")"
ck limit 50 --battery BAT1
assert_rc "asus unknown battery" 3
ck mode Fast --battery BAT0
assert_rc "asus mode unsupported" 3

# --- Framework: charge_behaviour -------------------------------------------
SYS=$(make_framework "$TMP/sys-framework")
CFG=$TMP/config-none.json
STATE=$TMP/state-framework
ck probe --json
assert_rc "framework probe rc" 0
assert_jq "framework behaviour" '.batteries[0].capabilities.behaviour.supported==["auto","inhibit-charge","force-discharge"] and .batteries[0].capabilities.behaviour.active=="auto"'
ck behaviour force-discharge --battery BAT0
assert_rc "framework set behaviour" 0
assert_eq "framework behaviour applied" "auto inhibit-charge [force-discharge]" "$(cat "$SYS/BAT0/charge_behaviour")"
ck behaviour bogus --battery BAT0
assert_rc "framework bad behaviour" 2

# --- No battery -------------------------------------------------------------
SYS=$TMP/sys-empty
mkdir -p "$SYS"
CFG=$TMP/config-none.json
STATE=$TMP/state-empty
ck auto --once --dry-run --json
assert_rc "auto no battery" 3
assert_contains "auto no battery message" "no battery found"

# --- Unsupported device -----------------------------------------------------
SYS=$(make_unsupported "$TMP/sys-unsupported")
CFG=$TMP/config-none.json
STATE=$TMP/state-unsupported
ck probe --json
assert_rc "unsupported probe rc" 0
assert_jq "unsupported caps" '(.batteries[0].capabilities.modes.supported|length)==0 and .batteries[0].capabilities.end_threshold.supported==false and (.batteries[0].capabilities.behaviour.supported|length)==0'
ck status
assert_rc "unsupported status rc" 0
ck mode Fast --battery BAT0
assert_rc "unsupported mode" 3
ck limit 80 --battery BAT0
assert_rc "unsupported limit" 3
ck behaviour auto --battery BAT0
assert_rc "unsupported behaviour" 3
ck on
assert_rc "upower disabled on" 3
ck off
assert_rc "upower disabled off" 3

# --- Readback mismatch ------------------------------------------------------
SYS=$(make_lenovo "$TMP/sys-mismatch" Long_Life)
CFG=$TMP/config-none.json
STATE=$TMP/state-mismatch
export FAKE_HELPER_NOOP=1
ck mode Fast --battery BAT1
assert_rc "mismatch rc" 1
assert_contains "mismatch message" "readback mismatch"
assert_eq "mismatch unchanged" "Fast Standard [Long_Life]" "$(cat "$SYS/BAT1/charge_types")"
unset FAKE_HELPER_NOOP

# Direct helper invocation without root must refuse and touch nothing. Never run
# this branch as root: the real helper would then write real sysfs.
if [ "$(id -u)" -ne 0 ]; then
  OUT=$("$REAL_HELPER" mode BAT1 Fast 2>&1); RC=$?
  if [ "$RC" -ne 0 ]; then pass; else fail "helper accepted non-root invocation"; fi
  assert_contains "helper root refusal" "must run as root"
else
  pass
fi

# --- Real helper: regression coverage through the test hook -----------------
# The real action code runs against a fake tree; only the root check is
# bypassed, and only when both CHARGEKEEPER_HELPER_TEST=1 and
# CHARGEKEEPER_TEST_SYSFS are set.
HSYS=$(make_asus "$TMP/helper-sys-asus")

real_helper() {
  OUT=$(CHARGEKEEPER_HELPER_TEST=1 CHARGEKEEPER_TEST_SYSFS="$HSYS" \
    "$REAL_HELPER" "$@" 2>&1)
  RC=$?
}

real_helper limit BAT0 80
assert_rc "helper limit 80 rc" 0
assert_contains "helper limit 80 output" "limit 80 set on BAT0"
assert_eq "helper limit 80 value" "80" "$(cat "$HSYS/BAT0/charge_control_end_threshold")"

real_helper limit BAT0 100
assert_rc "helper limit 100 rc" 0
assert_eq "helper limit 100 value" "100" "$(cat "$HSYS/BAT0/charge_control_end_threshold")"

real_helper limit BAT0 080
assert_rc "helper limit 080 rc" 0
assert_eq "helper limit 080 -> 80" "80" "$(cat "$HSYS/BAT0/charge_control_end_threshold")"

real_helper limit BAT0 101
assert_rc "helper limit 101 rc" 2
assert_eq "helper limit 101 unchanged" "80" "$(cat "$HSYS/BAT0/charge_control_end_threshold")"

real_helper limit BAT0 0100
assert_rc "helper limit four digits rc" 2
assert_eq "helper limit four digits unchanged" "80" "$(cat "$HSYS/BAT0/charge_control_end_threshold")"

real_helper limit BAT0 0
assert_rc "helper limit 0 rc" 0
assert_eq "helper limit 0 value" "0" "$(cat "$HSYS/BAT0/charge_control_end_threshold")"

real_helper limit BAT0 40 30
assert_rc "helper start+end rc" 0
assert_eq "helper start+end end" "40" "$(cat "$HSYS/BAT0/charge_control_end_threshold")"
assert_eq "helper start+end start" "30" "$(cat "$HSYS/BAT0/charge_control_start_threshold")"

real_helper limit BAT0 90 60
assert_rc "helper raise both rc" 0
assert_eq "helper raise both end" "90" "$(cat "$HSYS/BAT0/charge_control_end_threshold")"
assert_eq "helper raise both start" "60" "$(cat "$HSYS/BAT0/charge_control_start_threshold")"

# Lowering the end below the current start exercises the start-first branch.
real_helper limit BAT0 50 40
assert_rc "helper lower both rc" 0
assert_eq "helper lower both end" "50" "$(cat "$HSYS/BAT0/charge_control_end_threshold")"
assert_eq "helper lower both start" "40" "$(cat "$HSYS/BAT0/charge_control_start_threshold")"

real_helper limit BAT9 80
assert_rc "helper unknown battery rc" 3

HSYS=$(make_lenovo "$TMP/helper-sys-lenovo")
real_helper mode BAT1 Fast
assert_rc "helper mode rc" 0
assert_contains "helper mode output" "mode Fast set on BAT1"
# A plain file stores the bare value; a real driver re-renders the bracketed list.
assert_eq "helper mode applied" "Fast" "$(cat "$HSYS/BAT1/charge_types")"

HSYS=$(make_framework "$TMP/helper-sys-framework")
real_helper behaviour BAT0 inhibit-charge
assert_rc "helper behaviour rc" 0
assert_contains "helper behaviour output" "behaviour inhibit-charge set on BAT0"
assert_eq "helper behaviour applied" "inhibit-charge" "$(cat "$HSYS/BAT0/charge_behaviour")"

# The hook is inert without its sysfs variable.
OUT=$(CHARGEKEEPER_HELPER_TEST=1 "$REAL_HELPER" mode BAT1 Fast 2>&1); RC=$?
assert_rc "helper hook needs sysfs rc" 2
assert_contains "helper hook needs sysfs message" "CHARGEKEEPER_TEST_SYSFS"

# --- Policy -----------------------------------------------------------------
POLICY_NOW=1795000000
NOW=$POLICY_NOW
now_hm=$(date -d "@$POLICY_NOW" +%H:%M)
now_min=$((10#${now_hm:0:2} * 60 + 10#${now_hm:3:2}))
night_start_min=$(( (now_min - 60 + 1440) % 1440 ))
night_end_min=$(( (now_min + 60) % 1440 ))
printf -v night_start '%02d:%02d' $((night_start_min / 60)) $((night_start_min % 60))
printf -v night_end '%02d:%02d' $((night_end_min / 60)) $((night_end_min % 60))

SYS=$(make_lenovo "$TMP/sys-policy-ac" Standard)
CFG=$TMP/config-ac.json
STATE=$TMP/state-policy-ac
mkdir -p "$STATE"
printf '%s\n' $((POLICY_NOW - 600)) > "$STATE/ac-since"
# shellcheck disable=SC2016 # $acMode/$batteryMode/$delay are jq variables.
write_config "$CFG" --argjson delay 10 --argjson acMode '"Long_Life"' --argjson batteryMode '"Standard"' \
  '{enabled:true,acMode:$acMode,batteryMode:$batteryMode,acLimit:80,batteryLimit:100,acDelayMinutes:$delay,nightStart:"",nightEnd:"",manualMinutes:120}'
ck auto --once --dry-run --json
assert_rc "policy ac rc" 0
assert_jq "policy ac decision" '.action=="set" and .kind=="mode" and .target=="Long_Life" and .reason=="ac" and .current=="Standard" and .dry_run==true and .applied==false'
assert_eq "dry-run did not write" "Fast [Standard] Long_Life" "$(cat "$SYS/BAT1/charge_types")"

ck auto --once --json
assert_rc "policy ac apply rc" 0
assert_jq "policy ac applied" '.action=="set" and .kind=="mode" and .target=="Long_Life" and .applied==true'
assert_eq "policy ac written" "Fast Standard [Long_Life]" "$(cat "$SYS/BAT1/charge_types")"
ck auto --once --json
assert_jq "policy idempotent" '.action=="none" and .reason=="already"'

# AC delay.
printf '%s\n' $((POLICY_NOW - 60)) > "$STATE/ac-since"
ck auto --once --dry-run --json
assert_jq "policy delay" '.action=="none" and .reason=="delay"'
# First AC run with no state also waits.
rm -f "$STATE/ac-since"
now_keep=$NOW
ck auto --once --dry-run --json
assert_jq "policy delay no state" '.action=="none" and .reason=="delay"'
NOW=$now_keep

# Battery direction.
add_ac "$SYS" ACAD 0
printf 'Fast Standard [Long_Life]\n' > "$SYS/BAT1/charge_types"
ck auto --once --dry-run --json
assert_jq "policy battery" '.action=="set" and .kind=="mode" and .target=="Standard" and .reason=="battery"'

# Night window overrides battery mode.
add_ac "$SYS" ACAD 0
printf 'Fast [Standard] Long_Life\n' > "$SYS/BAT1/charge_types"
# shellcheck disable=SC2016 # $nightStart/$nightEnd are jq variables.
write_config "$CFG" --arg nightStart "$night_start" --arg nightEnd "$night_end" \
  '{enabled:true,acMode:"Long_Life",batteryMode:"Standard",acLimit:80,batteryLimit:100,acDelayMinutes:10,nightStart:$nightStart,nightEnd:$nightEnd,manualMinutes:120}'
ck auto --once --dry-run --json
assert_jq "policy night" '.action=="set" and .kind=="mode" and .target=="Long_Life" and .reason=="night"'

# Manual override wins over night and AC.
mkdir -p "$STATE"
printf '%s\n' $((POLICY_NOW + 600)) > "$STATE/manual-until"
ck auto --once --dry-run --json
assert_jq "policy manual" '.action=="none" and .reason=="manual"'
rm -f "$STATE/manual-until"

# Disabled automation.
write_config "$CFG" '{enabled:false,acMode:"Long_Life",batteryMode:"Standard",acLimit:80,batteryLimit:100,acDelayMinutes:10,nightStart:"",nightEnd:"",manualMinutes:120}'
ck auto --once --dry-run --json
assert_jq "policy disabled" '.action=="none" and .reason=="disabled"'

# Fast mode policy uses the helper (UPower disabled in tests).
SYS=$(make_lenovo "$TMP/sys-policy-fast" Standard)
CFG=$TMP/config-fast.json
STATE=$TMP/state-policy-fast
write_config "$CFG" '{enabled:true,acMode:"Fast",batteryMode:"Standard",acLimit:80,batteryLimit:100,acDelayMinutes:10,nightStart:"",nightEnd:"",manualMinutes:120}'
mkdir -p "$STATE"
printf '%s\n' $((POLICY_NOW - 600)) > "$STATE/ac-since"
ck auto --once --json
assert_rc "policy fast rc" 0
assert_jq "policy fast applied" '.action=="set" and .kind=="mode" and .target=="Fast" and .applied==true'
assert_eq "policy fast written" "[Fast] Standard Long_Life" "$(cat "$SYS/BAT1/charge_types")"

# Numeric policy on ASUS.
SYS=$(make_asus "$TMP/sys-policy-asus" 100)
printf '1\n' > "$SYS/ACAD/online"
CFG=$TMP/config-asus.json
STATE=$TMP/state-policy-asus
write_config "$CFG" '{enabled:true,acMode:"Long_Life",batteryMode:"Standard",acLimit:75,batteryLimit:95,acDelayMinutes:10,nightStart:"",nightEnd:"",manualMinutes:120}'
mkdir -p "$STATE"
printf '%s\n' $((POLICY_NOW - 600)) > "$STATE/ac-since"
ck auto --once --dry-run --json
assert_jq "policy numeric dry" '.action=="set" and .kind=="limit" and .target==75 and .reason=="ac" and .applied==false'
ck auto --once --json
assert_rc "policy numeric apply rc" 0
assert_jq "policy numeric applied" '.action=="set" and .kind=="limit" and .target==75 and .applied==true'
assert_eq "policy numeric written" "75" "$(cat "$SYS/BAT0/charge_control_end_threshold")"
ck auto --once --json
assert_jq "policy numeric idempotent" '.action=="none" and .reason=="already"'

# Numeric night and battery limits.
printf '100\n' > "$SYS/BAT0/charge_control_end_threshold"
add_ac "$SYS" ACAD 0
# shellcheck disable=SC2016 # $nightStart/$nightEnd are jq variables.
write_config "$CFG" --arg nightStart "$night_start" --arg nightEnd "$night_end" \
  '{enabled:true,acMode:"Long_Life",batteryMode:"Standard",acLimit:60,batteryLimit:95,acDelayMinutes:10,nightStart:$nightStart,nightEnd:$nightEnd,manualMinutes:120}'
ck auto --once --dry-run --json
assert_jq "policy numeric night" '.action=="set" and .kind=="limit" and .target==60 and .reason=="night"'
rm -f "$STATE/ac-since"
write_config "$CFG" '{enabled:true,acMode:"Long_Life",batteryMode:"Standard",acLimit:75,batteryLimit:95,acDelayMinutes:10,nightStart:"",nightEnd:"",manualMinutes:120}'
ck auto --once --dry-run --json
assert_jq "policy numeric battery" '.action=="set" and .kind=="limit" and .target==95 and .reason=="battery"'

# Night with no modes and no numeric limit is a no-op.
SYS=$(make_unsupported "$TMP/sys-policy-none")
CFG=$TMP/config-none.json
STATE=$TMP/state-policy-none
ck auto --once --dry-run --json
assert_rc "policy unsupported rc" 0
assert_jq "policy unsupported" '.action=="none" and .reason=="unsupported"'

# --- systemd units ----------------------------------------------------------
unit=$ROOT/systemd/user/chargekeeper-auto.service
timer=$ROOT/systemd/user/chargekeeper-auto.timer
if grep -qx 'ExecStart=/usr/bin/chargekeeper auto --once' "$unit"; then pass; else fail "service ExecStart"; fi
if grep -qx 'WantedBy=timers.target' "$timer"; then pass; else fail "timer WantedBy"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

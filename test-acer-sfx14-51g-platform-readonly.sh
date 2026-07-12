#!/usr/bin/env bash
set -Eeuo pipefail
MOD=acer_sfx14_51g_platform
KO=./acer-sfx14-51g-platform.ko
PDEV=/sys/bus/platform/devices/acer-sfx14-51g-platform

echo "[1/8] Removing the old overlapping experimental driver"
sudo rmmod acer_wmi_ext 2>/dev/null || sudo rmmod acer-wmi-ext 2>/dev/null || true
if lsmod | grep -qE '^acer_wmi_ext\b'; then
  echo "REFUSING: acer-wmi-ext is still loaded" >&2
  exit 1
fi

echo "[2/8] Loading $KO"
[[ -r $KO ]] || { echo "Missing $KO; run make first" >&2; exit 1; }
since=$(date --iso-8601=seconds)
if ! sudo insmod "$KO"; then
  echo "insmod failed; fresh kernel messages follow" >&2
  sudo journalctl -k --since "$since" --no-pager >&2 || true
  exit 1
fi
trap 'sudo rmmod "$MOD" 2>/dev/null || true' EXIT

if [[ ! -d $PDEV ]]; then
  echo "REFUSING: module loaded but platform driver did not bind" >&2
  sudo journalctl -k --since "$since" --no-pager >&2 || true
  exit 1
fi

echo "[3/8] Fresh kernel log"
sudo journalctl -k --since "$since" --no-pager

echo "[4/8] Platform profile (read only)"
cat /sys/firmware/acpi/platform_profile_choices
cat /sys/firmware/acpi/platform_profile

echo "[5/8] Model-specific attributes (read only)"
for f in battery_health_mode battery_calibration_mode adapter_rating_mw; do
  printf '%s=' "$f"
  cat "$PDEV/$f"
done

echo "[6/8] hwmon"
found=0
for h in /sys/class/hwmon/hwmon*; do
  [[ -r $h/name ]] || continue
  [[ $(cat "$h/name") == acer_sfx14_51g ]] || continue
  found=1
  echo "hwmon=$h"
  for f in "$h"/temp*_label "$h"/temp*_input; do
    [[ -r $f ]] && printf '%s=%s\n' "$(basename "$f")" "$(cat "$f")"
  done
done
(( found == 1 )) || { echo "No acer_sfx14_51g hwmon device" >&2; exit 1; }

echo "[7/8] Module metadata"
modinfo "$KO" | grep -E '^(name|version|depends|vermagic):'

echo "[8/8] Unload smoke test"
sudo rmmod "$MOD"
trap - EXIT
echo "PASS: getter-only load/read/unload smoke test completed"

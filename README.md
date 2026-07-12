# acer-sfx14-51g-platform v0.1.0

A deliberately model-specific out-of-tree Linux platform driver for the Acer Swift SFX14-51G.

## Current features

- Standard `platform_profile`: `quiet`, `balanced`, `performance`.
- `battery_health_mode` and `battery_calibration_mode`, both read/write with firmware read-back verification.
- `adapter_rating_mw` read-only (`100000`, nominal adapter capability, not live consumption).
- hwmon temperatures: CPU-side, GPU-side, Internal ambient.
- Exact Acer / Swift SFX14-51G DMI gate and fixed WMI methods only.

## Explicitly absent

No fan control, no tachometer claims, no raw EC access, no arbitrary WMI calls, no debugfs command interface, and no TSR5/TSR6 duplicate CPU/GPU-core sensors.

## Build

```bash
make
```

The expected module is:

```text
acer-sfx14-51g-platform.ko
```

## Critical pre-test step

The old experimental module owns overlapping interfaces. Remove it before loading this driver:

```bash
sudo rmmod acer_wmi_ext 2>/dev/null || sudo rmmod acer-wmi-ext 2>/dev/null || true
lsmod | grep -E 'acer[_-]wmi[_-]ext|acer_sfx14_51g_platform'
```

Do **not** unload the mainline `acer_wmi` driver unless a later test proves a conflict; this module is intended to coexist with it.

## First load: observe only

```bash
sudo insmod ./acer-sfx14-51g-platform.ko
dmesg --level=err,warn,info | tail -80
```

Inspect without writing anything:

```bash
cat /sys/firmware/acpi/platform_profile_choices
cat /sys/firmware/acpi/platform_profile

pdev=/sys/bus/platform/devices/acer-sfx14-51g-platform
cat "$pdev/battery_health_mode"
cat "$pdev/battery_calibration_mode"
cat "$pdev/adapter_rating_mw"

sensors
find /sys/class/hwmon -maxdepth 2 -name name -exec sh -c '
  for f; do printf "%s: " "$f"; cat "$f"; done
' sh {} + | grep -B1 -A1 acer_sfx14_51g
```

Unload test:

```bash
sudo rmmod acer_sfx14_51g_platform
dmesg --level=err,warn,info | tail -40
```

## Only after getter-only inspection succeeds

Profile writes use the standard interface:

```bash
echo quiet | sudo tee /sys/firmware/acpi/platform_profile
cat /sys/firmware/acpi/platform_profile
```

Battery writes are strict booleans and are read back from firmware before success is returned:

```bash
echo 1 | sudo tee "$pdev/battery_health_mode"
cat "$pdev/battery_health_mode"
```

Do not toggle calibration casually; it may initiate a battery calibration workflow.

## Known development caveat

Kernel subsystem APIs evolve. This first draft targets the platform-profile API shape already compiling in the existing local `acer-wmi-ext` source. If the Arch kernel headers report API differences, preserve the compiler output and patch against the exact 7.0.14 headers rather than weakening validation.

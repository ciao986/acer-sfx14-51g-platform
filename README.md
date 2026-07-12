# Acer Swift SFX14-51G Linux Platform Driver

Bring back Acer firmware features on Linux.

This driver exposes several platform features present in the firmware of the Acer Swift SFX14-51G that are normally only accessible through Acer software on Windows.

It provides standard Linux platform profiles, battery-care controls, firmware temperature sensors, and charger recognition through normal kernel interfaces instead of vendor utilities.

The goal is simple:

> Make the Acer Swift X (the SFX14-51G variant, mind you 😄) behave like an Acer Swift X under Linux.

---

## Disclaimer

This project was heavily "vibe-coded" with the assistance of Microsoft Copilot and GPT-based models.

Every exposed feature was subsequently verified through:

- ACPI analysis,
- firmware inspection,
- runtime validation,
- repeated real-hardware testing.

Nevertheless:

- this is an out-of-tree kernel module;
- it is not endorsed by Acer;
- it has not been reviewed by kernel maintainers;
- mistakes are possible.

Use at your own risk.

Keep a known-good kernel available and avoid performing firmware experiments on a machine you cannot afford to recover.

## Features

### Platform profiles

Exposes the firmware's built-in performance modes through the standard Linux `platform_profile` interface:

- Quiet
- Balanced
- Performance

Compatible with desktop environments and tools that support the kernel platform-profile API.

```bash
cat /sys/firmware/acpi/platform_profile_choices
cat /sys/firmware/acpi/platform_profile
```

Example:

```bash
echo performance | sudo tee /sys/firmware/acpi/platform_profile
```

---

### Battery Health Mode

Exposes Acer's battery-preservation feature.

When enabled, charging is limited by firmware to reduce long-term battery wear.

```bash
cat /sys/bus/platform/devices/acer-sfx14-51g-platform/battery_health_mode
```

Enable:

```bash
echo 1 | sudo tee \
/sys/bus/platform/devices/acer-sfx14-51g-platform/battery_health_mode
```

Disable:

```bash
echo 0 | sudo tee \
/sys/bus/platform/devices/acer-sfx14-51g-platform/battery_health_mode
```

---

### Battery Calibration Mode

Exposes Acer's battery calibration control.

```bash
cat /sys/bus/platform/devices/acer-sfx14-51g-platform/battery_calibration_mode
```

**Warning:** this may start a firmware-managed battery calibration workflow. Do not toggle it casually.

---

### Firmware Temperature Sensors

Four firmware-backed temperature sensors are exported through hwmon:

| Sensor | Firmware source | Description |
|---|---|---|
| CPU-side | `SEN1` / `TSR1` | CPU-side thermal sensor |
| GPU-side | `SEN2` / `TSR2` | Discrete-GPU-side thermal sensor |
| Internal ambient | `SEN4` / `TSR7` | Internal chassis/ambient sensor |
| Charger temperature | `SEN3` / `TSR3` | Firmware-labelled charger/power-area temperature |

The four underlying firmware participants were already visible to Linux through ACPI thermal zones named only `SEN1`, `SEN2`, `SEN3`, and `SEN4` under `/sys/class/thermal/`. Those generic names and changing `thermal_zoneN` paths made them difficult to identify and awkward in normal monitoring tools.
This driver (re-)exposes them under one hwmon device and gives them stable, descriptive labels.

The CPU, GPU, and ambient channels use Acer's validated BH/WMI temperature getter, with range checking, retries, and a short last-good cache for transient bad readings. Acer's BH interface does not expose `TSR3`, so the charger channel uses the firmware-defined `\_SB.PC00.LPCB.H_EC.SEN3._TMP` ACPI method instead. It receives the same range/retry/cache policy before being published through hwmon.

The firmware literally describes `SEN3` as **“Charger temperature.”** This is a temperature of the charger/power area. During testing it responded slowly to sustained CPU and GPU power, which makes it useful for observing heat around that region.

These appear automatically through standard tools such as:

```bash
sensors
```

Example:

```text
CPU-side:            62.0°C
GPU-side:            61.0°C
Internal ambient:    50.0°C
Charger temperature: 70.0°C
```

---

### Charger Recognition

The driver reads the charger rating recognized by firmware.

This is **not system power consumption**.

This is the power capability of the connected AC adapter.

Example:

```text
100 W charger -> 100000 mW
65 W charger  ->  65000 mW
No charger    ->      0 mW
```

Platform device attribute:

```bash
cat /sys/bus/platform/devices/acer-sfx14-51g-platform/adapter_rating_mw
```

The same value is also exposed through hwmon:

```text
power1_label = Connected PSU rating
power1_input = rating in microwatts
```

Example:

```text
100000000 µW = 100 W
```

---

## What this driver does NOT do

Intentionally excluded:

- Fan control
  - There are mentions of fan control in the ACPI code but the exposed fan control interface seems to reject every request
- Raw embedded-controller write access
  - This works through WMI rather than using EC calls
- Arbitrary firmware calls
- Overclocking
- Hidden Acer features that were not decoded and validated
- USB charging controls
  - Not implemented as (I think) it's already in the BIOS
- Predator-specific interfaces
  - They don't work on this model
- Unsupported Swift models

---

## Supported Hardware

Currently supported:

```text
Acer Swift SFX14-51G
```

The driver is intentionally DMI-gated and will refuse to bind on other systems.

This is deliberate.

Many Acer laptops use similar names while exposing completely different firmware interfaces.

---

## Why this driver exists

During investigation of missing Linux support for the Swift SFX14-51G, several firmware interfaces were discovered that Acer uses on Windows for:

- platform performance modes,
- battery-care features,
- thermal telemetry,
- charger identification.

These interfaces were reverse-engineered from ACPI tables and validated on real hardware.

The resulting implementation exposes those capabilities through normal Linux interfaces whenever possible.

Examples:

| Firmware feature | Linux interface |
|-----------------|----------------|
| Performance modes | `platform_profile` |
| Temperature telemetry | `hwmon` (consolidated from ACPI/BH firmware sources) |
| Charger recognition | `hwmon` + sysfs |
| Battery care | sysfs |

No Windows software is required.

---

## Build

```bash
make
```

Expected output:

```text
acer-sfx14-51g-platform.ko
```

---

## Loading

Before loading this driver, remove conflicting modules if present, e.g.:

```bash
sudo rmmod acer-wmi-ext 2>/dev/null || true
```

Load:

```bash
sudo insmod ./acer-sfx14-51g-platform.ko
```

Verify:

```bash
lsmod | grep acer_sfx14_51g_platform
```

Inspect:

```bash
pdev=/sys/bus/platform/devices/acer-sfx14-51g-platform

cat "$pdev/battery_health_mode"
cat "$pdev/battery_calibration_mode"
cat "$pdev/adapter_rating_mw"

cat /sys/firmware/acpi/platform_profile
```

---

## Validation

The repository includes a comprehensive validation script:

```text
test-acer-sfx14-51g-platform-full.sh
```

It exercises:

- platform profiles,
- battery controls,
- charger recognition,
- hwmon sensors,
- concurrent access,
- suspend/resume,
- module unload/load cycles,
- kernel log auditing,
- state restoration.

Run it after every modification:

```bash
chmod +x test-acer-sfx14-51g-platform-full.sh

./test-acer-sfx14-51g-platform-full.sh
```

The script was written specifically for this laptop and was used throughout development to validate every public feature exposed by the driver.

---

## Notes About Platform Profiles

The firmware internally maintains multiple representations of platform-profile state.

During reverse-engineering, a secondary firmware state variable was identified inside the EC and used extensively for validation and consistency checking.

This driver uses Acer's documented firmware protocol rather than directly manipulating EC state.

This keeps the implementation closer to the firmware's intended control path and reduces the risk of desynchronizing internal firmware variables.

---

## Acknowledgements

This project took heavy inspiration from https://github.com/TenSeventy7/acer-wmi-ext.

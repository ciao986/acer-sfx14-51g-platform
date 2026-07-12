#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Full validation suite for acer-sfx14-51g-platform v0.3.1
#
# Run as a normal user from the module build directory. The script uses sudo
# internally, records all output to a timestamped log, restores changed state,
# and leaves battery calibration untouched.

set -Eeuo pipefail
IFS=$'\n\t'

readonly MOD="acer_sfx14_51g_platform"
readonly KO="${KO:-./acer-sfx14-51g-platform.ko}"
readonly EXPECTED_VERSION="${EXPECTED_VERSION:-0.3.1}"
readonly PDEV="/sys/bus/platform/devices/acer-sfx14-51g-platform"
readonly PROFILE="/sys/firmware/acpi/platform_profile"
readonly PROFILE_CHOICES="/sys/firmware/acpi/platform_profile_choices"
readonly HEALTH="${PDEV}/battery_health_mode"
readonly CALIBRATION="${PDEV}/battery_calibration_mode"
readonly ADAPTER="${PDEV}/adapter_rating_mw"
readonly DO_SUSPEND="${DO_SUSPEND:-1}"
readonly DO_HEALTH_TOGGLE="${DO_HEALTH_TOGGLE:-1}"
readonly SEQUENTIAL_ROUNDS="${SEQUENTIAL_ROUNDS:-500}"
readonly CONCURRENT_WORKERS="${CONCURRENT_WORKERS:-4}"
readonly CONCURRENT_ROUNDS="${CONCURRENT_ROUNDS:-250}"
readonly LOAD_CYCLES="${LOAD_CYCLES:-20}"
readonly POST_RESUME_ROUNDS="${POST_RESUME_ROUNDS:-50}"
readonly OUT_DIR="${OUT_DIR:-.}"
readonly DO_PERM_CHECK="${DO_PERM_CHECK:-auto}"
readonly EC_IO="${EC_IO:-/sys/kernel/debug/ec/ec0/io}"
readonly PERM_OFFSET=$((0x45))

stamp=$(date +'%Y%m%d-%H%M%S')
readonly LOG_FILE="${LOG_FILE:-${OUT_DIR}/acer-sfx14-51g-platform-v0.3.1-test-${stamp}.log}"
readonly SUMMARY_FILE="${SUMMARY_FILE:-${OUT_DIR}/acer-sfx14-51g-platform-v0.3.1-test-${stamp}.summary}"

started_at=""
original_profile=""
original_health=""
original_calibration=""
original_adapter=""
hwmon=""
loaded_by_script=0
restore_profile_required=0
restore_health_required=0
cleanup_running=0
failures=0
passes=0

mkdir -p "$OUT_DIR"
touch "$LOG_FILE" "$SUMMARY_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { printf '[%s] %s\n' "$(date +'%H:%M:%S')" "$*"; }
pass() { passes=$((passes + 1)); printf 'PASS: %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf 'FAIL: %s\n' "$*" >&2; return 1; }
section() { printf '\n========== %s ==========\n' "$*"; }

module_loaded() { grep -q "^${MOD} " /proc/modules; }

read_value() {
    local path=$1
    [[ -r "$path" ]] || { printf 'Unreadable path: %s\n' "$path" >&2; return 1; }
    cat "$path"
}

valid_adapter_rating() {
    local value=$1
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    (( value >= 0 && value <= 255000 ))
}

profile_to_perm() {
    case "$1" in
        balanced) echo 1 ;;
        quiet) echo 2 ;;
        performance) echo 3 ;;
        *) return 1 ;;
    esac
}

perm_check_available() {
    case "$DO_PERM_CHECK" in
        0|no|false) return 1 ;;
        1|yes|true) return 0 ;;
        auto) sudo test -r "$EC_IO" ;;
        *) echo "Invalid DO_PERM_CHECK=$DO_PERM_CHECK" >&2; return 2 ;;
    esac
}

read_perm() {
    local raw
    raw=$(sudo dd if="$EC_IO" bs=1 skip="$PERM_OFFSET" count=1 status=none | od -An -tu1)
    raw=${raw//[[:space:]]/}
    [[ "$raw" =~ ^[0-9]+$ ]] || return 1
    (( raw >= 1 && raw <= 3 )) || {
        printf 'Invalid PERM value at EC 0x45: %s\n' "$raw" >&2
        return 1
    }
    printf '%s\n' "$raw"
}

check_profile_perm_consistency() {
    local context=$1 profile expected actual
    if ! perm_check_available; then
        if [[ "$DO_PERM_CHECK" != auto && "$DO_PERM_CHECK" != 0 &&
              "$DO_PERM_CHECK" != no && "$DO_PERM_CHECK" != false ]]; then
            echo "PERM checking requested but EC I/O is unavailable: $EC_IO" >&2
            return 1
        fi
        return 0
    fi
    profile=$(read_value "$PROFILE")
    expected=$(profile_to_perm "$profile")
    actual=$(read_perm)
    printf 'PERM context=%s profile=%s expected=%s observed=%s\n' \
        "$context" "$profile" "$expected" "$actual"
    [[ "$actual" == "$expected" ]] || {
        printf 'Profile/PERM mismatch at %s: profile=%s PERM=%s\n' \
            "$context" "$profile" "$actual" >&2
        return 1
    }
}

find_hwmon() {
    local h
    hwmon=""
    for h in /sys/class/hwmon/hwmon*; do
        [[ -r "$h/name" ]] || continue
        if [[ $(<"$h/name") == acer_sfx14_51g ]]; then
            hwmon=$h
            break
        fi
    done
    [[ -n "$hwmon" ]] || { echo 'acer_sfx14_51g hwmon device not found' >&2; return 1; }
}

write_profile() {
    local requested=$1 observed
    case "$requested" in quiet|balanced|performance) ;; *) return 1 ;; esac
    printf '%s\n' "$requested" | sudo tee "$PROFILE" >/dev/null
    observed=$(read_value "$PROFILE")
    printf 'profile requested=%s observed=%s\n' "$requested" "$observed"
    [[ "$observed" == "$requested" ]]
}

write_health() {
    local requested=$1 observed
    [[ "$requested" == 0 || "$requested" == 1 ]] || return 1
    printf '%s\n' "$requested" | sudo tee "$HEALTH" >/dev/null
    sleep 1
    observed=$(read_value "$HEALTH")
    printf 'health requested=%s observed=%s\n' "$requested" "$observed"
    [[ "$observed" == "$requested" ]]
}

restore_profile() {
    local observed
    (( restore_profile_required == 1 )) || return 0
    [[ -n "$original_profile" && -e "$PROFILE" ]] || return 1
    log "Restoring profile to ${original_profile}"
    printf '%s\n' "$original_profile" | sudo tee "$PROFILE" >/dev/null
    observed=$(read_value "$PROFILE")
    [[ "$observed" == "$original_profile" ]] || return 1
    restore_profile_required=0
}

restore_health() {
    local observed attempt
    (( restore_health_required == 1 )) || return 0
    [[ -n "$original_health" && -e "$HEALTH" ]] || return 1
    log "Restoring health mode to ${original_health}"
    for attempt in 1 2 3; do
        if printf '%s\n' "$original_health" | sudo tee "$HEALTH" >/dev/null; then
            sleep 1
            observed=$(read_value "$HEALTH")
            if [[ "$observed" == "$original_health" ]]; then
                restore_health_required=0
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

cleanup() {
    local status=${1:-$?} cleanup_failed=0
    (( cleanup_running == 0 )) || return
    cleanup_running=1
    trap - EXIT ERR INT TERM

    restore_health || { echo 'CRITICAL: health restoration failed' >&2; cleanup_failed=1; }
    restore_profile || { echo 'CRITICAL: profile restoration failed' >&2; cleanup_failed=1; }

    if (( loaded_by_script == 1 )) && module_loaded; then
        sudo rmmod "$MOD" || cleanup_failed=1
    fi

    if (( status != 0 && failures == 0 )); then
        failures=1
    fi

    {
        echo "log_file=$LOG_FILE"
        echo "started_at=$started_at"
        echo "finished_at=$(date --iso-8601=seconds)"
        echo "passes=$passes"
        echo "failures=$failures"
        echo "cleanup_failed=$cleanup_failed"
        echo "exit_status=$status"
    } > "$SUMMARY_FILE"

    printf '\nLog: %s\nSummary: %s\n' "$LOG_FILE" "$SUMMARY_FILE"
    if (( status != 0 || failures != 0 || cleanup_failed != 0 )); then exit 1; fi
    exit 0
}

on_signal() {
    echo 'Interrupted; restoring original state.' >&2
    failures=$((failures + 1))
    cleanup 130
}

check_static_source() {
    local source=./acer-sfx14-51g-platform.c bad
    [[ -r "$source" ]] || { echo 'Source file not found; skipping source checks'; return 0; }
    bad=$(grep -InE 'debugfs|misc_register|unlocked_ioctl|proc_create|ec_write|ioremap|outb|request_region' "$source" || true)
    [[ -z "$bad" ]] || { printf '%s\n' "$bad" >&2; return 1; }
    grep -q 'MODULE_VERSION("0.3.1")' "$source"
    ! grep -qE 'BATTERY_SET_ATTEMPTS|BATTERY_VERIFY_ATTEMPTS|response\.result' "$source"
}

check_interfaces() {
    local choices
    [[ -d "$PDEV" ]]
    for p in "$PROFILE" "$PROFILE_CHOICES" "$HEALTH" "$CALIBRATION" "$ADAPTER"; do [[ -r "$p" ]]; done
    choices=$(read_value "$PROFILE_CHOICES")
    [[ "$choices" == 'quiet balanced performance' ]]
    find_hwmon
    printf 'platform_device=%s\nhwmon=%s\n' "$PDEV" "$hwmon"
}

check_state_unchanged_except_health() {
    [[ $(read_value "$CALIBRATION") == "$original_calibration" ]]
    [[ $(read_value "$PROFILE") == "$original_profile" ]]
    valid_adapter_rating "$(read_value "$ADAPTER")"
}

check_temperatures_once() {
    local n label value
    local -a expected_labels=(
        "CPU-side"
        "GPU-side"
        "Internal ambient"
        "Charger temperature"
    )
    find_hwmon
    for n in 1 2 3 4; do
        label=$(read_value "$hwmon/temp${n}_label")
        [[ "$label" == "${expected_labels[n-1]}" ]]
        value=$(read_value "$hwmon/temp${n}_input")
        [[ "$value" =~ ^[0-9]+$ ]]
        (( value >= 10000 && value <= 120000 ))
        printf 'temp%d %s=%d mC (%d.%03d C)\n' "$n" "$label" "$value" "$((value/1000))" "$((value%1000))"
    done
}

check_psu_hwmon_once() {
    local adapter_mw power_uw label
    find_hwmon
    adapter_mw=$(read_value "$ADAPTER")
    power_uw=$(read_value "$hwmon/power1_input")
    label=$(read_value "$hwmon/power1_label")
    valid_adapter_rating "$adapter_mw"
    [[ "$power_uw" =~ ^[0-9]+$ ]]
    [[ "$power_uw" == $((adapter_mw * 1000)) ]]
    [[ "$label" == 'Connected PSU rating' ]]
    printf 'power1 %s=%d uW (%d.%03d W)\n' \
        "$label" "$power_uw" "$((power_uw / 1000000))" \
        "$(((power_uw % 1000000) / 1000))"
}

sequential_stress() {
    local i n value count=0
    find_hwmon
    for ((i=1; i<=SEQUENTIAL_ROUNDS; i++)); do
        for n in 1 2 3 4; do
            value=$(read_value "$hwmon/temp${n}_input")
            [[ "$value" =~ ^[0-9]+$ ]]
            (( value >= 10000 && value <= 120000 ))
            count=$((count + 1))
        done
        read_value "$PROFILE" >/dev/null
        read_value "$HEALTH" >/dev/null
        read_value "$CALIBRATION" >/dev/null
        valid_adapter_rating "$(read_value "$ADAPTER")"
        read_value "$hwmon/power1_input" >/dev/null
        sleep 0.02
    done
    printf 'sequential_temperature_reads=%d\n' "$count"
}

concurrent_stress() {
    local worker i pid concurrent_failures=0
    local -a pids=()
    find_hwmon
    for ((worker=1; worker<=CONCURRENT_WORKERS; worker++)); do
        (
            for ((i=1; i<=CONCURRENT_ROUNDS; i++)); do
                cat "$hwmon/temp1_input" >/dev/null &&
                cat "$hwmon/temp2_input" >/dev/null &&
                cat "$hwmon/temp3_input" >/dev/null &&
                cat "$hwmon/temp4_input" >/dev/null &&
                cat "$PROFILE" >/dev/null &&
                cat "$HEALTH" >/dev/null &&
                cat "$CALIBRATION" >/dev/null &&
                valid_adapter_rating "$(cat "$ADAPTER")" &&
                cat "$hwmon/power1_input" >/dev/null || exit 1
            done
            printf 'worker=%d passed\n' "$worker"
        ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid" || concurrent_failures=$((concurrent_failures + 1)); done
    printf 'concurrent_failures=%d\n' "$concurrent_failures"
    (( concurrent_failures == 0 ))
}

kernel_log_audit() {
    local journal bad
    journal=$(sudo journalctl -k --since "$started_at" --no-pager)
    printf '\n--- Driver and PM kernel messages ---\n'
    grep -Ei 'acer-sfx14|suspend|resume' <<<"$journal" || true
    bad=$(grep -E 'ACPI Error|ACPI Warning|WMI.*(error|failed)|BUG:|WARNING:|lockdep|hung task|use-after-free|refcount' <<<"$journal" || true)
    [[ -z "$bad" ]] || { printf '\nConcerning kernel messages:\n%s\n' "$bad" >&2; return 1; }
}

main() {
    local version choices requested alternate before_resume_profile after_resume_profile i cycle_since

    started_at=$(date --iso-8601=seconds)
    trap 'on_signal' INT TERM
    trap 'cleanup $?' EXIT

    section 'PREFLIGHT'
    [[ $EUID -ne 0 ]] || { echo 'Run as normal user, not with sudo.' >&2; return 1; }
    command -v sudo >/dev/null
    command -v modinfo >/dev/null
    command -v journalctl >/dev/null
    [[ -r "$KO" ]] || { echo "Missing module: $KO" >&2; return 1; }
    version=$(modinfo -F version "$KO")
    printf 'module=%s version=%s expected=%s\n' "$KO" "$version" "$EXPECTED_VERSION"
    [[ "$version" == "$EXPECTED_VERSION" ]]
    sudo -v
    check_static_source && pass 'source safety/version checks'

    sudo rmmod acer_wmi_ext 2>/dev/null || true
    sudo rmmod acer_bh_readonly_probe 2>/dev/null || true
    if grep -qE '^(acer_wmi_ext|acer_bh_readonly_probe) ' /proc/modules; then return 1; fi

    if ! module_loaded; then
        sudo insmod "$KO"
        loaded_by_script=1
    fi
    check_interfaces && pass 'module load, bind, and interface discovery'

    original_profile=$(read_value "$PROFILE")
    original_health=$(read_value "$HEALTH")
    original_calibration=$(read_value "$CALIBRATION")
    original_adapter=$(read_value "$ADAPTER")
    restore_profile_required=1
    restore_health_required=1
    printf 'baseline profile=%s health=%s calibration=%s adapter=%s\n' "$original_profile" "$original_health" "$original_calibration" "$original_adapter"
    [[ "$original_profile" =~ ^(quiet|balanced|performance)$ ]]
    [[ "$original_health" =~ ^[01]$ ]]
    [[ "$original_calibration" =~ ^[01]$ ]]
    valid_adapter_rating "$original_adapter"

    section 'GETTERS AND HWMON'
    check_temperatures_once
    check_psu_hwmon_once
    check_profile_perm_consistency baseline
    pass 'basic getters, temperature/PSU hwmon, and profile context'
    sequential_stress && pass 'sequential getter stress'
    concurrent_stress && pass 'concurrent getter stress'

    section 'PLATFORM PROFILE NO-OP AND FULL CYCLE'
    write_profile "$original_profile"
    check_state_unchanged_except_health
    pass 'profile no-op write and read-back'
    for requested in quiet balanced performance; do
        write_profile "$requested"
        sleep 2
        [[ $(read_value "$PROFILE") == "$requested" ]]
        [[ $(read_value "$HEALTH") == "$original_health" ]]
        [[ $(read_value "$CALIBRATION") == "$original_calibration" ]]
        check_profile_perm_consistency "profile-${requested}"
        check_temperatures_once
        check_psu_hwmon_once
    done
    restore_profile
    pass 'profile cycle quiet/balanced/performance and restoration'

    section 'BATTERY HEALTH NO-OP'
    write_health "$original_health"
    check_state_unchanged_except_health
    pass 'battery-health no-op write and read-back'

    if [[ "$DO_HEALTH_TOGGLE" == 1 ]]; then
        section 'BATTERY HEALTH TOGGLE AND RESTORE'
        if [[ "$original_health" == 1 ]]; then alternate=0; else alternate=1; fi
        write_health "$alternate"
        check_state_unchanged_except_health
        check_temperatures_once
        restore_health
        [[ $(read_value "$HEALTH") == "$original_health" ]]
        pass "battery-health transition ${original_health}->${alternate}->${original_health}"
    else
        echo 'SKIP: health toggle disabled with DO_HEALTH_TOGGLE=0'
    fi

    section 'BOOLEAN COMPATIBILITY AND INVALID INPUT REJECTION'
    # kstrtobool() intentionally keys off accepted leading forms.  Therefore
    # strings such as "17" are valid true inputs, not malformed inputs.
    # Exercise representative accepted forms, restoring the baseline after.
    for requested in 1 17 yes true turbo on; do
        printf '%s\n' "$requested" | sudo tee "$HEALTH" >/dev/null
        sleep 1
        [[ $(read_value "$HEALTH") == 1 ]] || {
            echo "Accepted true form did not read back as 1: $requested" >&2
            return 1
        }
    done
    for requested in 0 00 no false off; do
        printf '%s\n' "$requested" | sudo tee "$HEALTH" >/dev/null
        sleep 1
        [[ $(read_value "$HEALTH") == 0 ]] || {
            echo "Accepted false form did not read back as 0: $requested" >&2
            return 1
        }
    done
    write_health "$original_health"

    # These start with no accepted Boolean token and must be rejected.
    for requested in 2 7 maybe invalid banana; do
        if printf '%s\n' "$requested" | sudo tee "$HEALTH" >/dev/null 2>&1; then
            echo "Invalid health input accepted: $requested" >&2
            return 1
        fi
    done
    [[ $(read_value "$HEALTH") == "$original_health" ]]

    for requested in turbo ultra 7; do
        if printf '%s\n' "$requested" | sudo tee "$PROFILE" >/dev/null 2>&1; then
            echo "Invalid profile accepted: $requested" >&2
            return 1
        fi
    done
    [[ $(read_value "$PROFILE") == "$original_profile" ]]
    pass 'Boolean compatibility forms accepted; genuinely invalid inputs rejected'

    if [[ "$DO_SUSPEND" == 1 ]]; then
        section 'SUSPEND/RESUME'
        before_resume_profile=$(read_value "$PROFILE")
        sync
        log 'Suspending now; wake the machine normally.'
        sudo systemctl suspend
        printf '\nResume detected. Wait until the system is fully awake, then press Enter to continue.\n'
        IFS= read -r _
        sleep 2
        module_loaded
        check_interfaces
        after_resume_profile=$(read_value "$PROFILE")
        printf 'profile before_resume=%s after_resume=%s\n' "$before_resume_profile" "$after_resume_profile"
        [[ $(read_value "$HEALTH") == "$original_health" ]]
        [[ $(read_value "$CALIBRATION") == "$original_calibration" ]]
        check_profile_perm_consistency post-resume
        check_psu_hwmon_once
        for ((i=1; i<=POST_RESUME_ROUNDS; i++)); do
            check_temperatures_once >/dev/null
            check_psu_hwmon_once >/dev/null
        done
        pass 'suspend/resume state and post-resume getters'
    else
        echo 'SKIP: suspend disabled with DO_SUSPEND=0'
    fi

    section 'LOAD/UNLOAD CYCLES'
    restore_health
    restore_profile
    for ((i=1; i<=LOAD_CYCLES; i++)); do
        cycle_since=$(date --iso-8601=seconds)
        sudo rmmod "$MOD"
        if ! sudo insmod "$KO"; then
            printf 'FAIL: insmod failed on load cycle %d/%d\n' "$i" "$LOAD_CYCLES" >&2
            sudo journalctl -k --since "$cycle_since" --no-pager >&2 || true
            return 1
        fi
        [[ -d "$PDEV" ]]
        cat "$PROFILE" "$HEALTH" "$CALIBRATION" "$ADAPTER" >/dev/null
        find_hwmon
        cat "$hwmon/temp1_input" "$hwmon/temp2_input" \
            "$hwmon/temp3_input" "$hwmon/temp4_input" \
            "$hwmon/power1_input" >/dev/null
    done
    pass "${LOAD_CYCLES} unload/load cycles"

    section 'FINAL STATE AND LOG AUDIT'
    [[ $(read_value "$PROFILE") == "$original_profile" ]]
    [[ $(read_value "$HEALTH") == "$original_health" ]]
    [[ $(read_value "$CALIBRATION") == "$original_calibration" ]]
    valid_adapter_rating "$(read_value "$ADAPTER")"
    check_temperatures_once
    check_psu_hwmon_once
    check_profile_perm_consistency final
    kernel_log_audit
    pass 'final state restoration and clean kernel log'

    printf '\nALL TESTS PASSED: %d checks\n' "$passes"
}

main "$@"

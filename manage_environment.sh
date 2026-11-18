
#!/usr/bin/env bash
set -euo pipefail

CPU_ROOT="/sys/devices/system/cpu"
STATE_DIR="/var/lib/manage_env"
STATE_FILE="$STATE_DIR/original_state.tsv"

NUMA_FILE="/proc/sys/kernel/numa_balancing"
PARANOID_FILE="/proc/sys/kernel/perf_event_paranoid"

usage() {
    echo "Usage: sudo $0 {set_env|reset_env}"
    exit 1
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Require root privileges
[[ $EUID -eq 0 ]] || die "Run with sudo/root."
[[ $# -eq 1 ]] || usage

# Protect the backup from other users
[[ ! -L "$STATE_DIR" ]] || die "State directory is a symlink."
mkdir -p "$STATE_DIR"
[[ $(stat -c %u "$STATE_DIR") == 0 ]] ||
    die "State directory must be root-owned."
chmod 700 "$STATE_DIR"

[[ ! -L "$STATE_FILE" ]] || die "State file is a symlink."

# Prevent simultaneous set/reset operations
exec 9>"$STATE_DIR/.lock"
flock -x 9

tmp=""
trap 'if [[ -n "$tmp" ]]; then rm -f "$tmp"; fi' EXIT

set_env() {
    echo "========== SET ENVIRONMENT =========="

    # Never overwrite the original backup
    if [[ -e "$STATE_FILE" ]]; then
        die "Backup already exists at $STATE_FILE. Run reset_env first."
    fi

    echo "Saving original configuration..."

    tmp=$(mktemp "$STATE_DIR/.state.XXXXXX")
    cpu_count=0

    # Save ALL settings before modifying anything
    {
        printf 'NUMA\t%s\n' "$(cat "$NUMA_FILE")"
        printf 'PARANOID\t%s\n' "$(cat "$PARANOID_FILE")"

        for cpu_dir in "$CPU_ROOT"/cpu[0-9]*; do
            [[ -d "$cpu_dir" ]] || continue

            cpu=$(basename "$cpu_dir")
            gov_file="$cpu_dir/cpufreq/scaling_governor"
            available_file="$cpu_dir/cpufreq/scaling_available_governors"

            if [[ ! -r "$gov_file" ]]; then
                echo "WARNING: $cpu has no accessible CPU governor." >&2
                continue
            fi

            # Check whether performance is supported
            if [[ -r "$available_file" ]]; then
                available=$(cat "$available_file")
                if [[ " $available " != *" performance "* ]]; then
                    die "Performance governor not supported on $cpu."
                fi
            fi

            governor=$(cat "$gov_file")
            printf 'CPU\t%s\t%s\n' "$cpu" "$governor"

            ((cpu_count += 1))
        done
    } > "$tmp"

    ((cpu_count > 0)) || die "No CPU governors found."

    # Atomically publish the saved configuration
    mv "$tmp" "$STATE_FILE"
    tmp=""

    echo "Saved $cpu_count CPU governors."
    echo "Backup: $STATE_FILE"

    echo
    echo "Setting CPU governors to performance..."

    for cpu_dir in "$CPU_ROOT"/cpu[0-9]*; do
        gov_file="$cpu_dir/cpufreq/scaling_governor"
        [[ -f "$gov_file" ]] || continue

        echo performance > "$gov_file"
    done

    echo "Setting kernel paranoid to -1..."
    echo -1 > "$PARANOID_FILE"

    echo "Disabling AutoNUMA..."
    echo 0 > "$NUMA_FILE"

    echo
    echo "========== NEW CONFIGURATION =========="
    echo "CPU governor: performance"
    echo "Kernel paranoid: $(cat "$PARANOID_FILE")"
    echo "AutoNUMA: $(cat "$NUMA_FILE")"
    echo "Backup retained at: $STATE_FILE"
    echo "======================================="

    echo "Environment configured successfully."
}

reset_env() {
    echo "========== RESET ENVIRONMENT =========="

    [[ -f "$STATE_FILE" ]] ||
        die "No saved configuration found at $STATE_FILE"

    echo "Reading saved configuration..."

    saved_numa=""
    saved_paranoid=""
    cpus=()
    governors=()

    # Read saved values as data, not executable shell code
    while IFS=$'\t' read -r kind field1 field2 extra; do
        [[ -z "${extra:-}" ]] ||
            die "Invalid extra fields in backup."

        case "$kind" in
            NUMA)
                [[ "$field1" =~ ^[0-9]+$ && -z "$field2" ]] ||
                    die "Invalid saved AutoNUMA value."
                saved_numa="$field1"
                ;;
            PARANOID)
                [[ "$field1" =~ ^-?[0-9]+$ && -z "$field2" ]] ||
                    die "Invalid saved paranoid value."
                saved_paranoid="$field1"
                ;;
            CPU)
                [[ "$field1" =~ ^cpu[0-9]+$ ]] ||
                    die "Invalid CPU identifier."
                [[ "$field2" =~ ^[a-zA-Z0-9_-]+$ ]] ||
                    die "Invalid CPU governor."
                cpus+=("$field1")
                governors+=("$field2")
                ;;
            *)
                die "Unknown entry in backup: $kind"
                ;;
        esac
    done < "$STATE_FILE"

    [[ -n "$saved_numa" && -n "$saved_paranoid" ]] ||
        die "Incomplete saved kernel settings."

    (( ${#cpus[@]} > 0 )) ||
        die "No saved CPU governors."

    errors=0

    echo "Restoring CPU governors..."

    for i in "${!cpus[@]}"; do
        cpu="${cpus[$i]}"
        governor="${governors[$i]}"
        gov_file="$CPU_ROOT/$cpu/cpufreq/scaling_governor"

        if [[ -f "$gov_file" ]] &&
           printf '%s\n' "$governor" > "$gov_file"; then

            if [[ $(cat "$gov_file") == "$governor" ]]; then
                echo "$cpu -> $governor"
            else
                echo "FAILED verification: $cpu" >&2
                errors=1
            fi
        else
            echo "FAILED restoring $cpu" >&2
            errors=1
        fi
    done

    echo "Restoring kernel paranoid to $saved_paranoid..."
    if ! printf '%s\n' "$saved_paranoid" > "$PARANOID_FILE"; then
        errors=1
    elif [[ $(cat "$PARANOID_FILE") != "$saved_paranoid" ]]; then
        errors=1
    fi

    echo "Restoring AutoNUMA to $saved_numa..."
    if ! printf '%s\n' "$saved_numa" > "$NUMA_FILE"; then
        errors=1
    elif [[ $(cat "$NUMA_FILE") != "$saved_numa" ]]; then
        errors=1
    fi

    if (( errors != 0 )); then
        echo "ERROR: Some settings could not be restored." >&2
        echo "Backup preserved: $STATE_FILE"
        exit 1
    fi

    # Remove backup only after successful restoration
    rm -- "$STATE_FILE"

    echo
    echo "========== RESTORED CONFIGURATION =========="
    echo "Restored ${#cpus[@]} CPU governors."
    echo "Kernel paranoid: $(cat "$PARANOID_FILE")"
    echo "AutoNUMA: $(cat "$NUMA_FILE")"
    echo "============================================"

    echo "Original environment restored successfully."
}

case "$1" in
    set_env)
        set_env
        ;;
    reset_env)
        reset_env
        ;;
    *)
        usage
        ;;
esac

#!/bin/bash

echo "======================================"
echo " Current CPU Governors"
echo "======================================"

printf "%-10s %-15s\n" "CPU" "Governor"
echo "--------------------------------------"

for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    [[ -d "$cpu" ]] || continue

    cpu_id=$(basename "$cpu")

    if [[ -f "$cpu/cpufreq/scaling_governor" ]]; then
        governor=$(cat "$cpu/cpufreq/scaling_governor")
    else
        governor="N/A"
    fi

    printf "%-10s %-15s\n" "$cpu_id" "$governor"
done

echo "======================================"
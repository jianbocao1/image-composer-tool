#!/bin/bash
#
# Intel Embodied Intelligence SDK
# Copyright (c) Intel Corporation, 2026
# v2026.1
#

MIN_FREQ_PATH="/sys/class/drm/card0/device/tile0/gt0/freq0/min_freq"
MAX_FREQ_PATH="/sys/class/drm/card0/device/tile0/gt0/freq0/max_freq"
BACKUP_FILE="/var/tmp/gpu_min_freq_backup"

start_service() {
    if [ ! -f "$MIN_FREQ_PATH" ] || [ ! -f "$MAX_FREQ_PATH" ]; then
        echo "GPU frequency control files not found"
        exit 1
    fi
    
    current_min_freq=$(cat "$MIN_FREQ_PATH")
    echo "$current_min_freq" > "$BACKUP_FILE"
    echo "Saved current min_freq: $current_min_freq"
    
    max_freq=$(cat "$MAX_FREQ_PATH")
    echo "Max freq: $max_freq"
    
    echo "$max_freq" > "$MIN_FREQ_PATH"
    echo "Set min_freq to max_freq: $max_freq"
    
    new_min_freq=$(cat "$MIN_FREQ_PATH")
    echo "Current min_freq after setting: $new_min_freq"
}

stop_service() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "Backup file not found, cannot restore"
        exit 1
    fi
    
    original_min_freq=$(cat "$BACKUP_FILE")
    echo "$original_min_freq" > "$MIN_FREQ_PATH"
    echo "Restored min_freq to original value: $original_min_freq"
    
    rm -f "$BACKUP_FILE"
    echo "Cleanup completed"
}

case "$1" in
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac
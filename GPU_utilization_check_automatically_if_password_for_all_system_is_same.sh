#!/bin/bash

# Define IP addresses and usernames
declare -A SYSTEMS=(
    ["192.168.0.102"]="seclva10"
    ["192.168.0.103"]="seclva3"
    ["192.168.0.107"]="seclva8"
    # so on 
)
#password is same for all system
PASSWORD="secl@123"
LOG_FILE="gpu_monitor.log"
OUTPUT_FILE="gpu_monitor_report.txt"
TABLE_FILE="/tmp/gpu_table.txt"

MONITOR_DURATION=5   # ✅ Fixed: Now 30 seconds
SAMPLE_INTERVAL=2

> "$TABLE_FILE"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Check sshpass
if ! command -v sshpass &>/dev/null; then
    log_message "sshpass missing… installing…"
    sudo apt-get update && sudo apt-get install -y sshpass >>"$LOG_FILE" 2>&1
fi

# Report header
> "$OUTPUT_FILE"
echo "========================================" | tee -a "$OUTPUT_FILE"
echo "GPU Monitoring Report" | tee -a "$OUTPUT_FILE"
echo "Monitoring Duration: $MONITOR_DURATION seconds per server" | tee -a "$OUTPUT_FILE"
echo "Sample Interval: $SAMPLE_INTERVAL seconds" | tee -a "$OUTPUT_FILE"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$OUTPUT_FILE"
echo "========================================" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

monitor_gpu_usage() {
    local ip=$1
    local user=$2

    log_message "Starting GPU monitoring on $user@$ip"
    echo "========== $user@$ip ==========" | tee -a "$OUTPUT_FILE"

    local temp_file="/tmp/gpu_${ip//./_}.txt"

    REMOTE_SCRIPT=$(cat <<'EOF'
#!/bin/bash
if ! command -v nvidia-smi &>/dev/null; then
    echo "NO_GPU"
    exit 1
fi

GPU_COUNT=$(nvidia-smi -L | wc -l)
echo "GPU_COUNT=$GPU_COUNT"

# Function to sample all GPUs at once
sample_gpus() {
    nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu \
    --format=csv,noheader,nounits
}

SAMPLES=$((30 / 2))  # Hardcoded to avoid quoting issues

for i in $(seq 1 $SAMPLES); do
    sample_gpus | while IFS=',' read -r idx util mem_used mem_total temp; do
        echo "GPU_${idx}:${util}:${mem_used}:${mem_total}:${temp}"
    done
    sleep 2
done
EOF
)

    if sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$user@$ip" "bash -s" <<< "$REMOTE_SCRIPT" > "$temp_file" 2>>"$LOG_FILE"; then
        local ssh_exit_code=$?

        if [ $ssh_exit_code -ne 0 ]; then
            echo "SSH connection failed" | tee -a "$OUTPUT_FILE"
            return 1
        fi

        if grep -q "NO_GPU" "$temp_file"; then
            echo "No GPU found" | tee -a "$OUTPUT_FILE"
            return 0
        fi

        # Get GPU count from first line
        local gpu_count=$(grep "GPU_COUNT=" "$temp_file" | head -1 | cut -d'=' -f2)

        if [ -z "$gpu_count" ] || [ "$gpu_count" -eq 0 ]; then
            echo "No GPUs detected" | tee -a "$OUTPUT_FILE"
            return 0
        fi

        echo "GPU Count: $gpu_count" | tee -a "$OUTPUT_FILE"

        # Process each GPU
        for ((gpu_id=0; gpu_id<gpu_count; gpu_id++)); do
            # Extract all samples for this GPU
            samples=$(grep "GPU_${gpu_id}:" "$temp_file" | cut -d':' -f2-)

            if [ -z "$samples" ]; then
                echo "GPU $gpu_id: No data collected" | tee -a "$OUTPUT_FILE"
                continue
            fi

            # Calculate averages
            total_util=0
            total_mem_used=0
            total_temp=0
            sample_count=0

            while IFS=':' read -r util mem_used mem_total temp; do
                total_util=$(echo "$total_util + $util" | bc)
                total_mem_used=$(echo "$total_mem_used + $mem_used" | bc)
                total_temp=$(echo "$total_temp + $temp" | bc)
                sample_count=$((sample_count + 1))
                # Get mem_total from first sample (should be constant)
                if [ $sample_count -eq 1 ]; then
                    mem_total_value=$mem_total
                fi
            done <<< "$samples"

            avg_util=$(echo "scale=2; $total_util / $sample_count" | bc)
            avg_mem_used=$(echo "scale=0; $total_mem_used / $sample_count" | bc)
            avg_temp=$(echo "scale=2; $total_temp / $sample_count" | bc)

            printf "GPU %d → Util: %.2f%% | Mem: %.0f/%.0f MB | Temp: %.2f°C\n" \
            "$gpu_id" "$avg_util" "$avg_mem_used" "$mem_total_value" "$avg_temp" | tee -a "$OUTPUT_FILE"

            # Store for table
            echo "$user|$ip|GPU_$gpu_id|$avg_util|${avg_mem_used}/${mem_total_value}|$avg_temp" >> "$TABLE_FILE"
        done

        return 0
    else
        echo "FAILED: $user@$ip - SSH connection error" | tee -a "$OUTPUT_FILE"
        return 1
    fi
}

echo "Starting GPU monitoring..."
SUCCESS=0
FAIL=0

for ip in "${!SYSTEMS[@]}"; do
    USERNAME="${SYSTEMS[$ip]}"

    echo "----------------------------------------" | tee -a "$OUTPUT_FILE"
    echo "Monitoring: $USERNAME@$ip" | tee -a "$OUTPUT_FILE"

    if monitor_gpu_usage "$ip" "$USERNAME"; then
        ((SUCCESS++))
    else
        ((FAIL++))
    fi

    echo "----------------------------------------" | tee -a "$OUTPUT_FILE"
done

# Summary
echo "========================================" | tee -a "$OUTPUT_FILE"
echo "MONITORING SUMMARY" | tee -a "$OUTPUT_FILE"
echo "========================================" | tee -a "$OUTPUT_FILE"
echo "Total Systems: ${#SYSTEMS[@]}" | tee -a "$OUTPUT_FILE"
echo "Successful: $SUCCESS | Failed: $FAIL" | tee -a "$OUTPUT_FILE"
echo "========================================" | tee -a "$OUTPUT_FILE"

log_message "Monitoring completed"

# ================= TABLE OUTPUT =================
echo ""
echo "================ TABULAR SUMMARY ================"
printf "%-12s %-15s %-6s %-10s %-20s %-10s\n" "SYSTEM" "IP" "GPU" "GPU(%)" "MEM(MB)" "TEMP(C)"

while IFS="|" read -r system ip gpu util mem temp; do
    printf "%-12s %-15s %-6s %-10.2f %-20s %-10.2f\n" \
    "$system" "$ip" "$gpu" "$util" "$mem" "$temp"
done < "$TABLE_FILE"

echo "================================================"

echo ""
echo "Report: $OUTPUT_FILE"
echo "Log: $LOG_FILE"
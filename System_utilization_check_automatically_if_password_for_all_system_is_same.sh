#!/bin/bash

# ============================================================
#  SYSTEM + GPU MONITOR — SSH-based
# ============================================================

declare -A SYSTEMS=(
    ["192.168.0.102"]="username"
    ["192.168.0.103"]="username"
    ["192.168.0.107"]="username")

PASSWORD="******"

LOG_FILE="monitor_all.log"
OUTPUT_FILE="monitor_all_report.txt"
TABLE_FILE="/tmp/monitor_table.txt"

MONITOR_DURATION=5
SAMPLE_INTERVAL=2

> "$TABLE_FILE"
> "$OUTPUT_FILE"

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

safe_div() {
    local num="$1"
    local den="$2"
    local scale="${3:-2}"

    if [[ -z "$num" || -z "$den" || "$den" == "0" ]]; then
        echo "N/A"
    else
        echo "scale=${scale}; ${num} / ${den}" | bc 2>/dev/null || echo "N/A"
    fi
}

# ─────────────────────────────────────────────────────────────
# Dependency Check
# ─────────────────────────────────────────────────────────────

for pkg in sshpass bc; do
    if ! command -v "$pkg" &>/dev/null; then
        log_message "$pkg not found — installing..."
        sudo apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1
    fi
done

# ─────────────────────────────────────────────────────────────
# Report Header
# ─────────────────────────────────────────────────────────────

{
echo "========================================"
echo "  SYSTEM + GPU MONITORING REPORT"
echo "  Monitor Duration : ${MONITOR_DURATION}s"
echo "  Sample Interval  : ${SAMPLE_INTERVAL}s"
echo "  Started          : $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""
} | tee -a "$OUTPUT_FILE"

# ─────────────────────────────────────────────────────────────
# Monitor Function
# ─────────────────────────────────────────────────────────────

monitor_system() {

    local ip=$1
    local user=$2
    local temp_file="/tmp/monitor_${ip//./_}.txt"

    log_message "Connecting to $user@$ip ..."

    echo "  Host   : $user@$ip" | tee -a "$OUTPUT_FILE"

    REMOTE_SCRIPT='#!/bin/bash

SAMPLES=15
INTERVAL=2

HAS_GPU=0

command -v nvidia-smi &>/dev/null && HAS_GPU=1

GPU_COUNT=0

[ "$HAS_GPU" -eq 1 ] && GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)

echo "META:HAS_GPU=${HAS_GPU}"
echo "META:GPU_COUNT=${GPU_COUNT}"

for i in $(seq 1 $SAMPLES); do

    # CPU Usage

    line1=$(grep "^cpu " /proc/stat)
    sleep "$INTERVAL"
    line2=$(grep "^cpu " /proc/stat)

    read -r _ u1 n1 s1 id1 io1 irq1 sirq1 _ <<< "$line1"
    read -r _ u2 n2 s2 id2 io2 irq2 sirq2 _ <<< "$line2"

    total1=$((u1+n1+s1+id1+io1+irq1+sirq1))
    total2=$((u2+n2+s2+id2+io2+irq2+sirq2))

    dtotal=$((total2-total1))
    didle=$((id2-id1))

    if [ "$dtotal" -gt 0 ]; then
        cpu_pct=$(echo "scale=2; 100*($dtotal-$didle)/$dtotal" | bc)
    else
        cpu_pct="0.00"
    fi

    # Memory

    mem_total_kb=$(awk "/^MemTotal:/{print \$2}" /proc/meminfo)
    mem_free_kb=$(awk "/^MemFree:/{print \$2}" /proc/meminfo)
    buffers_kb=$(awk "/^Buffers:/{print \$2}" /proc/meminfo)
    cached_kb=$(awk "/^Cached:/{print \$2}" /proc/meminfo)

    mem_used_kb=$((mem_total_kb - mem_free_kb - buffers_kb - cached_kb))

    mem_total_gb=$(echo "scale=2; $mem_total_kb / 1024 / 1024" | bc)
    mem_used_gb=$(echo "scale=2; $mem_used_kb / 1024 / 1024" | bc)
    mem_free_gb=$(echo "scale=2; $mem_free_kb / 1024 / 1024" | bc)

    if [ "$mem_total_kb" -gt 0 ]; then
        mem_pct=$(echo "scale=2; 100*$mem_used_kb/$mem_total_kb" | bc)
    else
        mem_pct="0.00"
    fi

    echo "SYS:${cpu_pct}:${mem_pct}:${mem_used_gb}:${mem_free_gb}:${mem_total_gb}"

    # GPU

    if [ "$HAS_GPU" -eq 1 ] && [ "$GPU_COUNT" -gt 0 ]; then

        nvidia-smi \
            --query-gpu=index,utilization.gpu,memory.used,memory.free,memory.total,temperature.gpu \
            --format=csv,noheader,nounits 2>/dev/null \
        | while IFS="," read -r idx util mu mf mt temp; do

            idx=$(echo "$idx" | tr -d " \r")
            util=$(echo "$util" | tr -d " \r")

            mu=$(echo "$mu" | tr -d " \r")
            mf=$(echo "$mf" | tr -d " \r")
            mt=$(echo "$mt" | tr -d " \r")

            temp=$(echo "$temp" | tr -d " \r")

            mu_gb=$(echo "scale=2; $mu / 1024" | bc)
            mf_gb=$(echo "scale=2; $mf / 1024" | bc)
            mt_gb=$(echo "scale=2; $mt / 1024" | bc)

            echo "GPU_${idx}:${util}:${mu_gb}:${mf_gb}:${mt_gb}:${temp}"

        done
    fi

done
'

    if ! sshpass -p "$PASSWORD" ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        -o BatchMode=no \
        "$user@$ip" "bash -s" <<< "$REMOTE_SCRIPT" > "$temp_file" 2>>"$LOG_FILE"; then

        echo "  SSH : FAILED" | tee -a "$OUTPUT_FILE"

        echo "${user}|${ip}|SSH_FAILED|-|-|-|-|-|-" >> "$TABLE_FILE"

        echo "" | tee -a "$OUTPUT_FILE"

        return 1
    fi

    # ─────────────────────────────────────────────────────────
    # Parse META
    # ─────────────────────────────────────────────────────────

    has_gpu=$(grep "^META:HAS_GPU=" "$temp_file" | cut -d= -f2 | tr -d '[:space:]')
    gpu_count=$(grep "^META:GPU_COUNT=" "$temp_file" | cut -d= -f2 | tr -d '[:space:]')

    [[ "$has_gpu" =~ ^[0-9]+$ ]] || has_gpu=0
    [[ "$gpu_count" =~ ^[0-9]+$ ]] || gpu_count=0

    # ─────────────────────────────────────────────────────────
    # Average CPU / Memory
    # ─────────────────────────────────────────────────────────

    cpu_sum=0
    mem_pct_sum=0
    mem_used_sum=0
    mem_free_sum=0

    sys_count=0
    mem_total_val=0

    while IFS=':' read -r cpu_pct mem_pct mem_used mem_free mem_total; do

        [[ "$cpu_pct" =~ ^[0-9.]+$ ]] || continue
        [[ "$mem_pct" =~ ^[0-9.]+$ ]] || continue

        cpu_sum=$(echo "$cpu_sum + $cpu_pct" | bc)
        mem_pct_sum=$(echo "$mem_pct_sum + $mem_pct" | bc)

        mem_used_sum=$(echo "$mem_used_sum + $mem_used" | bc)
        mem_free_sum=$(echo "$mem_free_sum + $mem_free" | bc)

        mem_total_val="$mem_total"

        sys_count=$((sys_count + 1))

    done < <(grep "^SYS:" "$temp_file" | cut -d: -f2-)


if [ "$sys_count" -gt 0 ]; then

    avg_cpu=$(safe_div "$cpu_sum" "$sys_count" 2)

    avg_mem_pct=$(safe_div "$mem_pct_sum" "$sys_count" 2)

    avg_mem_used=$(safe_div "$mem_used_sum" "$sys_count" 2)
    avg_mem_free=$(safe_div "$mem_free_sum" "$sys_count" 2)

    {
        echo "  CPU    : ${avg_cpu}%"
        echo "  Memory : ${avg_mem_pct}% used | Used: ${avg_mem_used} GB | Free: ${avg_mem_free} GB | Total: ${mem_total_val} GB"
    } | tee -a "$OUTPUT_FILE"

else

    avg_cpu="N/A"
    avg_mem_pct="N/A"
    avg_mem_used="N/A"
    avg_mem_free="N/A"
    mem_total_val="N/A"

    echo "  No SYS data" | tee -a "$OUTPUT_FILE"

fi


    # ─────────────────────────────────────────────────────────
    # GPU Averages
    # ─────────────────────────────────────────────────────────

    if [ "$has_gpu" -eq 1 ] && [ "$gpu_count" -gt 0 ]; then

        echo "  GPUs   : $gpu_count detected" | tee -a "$OUTPUT_FILE"

        for ((gid=0; gid<gpu_count; gid++)); do

            g_util_sum=0
            g_mu_sum=0
            g_mf_sum=0
            g_temp_sum=0

            g_count=0
            g_mt=0

            while IFS=':' read -r util mu mf mt temp; do

                [[ "$util" =~ ^[0-9.]+$ ]] || continue

                g_util_sum=$(echo "$g_util_sum + $util" | bc)

                g_mu_sum=$(echo "$g_mu_sum + $mu" | bc)
                g_mf_sum=$(echo "$g_mf_sum + $mf" | bc)

                g_temp_sum=$(echo "$g_temp_sum + $temp" | bc)

                g_mt="$mt"

                g_count=$((g_count + 1))

            done < <(grep "^GPU_${gid}:" "$temp_file" | cut -d: -f2-)

            if [ "$g_count" -gt 0 ]; then

                avg_gutil=$(safe_div "$g_util_sum" "$g_count" 2)

                avg_gmu=$(safe_div "$g_mu_sum" "$g_count" 2)
                avg_gmf=$(safe_div "$g_mf_sum" "$g_count" 2)

                avg_gtemp=$(safe_div "$g_temp_sum" "$g_count" 1)

                printf "  GPU %-2d : Util %s%% | Mem %s/%s GB (free %s GB) | Temp %s°C\n" \
                    "$gid" \
                    "$avg_gutil" \
                    "$avg_gmu" \
                    "$g_mt" \
                    "$avg_gmf" \
                    "$avg_gtemp" | tee -a "$OUTPUT_FILE"

                echo "${user}|${ip}|GPU_${gid}|${avg_cpu}|${avg_mem_used}/${mem_total_val}GB|${avg_mem_pct}|${avg_gutil}|${avg_gmu}/${g_mt}GB|${avg_gtemp}" \
                    >> "$TABLE_FILE"

            else

                printf "  GPU %-2d : No data\n" "$gid" | tee -a "$OUTPUT_FILE"

            fi
        done

    else

        echo "  GPUs   : None" | tee -a "$OUTPUT_FILE"

        echo "${user}|${ip}|NO_GPU|${avg_cpu}|${avg_mem_used}/${mem_total_val}GB|${avg_mem_pct}|N/A|N/A|N/A" \
            >> "$TABLE_FILE"

    fi

    echo "" | tee -a "$OUTPUT_FILE"

    rm -f "$temp_file"

    return 0
}

# ─────────────────────────────────────────────────────────────
# Main Loop
# ─────────────────────────────────────────────────────────────

log_message "Starting monitoring"

SUCCESS=0
FAIL=0

for ip in "${!SYSTEMS[@]}"; do

    USERNAME="${SYSTEMS[$ip]}"

    echo "----------------------------------------" | tee -a "$OUTPUT_FILE"
    echo "Monitoring : $USERNAME@$ip" | tee -a "$OUTPUT_FILE"
    echo "----------------------------------------" | tee -a "$OUTPUT_FILE"

    if monitor_system "$ip" "$USERNAME"; then
        ((SUCCESS++))
    else
        ((FAIL++))
    fi

done

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────

{
echo ""
echo "========================================"
echo "  SUMMARY"
echo "  Total   : ${#SYSTEMS[@]}"
echo "  OK      : $SUCCESS"
echo "  FAILED  : $FAIL"
echo "  Ended   : $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
} | tee -a "$OUTPUT_FILE"

log_message "Done — OK:$SUCCESS FAIL:$FAIL"

# ─────────────────────────────────────────────────────────────
# Final Table
# ─────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════════════════════════════════"

printf "%-12s %-15s %-7s %-10s %-24s %-8s %-10s %-20s %-10s\n" \
    "SYSTEM" \
    "IP" \
    "SLOT" \
    "CPU%" \
    "MEM(used/total)" \
    "MEM%" \
    "GPU%" \
    "GPU_MEM" \
    "GPU_TEMP"

echo "────────────────────────────────────────────────────────────────────────────────"

while IFS="|" read -r system ip slot cpu mem mem_pct gpu_util gpu_mem gpu_temp; do

    printf "%-12s %-15s %-7s %-10s %-24s %-8s %-10s %-20s %-10s\n" \
        "$system" \
        "$ip" \
        "$slot" \
        "$cpu" \
        "$mem" \
        "$mem_pct" \
        "$gpu_util" \
        "$gpu_mem" \
        "$gpu_temp"

done < "$TABLE_FILE"

echo "══════════════════════════════════════════════════════════════════════════════════"

echo ""
echo "Report : $OUTPUT_FILE"
echo "Log    : $LOG_FILE"

#!/bin/bash
# ~/notify.sh — source this at the top of your job scripts
# Usage: source ~/notify.sh

# ── Configure these two lines ────────────────────────────────────────────────
DISCORD_WEBHOOK="https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN"
DISCORD_USER_ID="YOUR_DISCORD_USER_ID"
# ─────────────────────────────────────────────────────────────────────────────

_notify() {
    local message="$1"
    # Escape special characters for JSON without jq
    message="${message//\\/\\\\}"   # backslashes
    message="${message//\"/\\\"}"   # double quotes
    message="${message//$'\n'/\\n}" # newlines
    message="${message//$'\r'/\\r}" # carriage returns
    message="${message//$'\t'/\\t}" # tabs
    curl -s -o /dev/null \
         -H "Content-Type: application/json" \
         -d "{\"content\": \"$message\"}" \
         "$DISCORD_WEBHOOK"
}

notify_start() {
    local gpu_info=""
    if [ -n "$SLURM_GPUS_ON_NODE" ] && [ "$SLURM_GPUS_ON_NODE" -gt 0 ] 2>/dev/null; then
        gpu_info=$'\nGPUs     : '"$SLURM_GPUS_ON_NODE"
    fi

    local array_info=""
    if [ -n "$SLURM_ARRAY_TASK_ID" ]; then
        array_info=$'\nArray    : task '"$SLURM_ARRAY_TASK_ID of $SLURM_ARRAY_TASK_MAX"
    fi

    local msg="<@${DISCORD_USER_ID}> 🚀 **${SLURM_JOB_NAME}** started"
    msg+=$'\n```'
    msg+=$'\nJob ID   : '"$SLURM_JOB_ID"
    msg+=$'\nPartition: '"$SLURM_JOB_PARTITION"
    msg+=$'\nNode(s)  : '"$SLURM_JOB_NODELIST"
    msg+="${gpu_info}${array_info}"
    msg+=$'\n```'

    _notify "$msg"
    export _JOB_START_TIME=$SECONDS
}

notify_end() {
    local exit_code="$1"
    local runtime=$(( SECONDS - ${_JOB_START_TIME:-0} ))
    local hours=$(( runtime / 3600 ))
    local mins=$(( (runtime % 3600) / 60 ))
    local secs=$(( runtime % 60 ))
    local duration="${hours}h ${mins}m ${secs}s"

    local array_info=""
    if [ -n "$SLURM_ARRAY_TASK_ID" ]; then
        array_info=" [task ${SLURM_ARRAY_TASK_ID}]"
    fi

    # Collect last 30 lines of stdout and stderr logs
    # For array jobs: out/name-jobid_taskid.{out,err}
    # For regular jobs: out/name-jobid.{out,err}
    local log_base="${SLURM_SUBMIT_DIR}/out/${SLURM_JOB_NAME}-${SLURM_JOB_ID}"
    if [ -n "$SLURM_ARRAY_TASK_ID" ]; then
        log_base="${SLURM_SUBMIT_DIR}/out/${SLURM_JOB_NAME}-${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
    fi
    local out_file="${log_base}.out"
    local err_file="${log_base}.err"

    local log_section=""
    if [ -f "$out_file" ] && [ -s "$out_file" ]; then
        local out_tail
        out_tail=$(tail -n 30 "$out_file" | head -c 700)
        log_section+=$'\n**stdout (last 30 lines):**\n```\n'"${out_tail}"$'\n```'
    fi
    if [ -f "$err_file" ] && [ -s "$err_file" ]; then
        local err_tail
        err_tail=$(tail -n 30 "$err_file" | head -c 900)
        log_section+=$'\n**stderr (last 30 lines):**\n```\n'"${err_tail}"$'\n```'
    fi

    if [ "$exit_code" -eq 0 ]; then
        local msg="<@${DISCORD_USER_ID}> ✅ **${SLURM_JOB_NAME}**${array_info} completed in ${duration}"
        msg+=$'\n```'
        msg+=$'\nJob ID   : '"$SLURM_JOB_ID"
        msg+=$'\nPartition: '"$SLURM_JOB_PARTITION"
        msg+=$'\nNode(s)  : '"$SLURM_JOB_NODELIST"
        msg+=$'\n```'
        _notify "$msg"

    else
        local msg="<@${DISCORD_USER_ID}> ❌ **${SLURM_JOB_NAME}**${array_info} failed after ${duration}"
        msg+=$'\nExit code: `'"${exit_code}"'`'
        msg+="${log_section}"
        _notify "$msg"
    fi
}
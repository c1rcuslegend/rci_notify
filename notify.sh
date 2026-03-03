#!/bin/bash
# ~/notify.sh — source this at the top of your job scripts
# Usage: source ~/notify.sh

# ── Configure these two lines ────────────────────────────────────────────────
DISCORD_WEBHOOK="https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN"
DISCORD_USER_ID="YOUR_DISCORD_USER_ID"
# ─────────────────────────────────────────────────────────────────────────────

# Get the already-resolved stdout/stderr paths for the current SLURM job.
# Priority:
#   1. scontrol show job  — returns fully expanded absolute paths (most reliable)
#   2. SLURM_STDOUTMODE / SLURM_STDERRMODE — pattern-based expansion (fallback)
#   3. SLURM default "slurm-%j.out" — last resort
#
# Usage: _get_slurm_log_paths
#   Sets: _SLURM_STDOUT_PATH  _SLURM_STDERR_PATH
_get_slurm_log_paths() {
    _SLURM_STDOUT_PATH=""
    _SLURM_STDERR_PATH=""

    # ── Method 1: ask scontrol (gives fully resolved absolute paths) ─────
    if command -v scontrol &>/dev/null && [ -n "$SLURM_JOB_ID" ]; then
        local job_info
        job_info=$(scontrol show job "$SLURM_JOB_ID" 2>/dev/null) || true
        if [ -n "$job_info" ]; then
            _SLURM_STDOUT_PATH=$(echo "$job_info" | grep -oP 'StdOut=\K\S+' || true)
            _SLURM_STDERR_PATH=$(echo "$job_info" | grep -oP 'StdErr=\K\S+' || true)
        fi
    fi

    # ── Method 2: expand SLURM_STDOUTMODE / SLURM_STDERRMODE patterns ───
    if [ -z "$_SLURM_STDOUT_PATH" ]; then
        _SLURM_STDOUT_PATH=$(_resolve_slurm_pattern "${SLURM_STDOUTMODE:-slurm-%j.out}")
    fi
    if [ -z "$_SLURM_STDERR_PATH" ]; then
        _SLURM_STDERR_PATH=$(_resolve_slurm_pattern "${SLURM_STDERRMODE:-slurm-%j.out}")
    fi
}

# Resolve a SLURM filename pattern (e.g. "out/%x-%j.out") into the actual
# file path by expanding all known % tokens.
# See: https://slurm.schedmd.com/sbatch.html#SECTION_FILENAME-PATTERN
#
# Usage: _resolve_slurm_pattern "out/%x-%j.out"
_resolve_slurm_pattern() {
    local pattern="$1"

    # If the pattern is empty, return empty
    [ -z "$pattern" ] && return

    # For array jobs, %j expands to <array_job_id>_<task_id>
    local effective_job_id="$SLURM_JOB_ID"

    # Perform all standard SLURM substitutions
    # IMPORTANT: %% must be handled carefully — we use a placeholder to avoid
    # double-substitution, then replace it at the end.
    local _pct_placeholder=$'\x01'
    pattern="${pattern//%%/${_pct_placeholder}}"                        # protect literal %%
    pattern="${pattern//%A/${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}}"     # array master job id
    pattern="${pattern//%a/${SLURM_ARRAY_TASK_ID:-0}}"                 # array task id
    pattern="${pattern//%j/${effective_job_id}}"                        # job id (or arrayjobid_taskid)
    pattern="${pattern//%J/${effective_job_id}}"                        # same as %j for sbatch
    pattern="${pattern//%N/${SLURMD_NODENAME:-$(hostname -s)}}"        # short hostname of first node
    pattern="${pattern//%n/0}"                                         # node id relative to job (0 for sbatch)
    pattern="${pattern//%t/0}"                                         # task id relative to job (0 for sbatch)
    pattern="${pattern//%u/${USER:-$(whoami)}}"                        # username
    pattern="${pattern//%x/${SLURM_JOB_NAME:-batch}}"                  # job name
    pattern="${pattern//${_pct_placeholder}/%}"                         # restore literal %

    # Make relative paths relative to submit dir
    if [[ "$pattern" != /* ]]; then
        pattern="${SLURM_SUBMIT_DIR:-.}/${pattern}"
    fi

    printf '%s' "$pattern"
}

# Get the last N lines of a file, but trim from the TOP (removing oldest lines)
# until the total output fits within a character budget. This ensures we never
# cut a line in half — we always show complete lines.
#
# Usage: _tail_within_chars FILE MAX_LINES MAX_CHARS
_tail_within_chars() {
    local file="$1"
    local max_lines="${2:-30}"
    local max_chars="${3:-800}"

    local chunk
    chunk=$(tail -n "$max_lines" "$file")

    # If it already fits, return as-is
    if [ "${#chunk}" -le "$max_chars" ]; then
        printf '%s' "$chunk"
        return
    fi

    # Drop lines from the top until it fits
    while [ "${#chunk}" -gt "$max_chars" ] && [ -n "$chunk" ]; do
        chunk="${chunk#*$'\n'}"
    done

    printf '%s' "$chunk"
}

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

    # Resolve log paths so they appear in the start notification
    _get_slurm_log_paths
    local log_info=""
    if [ -n "$_SLURM_STDOUT_PATH" ]; then
        log_info+=$'\nStdout   : '"$_SLURM_STDOUT_PATH"
    fi
    if [ -n "$_SLURM_STDERR_PATH" ] && [ "$_SLURM_STDERR_PATH" != "$_SLURM_STDOUT_PATH" ]; then
        log_info+=$'\nStderr   : '"$_SLURM_STDERR_PATH"
    fi

    local msg="<@${DISCORD_USER_ID}> 🚀 **${SLURM_JOB_NAME}** started"
    msg+=$'\n```'
    msg+=$'\nJob ID   : '"$SLURM_JOB_ID"
    msg+=$'\nPartition: '"$SLURM_JOB_PARTITION"
    msg+=$'\nNode(s)  : '"$SLURM_JOB_NODELIST"
    msg+="${gpu_info}${array_info}${log_info}"
    msg+=$'\n```'

    _notify "$msg"
    export _JOB_START_TIME=$SECONDS
}

notify_end() {
    local exit_code="$1"

    # Guard: if the caller passed an empty string, no argument, or non-integer,
    # treat as failure. Common mistake: notify_end $UNSET_VAR → empty string.
    if [ -z "$exit_code" ]; then
        exit_code=255
    elif ! [[ "$exit_code" =~ ^[0-9]+$ ]]; then
        exit_code=255
    fi

    local runtime=$(( SECONDS - ${_JOB_START_TIME:-0} ))
    local hours=$(( runtime / 3600 ))
    local mins=$(( (runtime % 3600) / 60 ))
    local secs=$(( runtime % 60 ))
    local duration="${hours}h ${mins}m ${secs}s"

    local array_info=""
    if [ -n "$SLURM_ARRAY_TASK_ID" ]; then
        array_info=" [task ${SLURM_ARRAY_TASK_ID}]"
    fi

    # Resolve the actual output/error file paths.
    # Tries scontrol first (gives absolute resolved paths directly from SLURM),
    # then falls back to expanding SLURM_STDOUTMODE/SLURM_STDERRMODE patterns,
    # and finally defaults to "slurm-%j.out".
    _get_slurm_log_paths
    local out_file="$_SLURM_STDOUT_PATH"
    local err_file="$_SLURM_STDERR_PATH"

    # Flush filesystem buffers so we read the most up-to-date log content.
    # SLURM may still be buffering the job's stdout/stderr at this point.
    sync
    sleep 10

    local log_section=""
    if [ -f "$out_file" ] && [ -s "$out_file" ]; then
        local out_tail
        out_tail=$(_tail_within_chars "$out_file" 20 700)
        log_section+=$'\n**stdout (last lines):**\n```\n'"${out_tail}"$'\n```'
    fi
    if [ -f "$err_file" ] && [ -s "$err_file" ] && [ "$err_file" != "$out_file" ]; then
        local err_tail
        err_tail=$(_tail_within_chars "$err_file" 50 900)
        log_section+=$'\n**stderr (last lines):**\n```\n'"${err_tail}"$'\n```'
    fi

    if [ "$exit_code" -eq 0 ]; then
        local msg="<@${DISCORD_USER_ID}> ✅ **${SLURM_JOB_NAME}**${array_info} completed in ${duration}"
        msg+=$'\n```'
        msg+=$'\nJob ID   : '"$SLURM_JOB_ID"
        msg+=$'\nPartition: '"$SLURM_JOB_PARTITION"
        msg+=$'\nNode(s)  : '"$SLURM_JOB_NODELIST"
        msg+=$'\nStdout   : '"$out_file"
        [ "$err_file" != "$out_file" ] && msg+=$'\nStderr   : '"$err_file"
        msg+=$'\n```'
        _notify "$msg"

    else
        local msg="<@${DISCORD_USER_ID}> ❌ **${SLURM_JOB_NAME}**${array_info} failed after ${duration}"
        msg+=$'\nExit code: `'"${exit_code}"'`'
        msg+=$'\n```'
        msg+=$'\nJob ID   : '"$SLURM_JOB_ID"
        msg+=$'\nStdout   : '"$out_file"
        [ "$err_file" != "$out_file" ] && msg+=$'\nStderr   : '"$err_file"
        msg+=$'\n```'
        msg+="${log_section}"
        _notify "$msg"
    fi
}
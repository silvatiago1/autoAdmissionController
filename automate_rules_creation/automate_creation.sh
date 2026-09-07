#!/usr/bin/env bash

# Prevent pipeline failures on SIGPIPE (Exit 141) while keeping safety checks
set -eu
set -o pipefail 2>/dev/null || true

SKIP_APPLY=0
HEADLESS=0
WAIT_WORKFLOW=0
DEACTIVATE_RULES=0
INPUT_FILE=""

# Initialize metric accumulators to prevent set -u unbound variable crashes
pipeline_elapsed=0
workflow_elapsed=0

# Parse optional flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-apply|-s)
            SKIP_APPLY=1
            shift
            ;;
        --headless|-h)
            HEADLESS=1
            shift
            ;;
        --wait|-w)
            WAIT_WORKFLOW=1
            shift
            ;;
        --deactivate-rules|-d)
            DEACTIVATE_RULES=1
            shift
            ;;
        *)
            if [[ -z "$INPUT_FILE" ]]; then
                INPUT_FILE="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "${INPUT_FILE:-}" ]]; then
    echo "Usage: $0 [--skip-apply|-s] [--headless|-h] [--wait|-w] [--deactivate-rules|-d] <input_file>"
    exit 1
fi

# Log file definitions
PIPELINE_LOG="benchmark_pipeline_times.txt"
WORKFLOW_LOG="benchmark_workflow_times.txt"
TOTAL_LOG="benchmark_total_times.txt"
MEMORY_SERIES_LOG="benchmark_workflow_memory_timeseries.csv"

# Always ensure CSV log exists at start
if [[ ! -f "$MEMORY_SERIES_LOG" ]]; then
    echo "timestamp_epoch_ms,pod_name,memory_bytes,memory_mib" > "$MEMORY_SERIES_LOG"
fi

# ==============================================================================
# DEACTIVATION PHASE (Clears existing rules BEFORE starting the timer)
# ==============================================================================
if [[ "$SKIP_APPLY" -eq 0 ]]; then
    echo "Deactivating previous Falco rules using disable_rules.yaml..."
    
    # Auto-cleanup stale helm release locks if present
    STUCK_SECRET=$(kubectl get secrets -n falco -l "owner=helm,name=falco,status=pending-upgrade" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$STUCK_SECRET" ]]; then
        echo "Removing stale Helm upgrade lock: $STUCK_SECRET"
        kubectl delete secret "$STUCK_SECRET" -n falco > /dev/null 2>&1 || true
    fi

    helm upgrade --namespace falco falco falcosecurity/falco \
        --set tty=true \
        --set falcoctl.artifact.install.enabled=false \
        --set falcoctl.artifact.follow.enabled=false \
        --atomic --timeout 30s \
        -f disable_rules.yaml > /dev/null

    echo "Waiting for rule deactivation rollout to complete..."
    until kubectl rollout status daemonset/falco -n falco --timeout=60s > /dev/null 2>&1; do
        echo "Timed out waiting for deactivation rollout. Retrying in 5 seconds..."
        sleep 5
    done
fi

# ==============================================================================
# PIPELINE TIMER START (Captures rule generation & deployment latency)
# ==============================================================================
if [[ "${BENCHMARK_MODE:-0}" -eq 1 ]]; then
    pipeline_start_time=$(date +%s%3N)
fi

echo "Running generator..."
python3 main.py "$INPUT_FILE"

# Find the newest generated rules file.
GENERATED_FILE=$(find ./created_rules -maxdepth 1 -type f -name "*.yaml" -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null \
    | head -n1 || true)

if [[ -z "$GENERATED_FILE" || ! -f "$GENERATED_FILE" ]]; then
    echo "Error: Could not find generated YAML file in ./created_rules"
    exit 1
fi

# Determine which rules file to deploy
if [[ "$DEACTIVATE_RULES" -eq 1 ]]; then
    TARGET_RULES_FILE="disable_rules.yaml"
    echo "Deactivate flag active: Deploying empty/disabled rules baseline ($TARGET_RULES_FILE)..."
else
    TARGET_RULES_FILE="$GENERATED_FILE"
    echo "Using generated rules file: $TARGET_RULES_FILE"
fi

# Bypass Helm, kubectl, and background execution if requested
if [[ "$SKIP_APPLY" -eq 1 ]]; then
    echo "Rule creation finished. Skipping deployment phase."
    
    if [[ "${BENCHMARK_MODE:-0}" -eq 1 ]]; then
        pipeline_end_time=$(date +%s%3N)
        pipeline_elapsed=$((pipeline_end_time - pipeline_start_time))
        
        echo "$pipeline_elapsed" >> "$PIPELINE_LOG"
        echo "$pipeline_elapsed" >> "$TOTAL_LOG"
        
        echo "Pipeline Elapsed: $pipeline_elapsed"
        echo "Elapsed: $pipeline_elapsed"
    fi
    exit 0
fi

echo "Applying Helm upgrade with selected rules configuration..."
helm upgrade --namespace falco falco falcosecurity/falco \
    --set tty=true \
    --set falcoctl.artifact.install.enabled=false \
    --set falcoctl.artifact.follow.enabled=false \
    --atomic --timeout 30s \
    -f "$TARGET_RULES_FILE" > /dev/null

echo "Waiting for Falco DaemonSet rollout to complete..."
until kubectl rollout status daemonset/falco -n falco --timeout=60s > /dev/null 2>&1; do
    echo "Timed out waiting for rollout. Retrying in 5 seconds..."
    sleep 5
done

# Brief delay to settle Kubernetes API references
sleep 2

# Stop pipeline timing here (before workflow starts execution)
if [[ "${BENCHMARK_MODE:-0}" -eq 1 ]]; then
    pipeline_end_time=$(date +%s%3N)
    pipeline_elapsed=$((pipeline_end_time - pipeline_start_time))
fi

# ==============================================================================
# WORKFLOW EXECUTION & UNIVERSAL BACKGROUND MONITORING
# ==============================================================================

# Start universal memory collector in the background
(
    LOG_FILE="benchmark_workflow_memory_timeseries.csv"
    while true; do
        now_ms=$(date +%s%3N)
        top_output=$(kubectl top pods -A --no-headers 2>/dev/null | grep -v -E "argo-workflows-server|workflow-controller|kube-system|falco" || true)
        
        if [[ -n "$top_output" ]]; then
            echo "$top_output" | while read -r line; do
                pod_name=$(echo "$line" | awk '{print $2}')
                mem_raw=$(echo "$line" | awk '{print $4}')
                
                if [[ "$mem_raw" == *Mi ]]; then
                    mem_mib=$(echo "$mem_raw" | tr -d 'Mi')
                    mem_bytes=$((mem_mib * 1048576))
                elif [[ "$mem_raw" == *Ki ]]; then
                    mem_ki=$(echo "$mem_raw" | tr -d 'Ki')
                    mem_mib=$((mem_ki / 1024))
                    mem_bytes=$((mem_ki * 1024))
                elif [[ "$mem_raw" == *Gi ]]; then
                    mem_gi=$(echo "$mem_raw" | tr -d 'Gi')
                    mem_mib=$((mem_gi * 1024))
                    mem_bytes=$((mem_gi * 1073741824))
                else
                    mem_mib=0
                    mem_bytes=0
                fi

                if [[ -n "$pod_name" && "$mem_mib" -gt 0 ]]; then
                    echo "${now_ms},${pod_name},${mem_bytes},${mem_mib}" >> "$LOG_FILE"
                fi
            done
        fi
        sleep 3
    done
) &
MONITOR_PID=$!

# Ensure background monitor process is killed when the script terminates
trap 'kill "$MONITOR_PID" 2>/dev/null || true' EXIT

if [[ "$HEADLESS" -eq 1 ]]; then
    echo "Headless mode enabled: Skipping gnome-terminal windows..."
    
    if [[ "$WAIT_WORKFLOW" -eq 1 ]]; then
        echo "Submitting Argo workflow and waiting for completion..."
        workflow_start_time=$(date +%s%3N)
        
        # Submit workflow and capture submission output to extract workflow name safely
        SUBMIT_OUTPUT=$(argo submit -n argo "$INPUT_FILE" -o name 2>/dev/null || true)
        
        if [[ -n "$SUBMIT_OUTPUT" ]]; then
            argo watch -n argo "$SUBMIT_OUTPUT" > /dev/null 2>&1 || true
        else
            # Fallback to watching @latest without SIGPIPE prone piping
            argo watch -n argo @latest > /dev/null 2>&1 || true
        fi
        
        workflow_end_time=$(date +%s%3N)
        workflow_elapsed=$((workflow_end_time - workflow_start_time))
    else
        echo "Submitting Argo workflow in the background..."
        argo submit -n argo "$INPUT_FILE" > /dev/null 2>&1 &
    fi
else
    echo "Opening Falco logs window..."
    gnome-terminal --title="Falco Logs" -- bash -lc \
    'kubectl logs -f --tail=50 -l app.kubernetes.io/name=falco -n falco -c falco; exec bash' &

    echo "Opening Argo workflow window..."
    if [[ "$WAIT_WORKFLOW" -eq 1 ]]; then
        workflow_start_time=$(date +%s%3N)
        gnome-terminal --wait --title="Argo" -- bash -lc \
        "argo submit -n argo --watch \"$INPUT_FILE\""
        workflow_end_time=$(date +%s%3N)
        workflow_elapsed=$((workflow_end_time - workflow_start_time))
    else
        gnome-terminal --title="Argo" -- bash -lc \
        "argo submit -n argo --watch \"$INPUT_FILE\"; exec bash" &
    fi

    echo "Workflow submission finished."
fi

# ==============================================================================
# METRICS FILE WRITING & CONSOLE OUTPUT
# ==============================================================================
if [[ "${BENCHMARK_MODE:-0}" -eq 1 ]]; then
    total_elapsed=$((pipeline_elapsed + workflow_elapsed))
    
    echo "$pipeline_elapsed" >> "$PIPELINE_LOG"
    echo "$total_elapsed" >> "$TOTAL_LOG"
    
    echo "Pipeline Elapsed: $pipeline_elapsed"
    
    if [[ "$WAIT_WORKFLOW" -eq 1 ]]; then
        echo "$workflow_elapsed" >> "$WORKFLOW_LOG"
        echo "Workflow Elapsed: $workflow_elapsed"
    fi
    
    echo "Elapsed: $total_elapsed"
fi
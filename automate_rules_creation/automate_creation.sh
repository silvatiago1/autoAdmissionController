#!/usr/bin/env bash

set -eu
set -o pipefail 2>/dev/null || true

SKIP_APPLY=0
HEADLESS=0
WAIT_WORKFLOW=0
DEACTIVATE_RULES=0
INPUT_FILE=""

creation_elapsed=0
apply_elapsed=0
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

# Log file definitions (defaults if not set by wrapper)
CREATION_LOG="${CREATION_LOG:-benchmark_rule_creation_times.txt}"
APPLY_LOG="${APPLY_LOG:-benchmark_rule_apply_times.txt}"
WORKFLOW_LOG="${WORKFLOW_LOG:-benchmark_workflow_times.txt}"
MEMORY_SERIES_LOG="${MEMORY_SERIES_LOG:-benchmark_workflow_memory_timeseries.csv}"

if [[ ! -f "$MEMORY_SERIES_LOG" ]]; then
    echo "timestamp_epoch_ms,pod_name,memory_bytes,memory_mib" > "$MEMORY_SERIES_LOG"
fi

# Initial helm lock cleanup helper
STUCK_SECRET=$(kubectl get secrets -n falco -l "owner=helm,name=falco,status=pending-upgrade" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$STUCK_SECRET" ]]; then
    kubectl delete secret "$STUCK_SECRET" -n falco > /dev/null 2>&1 || true
fi

# ==============================================================================
# PHASE 1: RULE CREATION (Skipped completely if --deactivate-rules is active)
# ==============================================================================
if [[ "$DEACTIVATE_RULES" -eq 1 ]]; then
    echo "Deactivate flag active: Skipping rule generation phase entirely."
    TARGET_RULES_FILE="disable_rules.yaml"
    creation_elapsed=0
else
    echo "Running rule generator..."
    creation_start=$(date +%s%3N)
    python3 main.py "$INPUT_FILE"
    creation_end=$(date +%s%3N)
    creation_elapsed=$((creation_end - creation_start))

    GENERATED_FILE=$(find ./created_rules -maxdepth 1 -type f -name "*.yaml" -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null \
        | head -n1 || true)

    if [[ -z "$GENERATED_FILE" || ! -f "$GENERATED_FILE" ]]; then
        echo "Error: Could not find generated YAML file in ./created_rules"
        exit 1
    fi
    TARGET_RULES_FILE="$GENERATED_FILE"
fi

# Stop here if --skip-apply is set
if [[ "$SKIP_APPLY" -eq 1 ]]; then
    if [[ "${BENCHMARK_MODE:-0}" -eq 1 && "$DEACTIVATE_RULES" -eq 0 ]]; then
        echo "$creation_elapsed" >> "$CREATION_LOG"
        echo "Rule Creation Elapsed: $creation_elapsed"
        echo "Elapsed: $creation_elapsed"
    fi
    exit 0
fi

# ==============================================================================
# PHASE 2: MEASURE RULE APPLY TIME
# ==============================================================================
echo "Applying Helm upgrade with target configuration: $TARGET_RULES_FILE"
apply_start=$(date +%s%3N)

helm upgrade --namespace falco falco falcosecurity/falco \
    --set tty=true \
    --set falcoctl.artifact.install.enabled=false \
    --set falcoctl.artifact.follow.enabled=false \
    --atomic --timeout 30s \
    -f "$TARGET_RULES_FILE" > /dev/null

until kubectl rollout status daemonset/falco -n falco --timeout=60s > /dev/null 2>&1; do
    sleep 2
done

apply_end=$(date +%s%3N)
apply_elapsed=$((apply_end - apply_start))

# Brief delay to settle Kubernetes API references
sleep 2

# ==============================================================================
# PHASE 3: WORKFLOW EXECUTION & BACKGROUND MEMORY SAMPLING
# ==============================================================================
(
    while true; do
        now_ms=$(date +%s%3N)
        # Filter specifically for Falco and Prometheus pods
        top_output=$(kubectl top pods -A --no-headers 2>/dev/null | grep -E "falco|prometheus" | grep -v -E "operator|node-exporter|adapter" || true)
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
                    echo "${now_ms},${pod_name},${mem_bytes},${mem_mib}" >> "$MEMORY_SERIES_LOG"
                fi
            done
        fi
        sleep 3
    done
) &
MONITOR_PID=$!
trap 'kill "$MONITOR_PID" 2>/dev/null || true' EXIT

echo "Submitting Argo workflow..."
workflow_start=$(date +%s%3N)

SUBMIT_OUTPUT=$(argo submit -n argo "$INPUT_FILE" -o name 2>/dev/null || true)
if [[ -n "$SUBMIT_OUTPUT" ]]; then
    argo watch -n argo "$SUBMIT_OUTPUT" > /dev/null 2>&1 || true
else
    argo watch -n argo @latest > /dev/null 2>&1 || true
fi

workflow_end=$(date +%s%3N)
workflow_elapsed=$((workflow_end - workflow_start))

# ==============================================================================
# LOG OUTPUTS FOR BENCHMARKING
# ==============================================================================
if [[ "${BENCHMARK_MODE:-0}" -eq 1 ]]; then
    if [[ "$DEACTIVATE_RULES" -eq 0 ]]; then
        echo "$creation_elapsed" >> "$CREATION_LOG"
        echo "Rule Creation Elapsed: $creation_elapsed"
    fi
    
    echo "$apply_elapsed" >> "$APPLY_LOG"
    echo "$workflow_elapsed" >> "$WORKFLOW_LOG"
    
    echo "Rule Apply Elapsed: $apply_elapsed"
    echo "Workflow Elapsed: $workflow_elapsed"
    
    total_elapsed=$((creation_elapsed + apply_elapsed + workflow_elapsed))
    echo "Elapsed: $total_elapsed"
fi
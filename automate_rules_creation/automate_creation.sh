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

# Log file definitions
CREATION_LOG="${CREATION_LOG:-benchmark_rule_creation_times.txt}"
APPLY_LOG="${APPLY_LOG:-benchmark_rule_apply_times.txt}"
WORKFLOW_LOG="${WORKFLOW_LOG:-benchmark_workflow_times.txt}"
MEMORY_SERIES_LOG="${MEMORY_SERIES_LOG:-benchmark_workflow_memory_timeseries.csv}"

if [[ ! -f "$MEMORY_SERIES_LOG" ]]; then
    echo "timestamp_epoch_ms,pod_name,memory_bytes,memory_mib" > "$MEMORY_SERIES_LOG"
fi

# Cleanup stuck helm lock if present
STUCK_SECRET=$(kubectl get secrets -n falco -l "owner=helm,name=falco,status=pending-upgrade" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$STUCK_SECRET" ]]; then
    kubectl delete secret "$STUCK_SECRET" -n falco > /dev/null 2>&1 || true
fi

# ==============================================================================
# PHASE 1: RULE CREATION (Falco & Prometheus)
# ==============================================================================
if [[ "$DEACTIVATE_RULES" -eq 1 ]]; then
    echo "Deactivate flag active: Skipping rule generation phase entirely."
    TARGET_FALCO_RULES_FILE="disable_rules.yaml"
    TARGET_PROM_RULES_FILE=""
    creation_elapsed=0
else
    echo "Running rule generator for Falco and Prometheus..."
    creation_start=$(date +%s%3N)
    python3 main.py "$INPUT_FILE"
    creation_end=$(date +%s%3N)
    creation_elapsed=$((creation_end - creation_start))

    # Detect Falco rule file
    TARGET_FALCO_RULES_FILE=$(find ./created_rules -maxdepth 1 -type f \( -name "*falco*.yaml" -o -name "*.yaml" \) ! -name "*prometheus*" -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null \
        | head -n1 || true)

    # Detect Prometheus rule file (e.g., zipslip-prometheus-rules.yaml)
    TARGET_PROM_RULES_FILE=$(find ./created_rules -maxdepth 1 -type f -name "*prometheus*.yaml" -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null \
        | head -n1 || true)

    if [[ -z "$TARGET_FALCO_RULES_FILE" || ! -f "$TARGET_FALCO_RULES_FILE" ]]; then
        echo "Error: Could not find generated Falco YAML file in ./created_rules"
        exit 1
    fi

    if [[ -z "$TARGET_PROM_RULES_FILE" || ! -f "$TARGET_PROM_RULES_FILE" ]]; then
        echo "Warning: Could not find generated Prometheus YAML file in ./created_rules"
    fi
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
# PHASE 2: MEASURE RULE APPLY / DEACTIVATE TIME
# ==============================================================================
apply_start=$(date +%s%3N)

if [[ "$DEACTIVATE_RULES" -eq 1 ]]; then
    echo "Deactivating Falco & Prometheus rules..."
    
    # 1. Deactivate Falco Rules (Helm reset)
    helm upgrade --namespace falco falco falcosecurity/falco \
        --set tty=true \
        --set falcoctl.artifact.install.enabled=false \
        --set falcoctl.artifact.follow.enabled=false \
        --atomic --timeout 30s \
        -f "disable_rules.yaml" > /dev/null

    until kubectl rollout status daemonset/falco -n falco --timeout=60s > /dev/null 2>&1; do
        sleep 2
    done

    # 2. Deactivate Prometheus Rules (Delete PrometheusRule CRD)
    PROM_FILES=$(find ./created_rules -maxdepth 1 -type f -name "*prometheus*.yaml" 2>/dev/null || true)
    if [[ -n "$PROM_FILES" ]]; then
        for pf in $PROM_FILES; do
            kubectl delete -f "$pf" --ignore-not-found=true > /dev/null 2>&1 || true
        done
    fi
    # Delete any lingering custom prometheus rules
    kubectl delete prometheusrule --all -A --ignore-not-found=true > /dev/null 2>&1 || true

else
    echo "Applying active rules:"
    echo " - Falco: $TARGET_FALCO_RULES_FILE"
    echo " - Prometheus: ${TARGET_PROM_RULES_FILE:-None found}"

    # 1. Apply Falco rules via Helm
    helm upgrade --namespace falco falco falcosecurity/falco \
        --set tty=true \
        --set falcoctl.artifact.install.enabled=false \
        --set falcoctl.artifact.follow.enabled=false \
        --atomic --timeout 30s \
        -f "$TARGET_FALCO_RULES_FILE" > /dev/null

    until kubectl rollout status daemonset/falco -n falco --timeout=60s > /dev/null 2>&1; do
        sleep 2
    done

    # 2. Apply Prometheus rules via kubectl
    if [[ -n "${TARGET_PROM_RULES_FILE:-}" && -f "$TARGET_PROM_RULES_FILE" ]]; then
        kubectl apply -f "$TARGET_PROM_RULES_FILE" > /dev/null
    fi
fi

apply_end=$(date +%s%3N)
apply_elapsed=$((apply_end - apply_start))

sleep 2

# ==============================================================================
# PHASE 3: WORKFLOW EXECUTION & SAMPLING (Falco & Prometheus)
# ==============================================================================
(
    while true; do
        now_ms=$(date +%s%3N)
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
    echo "Total Elapsed: $total_elapsed"
fi
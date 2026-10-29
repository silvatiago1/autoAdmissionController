#!/usr/bin/env bash

set -eu
set -o pipefail 2>/dev/null || true

SKIP_APPLY=0
HEADLESS=0
WAIT_WORKFLOW=0
DEACTIVATE_RULES=0
SKIP_HELM=0
INPUT_FILE=""

creation_elapsed=0
apply_elapsed=0
workflow_elapsed=0

# Parse optional flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-helm)
            SKIP_HELM=1
            shift
            ;;
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
    echo "Usage: $0 [--skip-helm] [--skip-apply|-s] [--headless|-h] [--wait|-w] [--deactivate-rules|-d] <input_file>"
    exit 1
fi

# Log file definitions
CREATION_LOG="${CREATION_LOG:-benchmark_rule_creation_times.txt}"
APPLY_LOG="${APPLY_LOG:-benchmark_rule_apply_times.txt}"
WORKFLOW_LOG="${WORKFLOW_LOG:-benchmark_workflow_times.txt}"

# Default series log targets separately if not explicitly exported by parent script
if [[ -z "${MEMORY_SERIES_LOG:-}" ]]; then
    if [[ "$DEACTIVATE_RULES" -eq 1 ]]; then
        MEMORY_SERIES_LOG="benchmark_workflow_inactive_ram_timeseries.csv"
        CPU_SERIES_LOG="benchmark_workflow_inactive_cpu_timeseries.csv"
    else
        MEMORY_SERIES_LOG="benchmark_workflow_active_ram_timeseries.csv"
        CPU_SERIES_LOG="benchmark_workflow_active_cpu_timeseries.csv"
    fi
fi

if [[ -z "${CPU_SERIES_LOG:-}" ]]; then
    CPU_SERIES_LOG="${MEMORY_SERIES_LOG/_ram_/_cpu_}"
    CPU_SERIES_LOG="${CPU_SERIES_LOG%.csv}_cpu_usage_timeseries.csv"
fi

if [[ ! -f "$MEMORY_SERIES_LOG" ]]; then
    echo "timestamp_epoch_ms,process_name,vsz_kb,rss_kb" > "$MEMORY_SERIES_LOG"
fi

if [[ ! -f "$CPU_SERIES_LOG" ]]; then
    echo "timestamp_epoch_ms,process_name,cpu_percent" > "$CPU_SERIES_LOG"
fi

# Cleanup stuck helm lock if present
STUCK_SECRET=$(kubectl get secrets -n falco -l "owner=helm,name=falco,status=pending-upgrade" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$STUCK_SECRET" ]]; then
    kubectl delete secret "$STUCK_SECRET" -n falco > /dev/null 2>&1 || true
fi

# ==============================================================================
# HELPER FUNCTIONS FOR RULE MANAGEMENT
# ==============================================================================
deactivate_all_rules() {
    echo "Deactivating existing Falco & Prometheus rules..."
    
    # 1. Deactivate Falco Rules (Helm reset to default/disabled state)
    helm upgrade --namespace falco falco falcosecurity/falco \
        --set tty=true \
        --set falcoctl.artifact.install.enabled=false \
        --set falcoctl.artifact.follow.enabled=false \
        --atomic --timeout 30s \
        -f "disable_rules.yaml" > /dev/null

    until kubectl rollout status daemonset/falco -n falco --timeout=60s > /dev/null 2>&1; do
        sleep 2
    done

    # 2. Deactivate Prometheus Rules (Delete existing PrometheusRule CRDs)
    PROM_FILES=$(find ./created_rules -maxdepth 1 -type f -name "*prometheus*.yaml" 2>/dev/null || true)
    if [[ -n "$PROM_FILES" ]]; then
        for pf in $PROM_FILES; do
            kubectl delete -f "$pf" --ignore-not-found=true > /dev/null 2>&1 || true
        done
    fi
    kubectl delete prometheusrule --all -A --ignore-not-found=true > /dev/null 2>&1 || true
}

apply_active_rules() {
    echo "Applying active rules:"
    echo "Falco: $TARGET_FALCO_RULES_FILE"
    echo "Prometheus: ${TARGET_PROM_RULES_FILE:-None found}"

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
}

# ==============================================================================
# PHASES 1 & 2: RULE CREATION & HELM APPLY (BYPASSED IF --skip-helm IS SET)
# ==============================================================================
if [[ "$SKIP_HELM" -eq 0 ]]; then

    # --- PHASE 1: RULE CREATION ---
    if [[ "$DEACTIVATE_RULES" -eq 1 ]]; then
        echo "Deactivate flag active: Generating rules (untimed) so they can be applied prior to testing deactivation..."
        python3 main.py "$INPUT_FILE" > /dev/null 2>&1 || true
        creation_elapsed=0
    else
        echo "Running rule generator for Falco and Prometheus..."
        creation_start=$(date +%s%3N)
        python3 main.py "$INPUT_FILE"
        creation_end=$(date +%s%3N)
        creation_elapsed=$((creation_end - creation_start))
    fi

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

    # Stop here if --skip-apply is set
    if [[ "$SKIP_APPLY" -eq 1 ]]; then
        if [[ "${BENCHMARK_MODE:-0}" -eq 1 && "$DEACTIVATE_RULES" -eq 0 ]]; then
            echo "$creation_elapsed" >> "$CREATION_LOG"
            echo "Rule Creation Elapsed: $creation_elapsed"
            echo "Elapsed: $creation_elapsed"
        fi
        exit 0
    fi

    # --- PHASE 2: MEASURE RULE APPLY / DEACTIVATE TIME ---
    if [[ "$DEACTIVATE_RULES" -eq 1 ]]; then
        apply_active_rules
        apply_start=$(date +%s%3N)
        deactivate_all_rules
        apply_end=$(date +%s%3N)
        apply_elapsed=$((apply_end - apply_start))
    else
        deactivate_all_rules
        apply_start=$(date +%s%3N)
        apply_active_rules
        apply_end=$(date +%s%3N)
        apply_elapsed=$((apply_end - apply_start))
    fi

    sleep 2

else
    echo "Skipping rule generation and Helm deployment (--skip-helm)..."
fi

# ==============================================================================
# PHASE 3: WORKFLOW EXECUTION & SAMPLING (Falco & Prometheus via ps aux)
# ==============================================================================
(
    while true; do
        now_ms=$(date +%s%3N)
        
        # 1. Sample Falco process metrics
        falco_output=$(ps aux | grep falco | grep -v grep | head -n1 | awk '{ print $3 ";" $5 ";" $6; }' || true)
        if [[ -n "$falco_output" ]]; then
            IFS=';' read -r cpu_pct vsz rss <<< "$falco_output"
            if [[ -n "$cpu_pct" ]]; then
                echo "${now_ms},falco,${cpu_pct}" >> "$CPU_SERIES_LOG"
            fi
            if [[ -n "$vsz" && -n "$rss" ]]; then
                echo "${now_ms},falco,${vsz},${rss}" >> "$MEMORY_SERIES_LOG"
            fi
        fi

        # 2. Sample Prometheus process metrics (using port 7042)
        prom_output=$(ps aux | grep monitoring-kube-prometheus-prometheus.default | grep -v grep | head -n1 | awk '{ print $3 ";" $5 ";" $6; }' || true)
        if [[ -n "$prom_output" ]]; then
            IFS=';' read -r cpu_pct vsz rss <<< "$prom_output"
            if [[ -n "$cpu_pct" ]]; then
                echo "${now_ms},prometheus,${cpu_pct}" >> "$CPU_SERIES_LOG"
            fi
            if [[ -n "$vsz" && -n "$rss" ]]; then
                echo "${now_ms},prometheus,${vsz},${rss}" >> "$MEMORY_SERIES_LOG"
            fi
        fi

        sleep 3
    done
) &
MONITOR_PID=$!
trap 'kill "$MONITOR_PID" 2>/dev/null || true' EXIT

echo "Submitting Argo workflow..."
workflow_start=$(date +%s%3N)

# 1. Capture Argo submission output safely
RAW_SUBMIT_OUTPUT=$(argo submit -n argo "$INPUT_FILE" -o name 2>&1) || {
    echo "Error: Failed to submit Argo workflow!"
    echo "$RAW_SUBMIT_OUTPUT"
    exit 1
}

# 2. Extract clean workflow name (removes 'workflow.argoproj.io/' prefix if present)
WORKFLOW_NAME=$(echo "$RAW_SUBMIT_OUTPUT" | sed 's|^workflow\.argoproj\.io/||' | tr -d '[:space:]')

if [[ -z "$WORKFLOW_NAME" ]]; then
    echo "Error: Could not parse workflow name from output: $RAW_SUBMIT_OUTPUT"
    exit 1
fi

echo "Submitted workflow: $WORKFLOW_NAME"
echo "Watching execution..."

# 3. Watch workflow completion (respecting --headless flag)
if [[ "$HEADLESS" -eq 1 ]]; then
    argo watch -n argo "$WORKFLOW_NAME" > /dev/null 2>&1 || true
else
    argo watch -n argo "$WORKFLOW_NAME"
fi

workflow_end=$(date +%s%3N)
workflow_elapsed=$((workflow_end - workflow_start))

# ==============================================================================
# LOG OUTPUTS FOR BENCHMARKING
# ==============================================================================
if [[ "${BENCHMARK_MODE:-0}" -eq 1 ]]; then
    if [[ "$SKIP_HELM" -eq 0 && "$DEACTIVATE_RULES" -eq 0 ]]; then
        echo "$creation_elapsed" >> "$CREATION_LOG"
        echo "Rule Creation Elapsed: $creation_elapsed"
    fi
    
    if [[ "$SKIP_HELM" -eq 0 ]]; then
        echo "$apply_elapsed" >> "$APPLY_LOG"
        echo "Rule Apply/Deactivate Elapsed: $apply_elapsed"
    fi

    echo "$workflow_elapsed" >> "$WORKFLOW_LOG"
    echo "Workflow Elapsed: $workflow_elapsed"
    
    total_elapsed=$((creation_elapsed + apply_elapsed + workflow_elapsed))
    echo "Total Elapsed: $total_elapsed"
fi
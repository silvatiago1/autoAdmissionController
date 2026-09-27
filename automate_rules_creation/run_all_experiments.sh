#!/usr/bin/env bash

set -eu
set -o pipefail 2>/dev/null || true

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <iterations> <file_1.yaml> <file_2.yaml> [output_directory]"
    echo "Example: $0 200 workflow_a.yaml workflow_b.yaml ./benchmark_results"
    exit 1
fi

ITERATIONS="$1"
FILE_1="$2"
FILE_2="$3"
FILE_3="${4:-}"
BASE_OUT_DIR="${5:-./benchmark_results}"

export BENCHMARK_MODE=1

# Global iteration counter across all files and test phases
GLOBAL_ITERATION_COUNT=0

cleanup_workflow_pods() {
    echo "🧹 [Global Iteration $GLOBAL_ITERATION_COUNT] Cleaning up Argo workflow pods..."
    kubectl delete pods -n argo -l workflows.argoproj.io/workflow --ignore-not-found=true > /dev/null 2>&1 || true
    argo delete --all -n argo --yes > /dev/null 2>&1 || true
}

run_test_suite_for_file() {
    local target_file="$1"
    if [[ -z "$target_file" ]]; then
        return 0
    fi

    local base_name
    base_name=$(basename "$target_file" | sed 's/\.[^.]*$//')
    
    local target_dir="${BASE_OUT_DIR}/${base_name}"
    mkdir -p "$target_dir"

    echo "=================================================================="
    echo " Starting Benchmark Suite for File: $target_file"
    echo " Output Directory: $target_dir"
    echo " Required Iterations per Phase: $ITERATIONS"
    echo "=================================================================="

    # Target Metric Output Files
    export CREATION_LOG="${target_dir}/${base_name}_rule_creation_times_ms.txt"
    export WORKFLOW_ACTIVE_LOG="${target_dir}/${base_name}_workflow_active_rules_times_ms.txt"
    export WORKFLOW_INACTIVE_LOG="${target_dir}/${base_name}_workflow_inactive_rules_times_ms.txt"
    export APPLY_ACTIVE_LOG="${target_dir}/${base_name}_rule_apply_active_times_ms.txt"
    export APPLY_INACTIVE_LOG="${target_dir}/${base_name}_rule_apply_inactive_times_ms.txt"
    
    # Separated RAM Series Log Targets
    local active_ram_log="${target_dir}/${base_name}_active_ram_usage_timeseries.csv"
    local inactive_ram_log="${target_dir}/${base_name}_inactive_ram_usage_timeseries.csv"

    get_line_count() {
        local file="$1"
        if [[ -f "$file" ]]; then
            wc -l < "$file" | tr -d ' '
        else
            echo "0"
        fi
    }

    # 1. RUN CREATION & ACTIVE RULES BENCHMARKS
    echo "--> Benchmarking Rule Creation, Application, and Active Workflow..."
    export MEMORY_SERIES_LOG="$active_ram_log"

    while true; do
        current_lines=$(get_line_count "$WORKFLOW_ACTIVE_LOG")
        if [[ "$current_lines" -ge "$ITERATIONS" ]]; then
            echo "✔ Active rules metrics reached $ITERATIONS iterations."
            break
        fi

        iter_num=$((current_lines + 1))
        echo "Running iteration ${iter_num}/$ITERATIONS for Active Rules (Global Count: $((GLOBAL_ITERATION_COUNT + 1)))..."
        export WORKFLOW_LOG="$WORKFLOW_ACTIVE_LOG"
        export APPLY_LOG="$APPLY_ACTIVE_LOG"
        
        if ./automate_creation.sh -h -w "$target_file"; then
            GLOBAL_ITERATION_COUNT=$((GLOBAL_ITERATION_COUNT + 1))
            
            # Delete pods every 50 global iterations across all files/phases
            if (( GLOBAL_ITERATION_COUNT % 50 == 0 )); then
                cleanup_workflow_pods
            fi
        else
            echo "Execution failed. Retrying iteration..."
            sleep 3
            continue
        fi
    done

    # 2. RUN WORKFLOW WITH RULES DEACTIVATED (Skips Rule Creation)
    echo "--> Benchmarking Workflow Runtime with Rules DEACTIVATED..."
    export MEMORY_SERIES_LOG="$inactive_ram_log"

    while true; do
        current_lines=$(get_line_count "$WORKFLOW_INACTIVE_LOG")
        if [[ "$current_lines" -ge "$ITERATIONS" ]]; then
            echo "✔ Inactive rules metrics reached $ITERATIONS iterations."
            break
        fi

        iter_num=$((current_lines + 1))
        echo "Running iteration ${iter_num}/$ITERATIONS for Inactive Rules (Global Count: $((GLOBAL_ITERATION_COUNT + 1)))..."
        export WORKFLOW_LOG="$WORKFLOW_INACTIVE_LOG"
        export APPLY_LOG="$APPLY_INACTIVE_LOG"
        
        if ./automate_creation.sh -h -w -d "$target_file"; then
            GLOBAL_ITERATION_COUNT=$((GLOBAL_ITERATION_COUNT + 1))
            
            # Delete pods every 50 global iterations across all files/phases
            if (( GLOBAL_ITERATION_COUNT % 50 == 0 )); then
                cleanup_workflow_pods
            fi
        else
            echo "Execution failed. Retrying iteration..."
            sleep 3
            continue
        fi
    done

    echo "Finished all benchmark iterations for $target_file."
    echo ""
}

# Run benchmark suites for input files
run_test_suite_for_file "$FILE_1"
run_test_suite_for_file "$FILE_2"
if [[ -n "$FILE_3" ]]; then
    run_test_suite_for_file "$FILE_3"
fi

echo "=================================================================="
echo " All Benchmarks Completed Successfully!"
echo " Total Global Iterations Executed: $GLOBAL_ITERATION_COUNT"
echo " Results stored in: $BASE_OUT_DIR"
echo "=================================================================="
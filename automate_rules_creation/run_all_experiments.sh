#!/usr/bin/env bash

set -eu
set -o pipefail 2>/dev/null || true

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <iterations> <file_1.yaml> <file_2.yaml> [output_directory]"
    echo "Example: $0 5 workflow_a.yaml workflow_b.yaml ./metrics/benchmark_results"
    exit 1
fi

ITERATIONS="$1"
FILE_1="$2"
FILE_2="$3"
BASE_OUT_DIR="${4:-./benchmark_results}"

export BENCHMARK_MODE=1

run_test_suite_for_file() {
    local target_file="$1"
    local base_name
    base_name=$(basename "$target_file" | sed 's/\.[^.]*$//')
    
    local target_dir="${BASE_OUT_DIR}/${base_name}"
    mkdir -p "$target_dir"

    echo "=================================================================="
    echo " Starting Benchmark Suite for File: $target_file"
    echo " Output Directory: $target_dir"
    echo " Required Iterations: $ITERATIONS"
    echo "=================================================================="

    # Target Metric Output Files
    export CREATION_LOG="${target_dir}/${base_name}_rule_creation_times_ms.txt"
    export WORKFLOW_ACTIVE_LOG="${target_dir}/${base_name}_workflow_active_rules_times_ms.txt"
    export WORKFLOW_INACTIVE_LOG="${target_dir}/${base_name}_workflow_inactive_rules_times_ms.txt"
    export APPLY_ACTIVE_LOG="${target_dir}/${base_name}_rule_apply_active_times_ms.txt"
    export APPLY_INACTIVE_LOG="${target_dir}/${base_name}_rule_apply_inactive_times_ms.txt"
    export MEMORY_SERIES_LOG="${target_dir}/${base_name}_ram_usage_timeseries.csv"

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
    while true; do
        current_lines=$(get_line_count "$WORKFLOW_ACTIVE_LOG")
        if [[ "$current_lines" -ge "$ITERATIONS" ]]; then
            echo "✔ Active rules metrics reached $ITERATIONS iterations."
            break
        fi

        echo "Running iteration $((current_lines + 1))/$ITERATIONS for Active Rules..."
        export WORKFLOW_LOG="$WORKFLOW_ACTIVE_LOG"
        export APPLY_LOG="$APPLY_ACTIVE_LOG"
        
        ./automate_creation.sh -h -w "$target_file" || {
            echo "Execution failed. Retrying iteration..."
            sleep 3
            continue
        }
    done

    # 2. RUN WORKFLOW WITH RULES DEACTIVATED (Skips Rule Creation)
    echo "--> Benchmarking Workflow Runtime with Rules DEACTIVATED (Creation Skipped)..."
    while true; do
        current_lines=$(get_line_count "$WORKFLOW_INACTIVE_LOG")
        if [[ "$current_lines" -ge "$ITERATIONS" ]]; then
            echo "✔ Inactive rules metrics reached $ITERATIONS iterations."
            break
        fi

        echo "Running iteration $((current_lines + 1))/$ITERATIONS for Inactive Rules..."
        export WORKFLOW_LOG="$WORKFLOW_INACTIVE_LOG"
        export APPLY_LOG="$APPLY_INACTIVE_LOG"
        
        # -d flag deactivates rules and skips main.py rule generation
        ./automate_creation.sh -h -w -d "$target_file" || {
            echo "Execution failed. Retrying iteration..."
            sleep 3
            continue
        }
    done

    echo "Finished all benchmark iterations for $target_file."
    echo ""
}

# Run benchmark suites for both input files
run_test_suite_for_file "$FILE_1"
run_test_suite_for_file "$FILE_2"

echo "=================================================================="
echo " All Benchmarks Completed Successfully!"
echo " Results stored in: $BASE_OUT_DIR"
echo "=================================================================="
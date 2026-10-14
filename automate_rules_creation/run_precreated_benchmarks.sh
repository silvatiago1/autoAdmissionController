#!/usr/bin/env bash

set -eu
set -o pipefail 2>/dev/null || true

if [[ $# -lt 4 ]]; then
    echo "Usage: $0 <iterations> <workflow.yaml> <falco_rules.yaml> <prom_rules.yaml> [...] [output_directory]"
    echo "Example: $0 200 artifacts.yaml artifact-falco-rules.yaml artifact-prom-rules.yaml ./benchmark_results"
    exit 1
fi

ITERATIONS="$1"
shift

# Check if the last argument is an output directory (total triplet args % 3 != 0)
BASE_OUT_DIR="./benchmark_results"
ARG_COUNT=$#

if [[ $((ARG_COUNT % 3)) -ne 0 ]]; then
    # Last arg is output directory
    eval "BASE_OUT_DIR=\${$ARG_COUNT}"
    # Remove last arg from positional list
    set -- "${@:1:$((ARG_COUNT-1))}"
fi

export BENCHMARK_MODE=1

# Global iteration counter across all files and test phases
GLOBAL_ITERATION_COUNT=0

cleanup_workflow_pods() {
    echo "🧹 [Global Iteration $GLOBAL_ITERATION_COUNT] Cleaning up Argo workflow pods..."
    kubectl delete pods -n argo -l workflows.argoproj.io/workflow --ignore-not-found=true > /dev/null 2>&1 || true
    argo delete --all -n argo --yes > /dev/null 2>&1 || true
}

apply_helm_with_retry() {
    local rule_file="$1"
    local max_retries=3
    local attempt=1

    while [[ $attempt -le $max_retries ]]; do
        echo "Attempt $attempt/$max_retries: Applying $rule_file..."

        # 1. Clear any stuck pending secrets BEFORE attempting upgrade
        kubectl delete secret -n falco -l "owner=helm,name=falco,status=pending-upgrade" > /dev/null 2>&1 || true

        # 2. Run helm upgrade (showing error output on failure)
        if helm upgrade --namespace falco falco falcosecurity/falco \
            --set tty=true \
            --set falcoctl.artifact.install.enabled=false \
            --set falcoctl.artifact.follow.enabled=false \
            -f "$rule_file"; then
            echo "Helm upgrade succeeded!"
            return 0
        fi

        echo "Helm upgrade failed. Cleaning up pending state and attempting rollback..."
        
        # 3. Clear pending lock again so rollback can actually run
        kubectl delete secret -n falco -l "owner=helm,name=falco,status=pending-upgrade" > /dev/null 2>&1 || true
        helm rollback falco -n falco > /dev/null 2>&1 || true

        attempt=$((attempt + 1))
        if [[ $attempt -le $max_retries ]]; then
            echo "Retrying in 5 seconds..."
            sleep 5
        fi
    done

    echo "Error: Helm upgrade failed after $max_retries attempts."
    return 1
}

apply_prometheus_rules() {
    local prom_file="$1"
    echo "Applying Prometheus rules: $prom_file..."
    # Clear existing instances first, then create (handles generateName)
    kubectl delete -f "$prom_file" --ignore-not-found=true > /dev/null 2>&1 || true
    kubectl create -f "$prom_file" > /dev/null
}

run_test_suite_for_triplet() {
    local target_workflow="$1"
    local target_falco_rules="$2"
    local target_prom_rules="$3"
    
    local wf_name
    wf_name=$(basename "$target_workflow" | sed 's/\.[^.]*$//')
    local falco_name
    falco_name=$(basename "$target_falco_rules" | sed 's/\.[^.]*$//')
    local prom_name
    prom_name=$(basename "$target_prom_rules" | sed 's/\.[^.]*$//')
    
    local target_dir="${BASE_OUT_DIR}/${wf_name}_combined"
    mkdir -p "$target_dir"

    echo "=================================================================="
    echo " Workflow File: $target_workflow"
    echo " Falco Rules: $target_falco_rules"
    echo " Prometheus Rules: $target_prom_rules"
    echo " Output Directory: $target_dir"
    echo " Required Iterations: $ITERATIONS"
    echo "=================================================================="

    export WORKFLOW_ACTIVE_LOG="${target_dir}/${wf_name}_active_rules_times_ms.txt"
    export MEMORY_SERIES_LOG="${target_dir}/${wf_name}_ram_usage_timeseries.csv"

    get_line_count() {
        local file="$1"
        if [[ -f "$file" ]]; then
            wc -l < "$file" | tr -d ' '
        else
            echo "0"
        fi
    }

    # ------------------------------------------------------------------
    # ACTIVE RULES PHASE (Falco + Prometheus Applied Together)
    # ------------------------------------------------------------------
    echo "--> Applying pre-created Falco and Prometheus rules ONCE before workflow iterations..."
    apply_helm_with_retry "$target_falco_rules"
    apply_prometheus_rules "$target_prom_rules"

    echo "--> Running Active Rules Workflow Iterations..."
    while true; do
        current_lines=$(get_line_count "$WORKFLOW_ACTIVE_LOG")
        if [[ "$current_lines" -ge "$ITERATIONS" ]]; then
            echo "✔ Active rules metrics reached $ITERATIONS iterations."
            break
        fi

        iter_num=$((current_lines + 1))
        echo "Active Rules Iteration ${iter_num}/$ITERATIONS (Global Count: $((GLOBAL_ITERATION_COUNT + 1)))..."
        export WORKFLOW_LOG="$WORKFLOW_ACTIVE_LOG"
        
        # Call automate_creation.sh with --skip-helm (skips rule gen + helm upgrade per iteration)
        if ./automate_creation.sh --skip-helm -h -w "$target_workflow"; then
            GLOBAL_ITERATION_COUNT=$((GLOBAL_ITERATION_COUNT + 1))
            
            if (( GLOBAL_ITERATION_COUNT % 50 == 0 )); then
                cleanup_workflow_pods
            fi
        else
            echo "Execution failed. Retrying iteration..."
            sleep 3
            continue
        fi
    done

    echo "Finished all active iterations for $target_workflow with $target_falco_rules and $target_prom_rules."
    echo ""
}

# Process triplets passed as arguments: <wf1> <falco1> <prom1> [<wf2> <falco2> <prom2> ...]
while [[ $# -gt 0 ]]; do
    WORKFLOW_FILE="${1:-}"
    FALCO_RULE_FILE="${2:-}"
    PROM_RULE_FILE="${3:-}"

    if [[ -z "$WORKFLOW_FILE" || -z "$FALCO_RULE_FILE" || -z "$PROM_RULE_FILE" ]]; then
        echo "Error: Missing workflow, Falco, or Prometheus rule file in triplet."
        echo "Usage: $0 <iterations> <workflow.yaml> <falco_rules.yaml> <prom_rules.yaml> [...] [output_directory]"
        exit 1
    fi

    if [[ ! -f "$WORKFLOW_FILE" ]]; then
        echo "Error: Workflow file '$WORKFLOW_FILE' does not exist."
        exit 1
    fi

    if [[ ! -f "$FALCO_RULE_FILE" ]]; then
        echo "Error: Pre-created Falco rule file '$FALCO_RULE_FILE' does not exist."
        exit 1
    fi

    if [[ ! -f "$PROM_RULE_FILE" ]]; then
        echo "Error: Pre-created Prometheus rule file '$PROM_RULE_FILE' does not exist."
        exit 1
    fi

    shift 3
    run_test_suite_for_triplet "$WORKFLOW_FILE" "$FALCO_RULE_FILE" "$PROM_RULE_FILE"
done

echo "=================================================================="
echo " All Pre-Created Rule Benchmarks Completed!"
echo " Total Global Iterations Executed: $GLOBAL_ITERATION_COUNT"
echo " Results stored in: $BASE_OUT_DIR"
echo "=================================================================="
#!/usr/bin/env bash

set -eu
set -o pipefail 2>/dev/null || true

if [[ $# -lt 4 ]]; then
    echo "Usage: $0 <iterations> <benchmark_tag> <workflow.yaml> <falco_rules.yaml> <prom_rules.yaml> [...]"
    echo "Example: $0 200 inactive artifacts.yaml artifact-falco-rules.yaml artifact-prom-rules.yaml"
    exit 1
fi

ITERATIONS="$1"
BENCHMARK_TAG="$2"
shift 2

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

        kubectl delete secret -n falco -l "owner=helm,name=falco,status=pending-upgrade" > /dev/null 2>&1 || true

        if helm upgrade --namespace falco falco falcosecurity/falco \
            --set tty=true \
            --set falcoctl.artifact.install.enabled=false \
            --set falcoctl.artifact.follow.enabled=false \
            -f "$rule_file"; then
            echo "Helm upgrade succeeded!"
            return 0
        fi

        echo "Helm upgrade failed. Cleaning up pending state and attempting rollback..."
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
    kubectl delete -f "$prom_file" --ignore-not-found=true > /dev/null 2>&1 || true
    kubectl create -f "$prom_file" > /dev/null
}

run_test_suite_for_triplet() {
    local target_workflow="$1"
    local target_falco_rules="$2"
    local target_prom_rules="$3"
    
    local wf_name
    wf_name=$(basename "$target_workflow" | sed 's/\.[^.]*$//')
    
    local target_dir="./benchmark_results/${BENCHMARK_TAG}/${wf_name}_combined"
    mkdir -p "$target_dir"

    echo "=================================================================="
    echo " Benchmark Tag: $BENCHMARK_TAG"
    echo " Workflow File: $target_workflow"
    echo " Falco Rules: $target_falco_rules"
    echo " Prometheus Rules: $target_prom_rules"
    echo " Output Directory: $target_dir"
    echo " Required Iterations: $ITERATIONS"
    echo "=================================================================="

    export WORKFLOW_ACTIVE_LOG="${target_dir}/${wf_name}_active_rules_times_ms.txt"
    export MEMORY_SERIES_LOG="${target_dir}/${wf_name}_ram_usage_timeseries.csv"
    export CPU_SERIES_LOG="${target_dir}/${wf_name}_cpu_usage_timeseries.csv"

    get_line_count() {
        local file="$1"
        if [[ -f "$file" ]]; then
            wc -l < "$file" | tr -d ' '
        else
            echo "0"
        fi
    }

    # ------------------------------------------------------------------
    # SETUP PHASE: Deactivate if inactive tag, otherwise apply active rules
    # ------------------------------------------------------------------
    if [[ "$BENCHMARK_TAG" == "inactive" ]]; then
        echo "--> Deactivating Falco and Prometheus rules ONCE before workflow iterations (Inactive mode)..."
        helm upgrade --namespace falco falco falcosecurity/falco \
            --set tty=true \
            --set falcoctl.artifact.install.enabled=false \
            --set falcoctl.artifact.follow.enabled=false \
            --atomic --timeout 30s \
            -f "disable_rules.yaml" > /dev/null || true

        until kubectl rollout status daemonset/falco -n falco --timeout=60s > /dev/null 2>&1; do
            sleep 2
        done

        kubectl delete -f "$target_prom_rules" --ignore-not-found=true > /dev/null 2>&1 || true
        kubectl delete prometheusrule --all -A --ignore-not-found=true > /dev/null 2>&1 || true
    else
        echo "--> Applying pre-created Falco and Prometheus rules ONCE before workflow iterations..."
        apply_helm_with_retry "$target_falco_rules"
        apply_prometheus_rules "$target_prom_rules"
    fi

    echo "--> Running Workflow Iterations..."
    while true; do
        current_lines=$(get_line_count "$WORKFLOW_ACTIVE_LOG")
        if [[ "$current_lines" -ge "$ITERATIONS" ]]; then
            echo "✔ Metrics reached $ITERATIONS iterations."
            break
        fi

        iter_num=$((current_lines + 1))
        echo "Iteration ${iter_num}/$ITERATIONS (Global Count: $((GLOBAL_ITERATION_COUNT + 1)))..."
        export WORKFLOW_LOG="$WORKFLOW_ACTIVE_LOG"
        
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

    echo "Finished all iterations for $target_workflow."
    echo ""
}

# Process triplets passed as arguments
while [[ $# -gt 0 ]]; do
    WORKFLOW_FILE="${1:-}"
    FALCO_RULE_FILE="${2:-}"
    PROM_RULE_FILE="${3:-}"

    if [[ -z "$WORKFLOW_FILE" || -z "$FALCO_RULE_FILE" || -z "$PROM_RULE_FILE" ]]; then
        echo "Error: Missing workflow, Falco, or Prometheus rule file in triplet."
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
echo " All Benchmarks Completed!"
echo " Total Global Iterations Executed: $GLOBAL_ITERATION_COUNT"
echo " Results stored in: ./benchmark_results/${BENCHMARK_TAG}/"
echo "=================================================================="
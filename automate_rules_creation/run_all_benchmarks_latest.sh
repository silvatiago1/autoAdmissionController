#!/usr/bin/env bash

set -eu
set -o pipefail 2>/dev/null || true

ITERATIONS=2
BASE_OUT_DIR="./benchmark_results"

export BENCHMARK_MODE=1

# Global iteration counter across all files, suites, and test phases
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
        echo "Attempt $attempt/$max_retries: Applying $rule_file via Helm..."

        # Robustly clear any stuck pending helm release secrets
        kubectl delete secret -n falco -l "owner=helm,name=falco" --ignore-not-found=true > /dev/null 2>&1 || true
        kubectl get secrets -n falco -o name 2>/dev/null | grep "sh.helm.release.v1.falco" | while read -r sname; do
            status=$(kubectl get "$sname" -n falco -o jsonpath='{.metadata.annotations.status}' 2>/dev/null || true)
            if [[ "$status" == *pending* ]]; then
                echo "Removing stuck pending Helm secret: $sname (status: $status)"
                kubectl delete "$sname" -n falco > /dev/null 2>&1 || true
            fi
        done

        # Added --atomic and --timeout 60s to prevent indefinite hanging
        if helm upgrade --namespace falco falco falcosecurity/falco \
            --set tty=true \
            --set falcoctl.artifact.install.enabled=false \
            --set falcoctl.artifact.follow.enabled=false \
            --atomic --timeout 60s \
            -f "$rule_file"; then
            echo "Helm upgrade succeeded!"
            return 0
        fi

        echo "Helm upgrade failed. Cleaning up pending state and attempting rollback..."
        kubectl delete secret -n falco -l "owner=helm,name=falco" --ignore-not-found=true > /dev/null 2>&1 || true
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

get_line_count() {
    local file="$1"
    if [[ -f "$file" ]]; then
        wc -l < "$file" | tr -d ' '
    else
        echo "0"
    fi
}

run_benchmark_suite() {
    local benchmark_tag="$1"
    local workflow_file="$2"
    local falco_rules_file="$3"
    local prom_rules_file="$4"

    local wf_name
    wf_name=$(basename "$workflow_file" | sed 's/\.[^.]*$//')
    
    local target_dir="${BASE_OUT_DIR}/${benchmark_tag}/${wf_name}_combined"
    mkdir -p "$target_dir"

    echo "=================================================================="
    echo " Benchmark Tag: $benchmark_tag"
    echo " Workflow File: $workflow_file"
    echo " Falco Rules: $falco_rules_file"
    echo " Prometheus Rules: $prom_rules_file"
    echo " Output Directory: $target_dir"
    echo " Required Iterations: $ITERATIONS"
    echo "=================================================================="

    export WORKFLOW_ACTIVE_LOG="${target_dir}/${wf_name}_active_rules_times_ms.txt"
    export MEMORY_SERIES_LOG="${target_dir}/${wf_name}_ram_usage_timeseries.csv"
    export CPU_SERIES_LOG="${target_dir}/${wf_name}_cpu_usage_timeseries.csv"

    # Setup Phase (Deactivate rules if tag is 'inactive', otherwise apply rules)
    if [[ "$benchmark_tag" == "inactive" ]]; then
        echo "--> Deactivating Falco and Prometheus rules ONCE before workflow iterations (Inactive mode)..."
        
        kubectl delete secret -n falco -l "owner=helm,name=falco" --ignore-not-found=true > /dev/null 2>&1 || true

        helm upgrade --namespace falco falco falcosecurity/falco \
            --set tty=true \
            --set falcoctl.artifact.install.enabled=false \
            --set falcoctl.artifact.follow.enabled=false \
            --atomic --timeout 60s \
            -f "disable_rules.yaml" > /dev/null || true

        # Guarded rollout wait loop with a maximum attempt limit to prevent infinite freezing
        echo "Waiting for Falco daemonset rollout (inactive mode)..."
        local rollout_attempt=0
        local max_rollout_attempts=15
        while [[ $rollout_attempt -lt $max_rollout_attempts ]]; do
            if kubectl rollout status daemonset/falco -n falco --timeout=10s > /dev/null 2>&1; then
                echo "Falco rollout successful."
                break
            fi
            rollout_attempt=$((rollout_attempt + 1))
            echo "Waiting for rollout... (attempt $rollout_attempt/$max_rollout_attempts)"
            sleep 2
        done

        kubectl delete -f "$prom_rules_file" --ignore-not-found=true > /dev/null 2>&1 || true
        kubectl delete prometheusrule --all -A --ignore-not-found=true > /dev/null 2>&1 || true
    else
        echo "--> Applying pre-created Falco and Prometheus rules ONCE before workflow iterations..."
        apply_helm_with_retry "$falco_rules_file"
        apply_prometheus_rules "$prom_rules_file"
    fi

    echo "--> Running Workflow Iterations..."
    while true; do
        current_lines=$(get_line_count "$WORKFLOW_ACTIVE_LOG")
        if [[ "$current_lines" -ge "$ITERATIONS" ]]; then
            echo "✔ Metrics reached $ITERATIONS iterations for $wf_name."
            break
        fi

        iter_num=$((current_lines + 1))
        echo "Iteration ${iter_num}/$ITERATIONS [Tag: $benchmark_tag, Workflow: $wf_name] (Global Count: $((GLOBAL_ITERATION_COUNT + 1)))..."
        export WORKFLOW_LOG="$WORKFLOW_ACTIVE_LOG"
        
        if ./automate_creation.sh --skip-helm -h -w "$workflow_file"; then
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

    echo "Finished all iterations for $wf_name under tag '$benchmark_tag'."
    echo ""
}

echo "🚀 Starting Full Benchmark Execution Suite..."

# ==============================================================================
# LOOP 1: Inactive Rules
# ==============================================================================
echo "------------------------------------------------------------------"
echo "Suite 1: Inactive Rules"
echo "------------------------------------------------------------------"

run_benchmark_suite "inactive" \
    "/home/lemon/Documents/UA/tese/autoAdmissionController/vulnerability_examples/zipSlip/exploit/zipSlip_s3.yaml" \
    "./created_rules/zipslip-rules.yaml" \
    "./created_rules/zipslip-prometheus-rules.yaml"

run_benchmark_suite "inactive" \
    "/home/lemon/Documents/UA/tese/autoAdmissionController/tests/test_argo_yamls/inputs_tests/artifacts.yaml" \
    "./created_rules/artifact-passing-rules.yaml" \
    "./created_rules/artifact-passing-prometheus-rules.yaml"

run_benchmark_suite "inactive" \
    "/home/lemon/Documents/UA/tese/autoAdmissionController/vulnerability_examples/podSpecPatch/test_workflow/resource_limited_workflow.yaml" \
    "./created_rules/resource-limited-demo-rules.yaml" \
    "./created_rules/resource-limited-demo-prometheus-rules.yaml"


# ==============================================================================
# LOOP 2: Active Benign Rules
# ==============================================================================
echo "------------------------------------------------------------------"
echo "Suite 2: Active Benign Rules"
echo "------------------------------------------------------------------"

run_benchmark_suite "active-benign" \
    "/home/lemon/Documents/UA/tese/autoAdmissionController/vulnerability_examples/zipSlip/exploit/zipSlip_s3_benign.yaml" \
    "./created_rules/zipslip-rules.yaml" \
    "./created_rules/zipslip-prometheus-rules.yaml"

run_benchmark_suite "active-benign" \
    "/home/lemon/Documents/UA/tese/autoAdmissionController/tests/test_argo_yamls/inputs_tests/artifacts.yaml" \
    "./created_rules/artifact-passing-rules.yaml" \
    "./created_rules/artifact-passing-prometheus-rules.yaml"

run_benchmark_suite "active-benign" \
    "/home/lemon/Documents/UA/tese/autoAdmissionController/vulnerability_examples/podSpecPatch/test_workflow/resource_limited_workflow.yaml" \
    "./created_rules/resource-limited-demo-rules.yaml" \
    "./created_rules/resource-limited-demo-prometheus-rules.yaml"


# ==============================================================================
# LOOP 3: Active Anomalous Rules
# ==============================================================================
echo "------------------------------------------------------------------"
echo "Suite 3: Active Anomalous Rules"
echo "------------------------------------------------------------------"

run_benchmark_suite "active-anomalous" \
    "/home/lemon/Documents/UA/tese/autoAdmissionController/vulnerability_examples/zipSlip/exploit/zipSlip_s3.yaml" \
    "./created_rules/zipslip-rules.yaml" \
    "./created_rules/zipslip-prometheus-rules.yaml"

run_benchmark_suite "active-anomalous" \
    "/home/lemon/Documents/UA/tese/autoAdmissionController/tests/test_argo_yamls/inputs_tests/artifacts.yaml" \
    "./created_rules/artifact-passing-fake-rules.yaml" \
    "./created_rules/artifact-passing-fake-prometheus-rules.yaml"

run_benchmark_suite "active-anomalous" \
    "/home/lemon/Documents/UA/tese/autoAdmissionController/vulnerability_examples/podSpecPatch/test_workflow/resource_limited_workflow.yaml" \
    "./created_rules/resource-limited-demo-rules.yaml" \
    "./created_rules/resource-limited-fake-demo-prometheus-rules.yaml"

echo "=================================================================="
echo "✔ All Benchmark Suites Completed Successfully!"
echo " Total Global Iterations Executed: $GLOBAL_ITERATION_COUNT"
echo " Results stored under: $BASE_OUT_DIR/"
echo "=================================================================="
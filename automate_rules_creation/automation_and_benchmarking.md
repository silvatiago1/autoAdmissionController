Metrics code and documentation were done with the help of Gemini

Before capturing metrics, ensure that the metrics server is running, you may use:
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml


# Falco Rule Generator & Automated Deployment Pipeline

This repository provides an automated workflow to translate input workflow specifications (such as Argo YAMLs) into customized Falco security rules, deploy them to a Kubernetes cluster via Helm, execute Argo workflows, and run statistical performance benchmarks on the pipeline and resource utilization over time.

---

## Component Overview

* automate_creation.sh: The core execution script. Handles rule generation, rule deactivation, Helm rollouts, time-series memory collection, and Argo job execution.
* time_automate_creation.sh: A lightweight wrapper around automate_creation.sh that enables time measurement mode (BENCHMARK_MODE=1).
* benchmark.sh: The benchmark test runner. Runs the generation/deployment pipeline across multiple iterations (default: 11), logs output metrics, and calculates comprehensive statistical summaries.

---

## Requirements & Prerequisites

* CLI Utilities: bash (v4+), awk, find, xargs, helm, kubectl, argo
* Python Environment: python3 with main.py rule generator located in the project root.
* Kubernetes Environment: A working cluster with the falco namespace and Falco Helm deployment, plus the argo workflow engine.

---

## Generated Output Log Files

When executed with BENCHMARK_MODE=1, metrics are automatically saved to the following files:

* benchmark_pipeline_times.txt: Text file (ms) recording time taken to generate rules, apply Helm upgrades, and wait for DaemonSet rollout completion.
* benchmark_workflow_times.txt: Text file (ms) recording execution runtime of the Argo workflow steps (captured when running with --wait).
* benchmark_total_times.txt: Text file (ms) recording combined total duration (Pipeline + Workflow).
* benchmark_workflow_memory_timeseries.csv: CSV file recording time-series pod RAM usage sampled every 2 seconds during active workflow runs.

---

## Command-line Usage & Options

### 1. Core Script: automate_creation.sh

Runs the primary rule generation, deployment, and monitoring process once.

Usage:
./automate_creation.sh [OPTIONS] <input_file>

Available Options:
* --skip-apply (-s): Skip Deployment. Runs only the Python rule generator (main.py) and skips Helm upgrade, kubectl checks, and Argo job submissions.
* --headless (-h): Headless Mode. Suppresses opening new gnome-terminal GUI windows. Submits the Argo workflow quietly in the background instead.
* --wait (-w): Synchronous Execution. Blocks and waits for the submitted Argo workflow to finish executing before completing the script run. Required for capturing workflow runtime and time-series RAM metrics.
* --deactivate-rules (-d): Baseline Control Mode. Deploys disable_rules.yaml instead of the generated rule set to establish a baseline performance benchmark and measure Falco rule overhead on workflow execution.

Environment Variables:
* BENCHMARK_MODE=1: When set, enables metric calculations and outputs timing and RAM log files.

Examples:
* Full deployment with interactive GUI windows:
  ./automate_creation.sh path/to/input.yaml

* Generate rules only without cluster deployment:
  ./automate_creation.sh --skip-apply path/to/input.yaml

* Run full deployment in headless mode:
  ./automate_creation.sh --headless path/to/input.yaml

* Run in headless mode and wait for workflow completion:
  ./automate_creation.sh --headless --wait path/to/input.yaml

* Run baseline control test (disabled rules) in headless wait mode:
  ./automate_creation.sh --headless --wait --deactivate-rules path/to/input.yaml


### 2. Wrapper Script: time_automate_creation.sh

A convenient wrapper that passes arguments directly to automate_creation.sh while automatically setting BENCHMARK_MODE=1.

Usage:
./time_automate_creation.sh [OPTIONS] <input_file>

Examples:
./time_automate_creation.sh --skip-apply path/to/input.yaml
./time_automate_creation.sh --headless --wait --deactivate-rules path/to/input.yaml


### 3. Benchmark Runner: benchmark.sh

Automates repeated test executions to profile pipeline latency and calculate statistical distribution.

Usage:
bash benchmark.sh [OPTIONS] <input_file>

Options Forwarded to Core Pipeline:
* --skip-apply (-s): Measures performance of the Python Rule Generator ONLY.
* --headless (-h): Suppresses gnome-terminal window creation during benchmarking runs. Recommended for benchmarking full deployments.
* --wait (-w): Forces each benchmark iteration to wait for the Argo workflow to complete before starting the next iteration.
* --deactivate-rules (-d): Forwards baseline testing mode to execute benchmark runs against an empty/disabled Falco ruleset.

Benchmark Output Metrics:
All execution times are saved to benchmark_total_times.txt, benchmark_pipeline_times.txt, and benchmark_workflow_times.txt. After completion, the script prints an AWK-generated report including:
* Overall Iterations: Mean, Median, Maximum, and Standard Deviation (reported in ms and s).
* Quarterly Breakdown: Chronological breakdown divided into 4 quarters to help identify cold-starts, caching effects, or performance degradation over repeated runs.

Examples:
* Benchmark full deployment end-to-end with generated rules:
  bash benchmark.sh --headless --wait path/to/input.yaml

* Benchmark baseline workflow execution WITHOUT active rules (overhead test):
  bash benchmark.sh --headless --wait --deactivate-rules path/to/input.yaml

* Benchmark isolated Python rule generation performance:
  bash benchmark.sh --skip-apply path/to/input.yaml


## Workflow Execution Steps

When running a full deployment (automate_creation.sh without --skip-apply), the script executes the following sequence:

1. Rule Deactivation Phase: Executes helm upgrade -f disable_rules.yaml to clear previously active rules, ensuring clean and equal deployment measurements across consecutive runs.
2. Pipeline Timer Initialization: Starts the setup benchmark clock (when BENCHMARK_MODE=1).
3. Rule Generation: Executes python3 main.py <input_file>.
4. File Discovery: Scans ./created_rules/ for the newest YAML rules file.
5. Helm Upgrade: Upgrades the Falco release using either the generated rules or disable_rules.yaml (if -d is set).
6. Rollout Verification: Polls kubectl rollout status daemonset/falco -n falco until pods complete restart. Stops Pipeline Timer.
7. Workflow & Memory Monitoring Phase:
   * Standard Mode: Submits the workflow and opens gnome-terminal windows to monitor Falco logs and watch the Argo workflow.
   * Headless Mode (-h): Submits the Argo workflow in the background.
   * Wait Mode (-w): Launches background memory collector polling kubectl top pods every 2 seconds to write benchmark_workflow_memory_timeseries.csv, blocks until the Argo workflow finishes, stops collector, and records Workflow Elapsed time.


## Output Metrics & Data Formats

Standard Console Output Format:
Pipeline Elapsed: 4520
Workflow Elapsed: 18230
Elapsed: 22750

Memory Time-Series CSV Format (benchmark_workflow_memory_timeseries.csv):
timestamp_epoch_ms,pod_name,memory_bytes,memory_mib
1700000001200,artifact-passing-abcde-12345678,134217728,128
1700000003210,artifact-passing-abcde-12345678,157286400,150
1700000005220,artifact-passing-abcde-12345678,188743680,180

Analyzing Time-Series RAM Metrics:
To quickly calculate minimum, average, and peak RAM consumption from the CSV output:

awk -F',' 'NR>1 {
    sum+=$4; count++; 
    if(min=="" || $4<min) min=$4; 
    if($4>max) max=$4
} 
END {
    print "Min RAM:", min " MiB"; 
    print "Avg RAM:", (count ? sum/count : 0) " MiB"; 
    print "Max RAM:", max " MiB"
}' benchmark_workflow_memory_timeseries.csv
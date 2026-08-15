#!/usr/bin/env bash
set -euo pipefail

start_time=$(date +%s%N)

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <input_file>"
    exit 1
fi

INPUT_FILE="$1"

echo "Running generator..."
python3 main.py "$INPUT_FILE"

# Find the newest generated rules file.
GENERATED_FILE=$(find ./created_rules -maxdepth 1 -type f -name "*.yaml" -print0 \
    | xargs -0 ls -t \
    | head -n1)

if [[ ! -f "$GENERATED_FILE" ]]; then
    echo "Error: Could not find generated YAML file."
    exit 1
fi

echo "Using generated file: $GENERATED_FILE"

echo "Applying Helm upgrade..."
helm upgrade --namespace falco falco falcosecurity/falco \
    --set tty=true \
    --set falcoctl.artifact.install.enabled=false \
    --set falcoctl.artifact.follow.enabled=false \
    -f "$GENERATED_FILE"

echo "Waiting for Falco DaemonSet rollout to complete..."
until kubectl rollout status daemonset/falco -n falco --timeout=60s; do
    echo "Timed out waiting for rollout. Retrying in 5 seconds..."
    sleep 5
done

# Give the API server a brief moment to clean up references to dead pods
sleep 2
# Set benchmark_mode=1 to not open the GUI windows
if [[ "${BENCHMARK_MODE:-0}" != "1" ]]; then
    echo "Opening Falco logs window..."
    gnome-terminal --title="Falco Logs" -- bash -lc \
        'kubectl logs -f --tail=50 -l app.kubernetes.io/name=falco -n falco -c falco; exec bash' &
fi

echo "Submitting Argo workflow..."

WORKFLOW_NAME=$(argo submit -n argo "$INPUT_FILE" -o name | sed 's#workflows.argoproj.io/##')

if [[ "${BENCHMARK_MODE:-0}" != "1" ]]; then
    echo "Opening Argo workflow window..."
    gnome-terminal --title="Argo" -- bash -lc \
        "argo watch -n argo \"$WORKFLOW_NAME\"; exec bash" &
fi

echo "Submitted workflow: $WORKFLOW_NAME"

echo "Submitted workflow: $WORKFLOW_NAME"


end_time=$(date +%s%N)
elapsed=$((end_time - start_time))

echo "Terminating Argo workflow: $WORKFLOW_NAME"
argo terminate -n argo "$WORKFLOW_NAME"

printf "Elapsed: %.3f ms\n" \
    "$(awk "BEGIN { print ($end_time - $start_time) / 1000000 }")"
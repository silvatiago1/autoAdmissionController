#!/bin/bash

# Configuration
NS="${1:-argo}" # Set default to 'argo'

# Get the latest Workflow name
WF=$(kubectl get wf -n "$NS" --sort-by=.metadata.creationTimestamp --no-headers | awk 'END{print $1}')

if [ -z "$WF" ]; then
    echo "Error: No workflows found in namespace: $NS"
    exit 1
fi

# Get the latest Pod associated with that Workflow
POD=$(kubectl get pod -n "$NS" -l workflows.argoproj.io/workflow="$WF" --no-headers | awk 'END{print $1}')

if [ -z "$POD" ]; then
    echo "Error: No pods found for workflow: $WF"
    exit 1
fi

echo "------------------------------------------"
echo "Namespace: $NS"
echo "Workflow:  $WF"
echo "Pod:       $POD"
echo "------------------------------------------"

# Attempt to exec with bash, fallback to sh if bash is missing
echo "Attempting to connect..."
kubectl exec -it -n "$NS" "$POD" -c main -- /bin/bash || \
kubectl exec -it -n "$NS" "$POD" -c main -- /bin/sh
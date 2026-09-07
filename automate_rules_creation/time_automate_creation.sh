#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [--skip-apply|-s] <input_file>"
    exit 1
fi

# Delegate directly to automate_creation.sh with BENCHMARK_MODE enabled
BENCHMARK_MODE=1 ./automate_creation.sh "$@"
#!/usr/bin/env bash

set -u

SCRIPT="./time_automate_creation.sh"
ITERATIONS=4
FORWARD_FLAGS=""
INPUT_FILE=""

# Parse flags and collect extra flags to pass forward
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-apply|-s)
            FORWARD_FLAGS="$FORWARD_FLAGS --skip-apply"
            shift
            ;;
        --headless|-h)
            FORWARD_FLAGS="$FORWARD_FLAGS --headless"
            shift
            ;;
        --wait|-w)
            FORWARD_FLAGS="$FORWARD_FLAGS --wait"
            shift
            ;;
        *)
            INPUT_FILE="$1"
            shift
            ;;
    esac
done

if [[ -z "$INPUT_FILE" ]]; then
    echo "Usage: $0 [--skip-apply|-s] [--headless|-h] [--wait|-w] <input_file>"
    exit 1
fi

benchmark_results_file="./benchmark_results.txt"

rm -f "$benchmark_results_file"
touch "$benchmark_results_file"

echo "Running $ITERATIONS iterations..."
echo

for ((i=1; i<=ITERATIONS; i++)); do
    echo "Iteration $i/$ITERATIONS"

    output=$(bash "$SCRIPT" $FORWARD_FLAGS "$INPUT_FILE" 2>&1)
    status=$?

    echo "$output"

    elapsed=$(echo "$output" | awk '/^Elapsed:/ {print $2}')

    if [[ -z "$elapsed" ]]; then
        echo "ERROR: Could not extract elapsed time."
        echo "Exit status: $status"
        exit 1
    fi

    echo "$elapsed" >> "$benchmark_results_file"

    echo "Time: ${elapsed} ms"
    echo
done

awk '
{
    values[NR] = $1
}
END {
    n = NR

    if (n == 0) {
        print "No benchmark results found."
        exit
    }

    print ""
    print "========================================"
    print "BENCHMARK RESULTS"
    print "========================================"

    for (i = 1; i <= n; i++) {
        sorted[i] = values[i]
    }

    for (i = 1; i <= n; i++) {
        for (j = i + 1; j <= n; j++) {
            if (sorted[i] > sorted[j]) {
                tmp = sorted[i]
                sorted[i] = sorted[j]
                sorted[j] = tmp
            }
        }
    }

    sum = 0
    max = values[1]

    for (i = 1; i <= n; i++) {
        sum += values[i]

        if (values[i] > max)
            max = values[i]
    }

    mean = sum / n
    variance = 0

    for (i = 1; i <= n; i++)
        variance += (values[i] - mean)^2

    stddev = sqrt(variance / n)

    if (n % 2 == 1)
        median = sorted[(n + 1) / 2]
    else
        median = (sorted[n / 2] + sorted[n / 2 + 1]) / 2

    print ""
    print "ALL ITERATIONS"
    print "----------------------------------------"
    printf "Iterations:    1-%d (%d)\n", n, n
    printf "Average:       %.3f ms\n", mean
    printf "Median:        %.3f ms\n", median
    printf "Maximum:       %.3f ms\n", max
    printf "Std deviation: %.3f ms\n", stddev
    printf "Average:       %.3f s\n", mean / 1000
    printf "Median:        %.3f s\n", median / 1000
    printf "Maximum:       %.3f s\n", max / 1000
    printf "Std deviation: %.3f s\n", stddev / 1000

    quarter_size = int(n / 4)

    if (quarter_size < 1) {
        print ""
        print "Not enough iterations for quarter statistics."
        print "Run at least 4 iterations."
        exit
    }

    for (q = 1; q <= 4; q++) {
        start = (q - 1) * quarter_size + 1

        if (q == 4)
            end = n
        else
            end = q * quarter_size

        count = end - start + 1

        sum = 0
        max = values[start]

        for (i = start; i <= end; i++) {
            sum += values[i]

            if (values[i] > max)
                max = values[i]
        }

        mean = sum / count
        variance = 0

        for (i = start; i <= end; i++)
            variance += (values[i] - mean)^2

        stddev = sqrt(variance / count)

        for (i = 1; i <= count; i++)
            quarter[i] = values[start + i - 1]

        for (i = 1; i <= count; i++) {
            for (j = i + 1; j <= count; j++) {
                if (quarter[i] > quarter[j]) {
                    tmp = quarter[i]
                    quarter[i] = quarter[j]
                    quarter[j] = tmp
                }
            }
        }

        if (count % 2 == 1)
            median = quarter[(count + 1) / 2]
        else
            median = (quarter[count / 2] + quarter[count / 2 + 1]) / 2

        print ""
        printf "QUARTER %d\n", q
        print "----------------------------------------"
        printf "Iterations:    %d-%d (%d)\n", start, end, count
        printf "Average:       %.3f ms\n", mean
        printf "Median:        %.3f ms\n", median
        printf "Maximum:       %.3f ms\n", max
        printf "Std deviation: %.3f ms\n", stddev
        printf "Average:       %.3f s\n", mean / 1000
        printf "Median:        %.3f s\n", median / 1000
        printf "Maximum:       %.3f s\n", max / 1000
        printf "Std deviation: %.3f s\n", stddev / 1000
    }

    print ""
    print "========================================"
}
' "$benchmark_results_file"
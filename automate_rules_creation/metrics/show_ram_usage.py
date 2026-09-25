import csv
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.dates as mdates


# Input/output files
input_file = Path("./raw_data_vm_updated/zipSlip_s3_anomalous/falco_zipSlip_s3_anomalous.csv")
output_file = Path("./new_graphs/zipslip/falco_memory_timeseries_anomalous.png")


# Total RAM per timestamp
memory_by_timestamp = defaultdict(float)


with open(input_file, "r", newline="", encoding="utf-8") as csvfile:
    reader = csv.DictReader(csvfile)

    for row in reader:
        timestamp_ms = int(row["timestamp_epoch_ms"])
        memory_mib = float(row["memory_mib"])

        # Add memory from this pod to the total for this timestamp
        memory_by_timestamp[timestamp_ms] += memory_mib


# Sort timestamps
timestamps_ms = sorted(memory_by_timestamp.keys())

# Convert epoch milliseconds to datetime
timestamps = [
    datetime.fromtimestamp(timestamp_ms / 1000)
    for timestamp_ms in timestamps_ms
]

# Total memory at each timestamp
memory_usage = [
    memory_by_timestamp[timestamp_ms]
    for timestamp_ms in timestamps_ms
]


# Create plot
fig, ax = plt.subplots(figsize=(14, 7))

ax.plot(
    timestamps,
    memory_usage,
    linewidth=1
)

ax.set_xlabel("Time")
ax.set_ylabel("Total RAM Usage (MiB)")
ax.set_title("Total RAM Usage Over Time")

ax.grid(True, alpha=0.3)


# Limit number of time labels
locator = mdates.AutoDateLocator(
    minticks=5,
    maxticks=10
)

formatter = mdates.AutoDateFormatter(locator)

ax.xaxis.set_major_locator(locator)
ax.xaxis.set_major_formatter(formatter)

plt.xticks(rotation=45)

plt.tight_layout()

# Save PNG
plt.savefig(
    output_file,
    dpi=300,
    bbox_inches="tight"
)

plt.close()

print(f"Plot saved to: {output_file}")
import matplotlib.pyplot as plt
import numpy as np

TRESHOLD = 10270

# Read the numbers from the text file
data1 = np.loadtxt(
    "./raw_data_vm_updated_v1/zipSlip_s3_benign/zipSlip_s3_active_rules_times_ms.txt"
)

data2 = np.loadtxt(
    "./raw_data_vm_updated_v1/zipSlip_s3_anomalous/zipSlip_s3_workflow_active_rules_times_ms.txt"
)

# Count outliers (> TRESHOLD)
outliers1 = np.sum(data1 > TRESHOLD)
outliers2 = np.sum(data2 > TRESHOLD)

print(f"Benign Workflow: {outliers1} outliers discarded")
print(f"Anomalous Workflow: {outliers2} outliers discarded")

# Discard values greater than TRESHOLD ms
data1 = data1[data1 <= TRESHOLD]
data2 = data2[data2 <= TRESHOLD]

# Create the boxplot with outlier counts in labels
labels = [
    f"Benign Workflows\n({outliers1} outliers discarded)",
    f"Anomalous Workflows\n({outliers2} outliers discarded)",
]

plt.boxplot([data1, data2], labels=labels)

# Place the threshold text in the top-right corner using relative axes coordinates
plt.text(
    0.95,
    0.95,
    f"Threshold: {TRESHOLD} ms",
    transform=plt.gca().transAxes,
    ha="right",
    va="top",
    fontsize=10,
    bbox=dict(boxstyle="round,pad=0.4", facecolor="white", edgecolor="gray", alpha=0.8),
)

plt.ylabel("Time for the Workflow to Run (ms)")
plt.title("")

plt.savefig(
    "anom_benign_zipslip_workflow_run_boxplot.png", dpi=300, bbox_inches="tight"
)
plt.show()
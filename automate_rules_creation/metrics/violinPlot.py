import numpy as np
import matplotlib.pyplot as plt

TRESHOLD =15000

# Read the numbers from the text files
data1 = np.loadtxt("./raw_data_vm_updated/zipSlip_s3_anomalous/zipSlip_s3_workflow_inactive_rules_times_ms.txt")
data2 = np.loadtxt("./raw_data_vm_updated/zipSlip_s3_anomalous/zipSlip_s3_workflow_active_rules_times_ms.txt")

# Count outliers (> TRESHOLD)
outliers1 = np.sum(data1 > TRESHOLD)
outliers2 = np.sum(data2 > TRESHOLD)

print(f"Monitoring Rules not Applied: {outliers1} outliers discarded")
print(f"Monitoring Rules Applied: {outliers2} outliers discarded")

# Discard values greater than TRESHOLD ms
data1 = data1[data1 <= TRESHOLD]
data2 = data2[data2 <= TRESHOLD]


# Create the violin plot
plt.violinplot(
    [data1, data2],
    showmeans=True,
    showmedians=True,
    showextrema=True
)

# Set labels
plt.xticks(
    [1, 2],
    ["Monitoring Rules not Applied", "Monitoring Rules Applied"]
)

plt.ylabel("Time for the Pipeline to Run (ms)")
plt.title("Violin Plot of Pipeline Run Times")

plt.savefig(
    "zipslip_workflow_run_violinplot.png",
    dpi=300,
    bbox_inches="tight"
)

plt.show()
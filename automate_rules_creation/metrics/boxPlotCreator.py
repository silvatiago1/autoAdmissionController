import numpy as np
import matplotlib.pyplot as plt

TRESHOLD= 10300

# Read the numbers from the text file
data1 = np.loadtxt(
    "./raw_data_vm_updated/zipSlip_s3_benign/zipSlip_s3_active_rules_times_ms.txt"
)

data2 = np.loadtxt(
    "./raw_data_vm_updated/zipSlip_s3_anomalous/zipSlip_s3_workflow_active_rules_times_ms.txt"
)

# Count outliers (> TRESHOLD)
outliers1 = np.sum(data1 > TRESHOLD)
outliers2 = np.sum(data2 > TRESHOLD)

print(f"Benign Workflow: {outliers1} outliers discarded")
print(f"Anomalous Workflow: {outliers2} outliers discarded")

# Discard values greater than TRESHOLD ms
data1 = data1[data1 <= TRESHOLD]
data2 = data2[data2 <= TRESHOLD]

# Create the boxplot
plt.boxplot(
    [data1, data2],
    labels=["Benign Workflow", "Anomalous Workflow"]
)

plt.ylabel("Time for the Pipeline to Run (ms)")
plt.title("Boxplot of Data")

plt.savefig("anom_benign_zipslip_workflow_run_boxplot.png", dpi=300, bbox_inches="tight")
plt.show()
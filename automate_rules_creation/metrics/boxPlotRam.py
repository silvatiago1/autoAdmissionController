import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# Define threshold for RAM usage (adjust this value as needed)
TRESHOLD = 600000000

# Define file paths
file1_path = "/home/lemon/Documents/UA/tese/autoAdmissionController/automate_rules_creation/benchmark_results_vm/active-benign/artifacts_combined/artifacts_ram_prom.csv"
file2_path = "/home/lemon/Documents/UA/tese/autoAdmissionController/automate_rules_creation/benchmark_results_vm/inactive/artifacts_combined/artifacts_ram_prom.csv"
output_image_path = "prom_ram_active_inactive_artifacts.png"

# Read CSV files into DataFrames (header=None since raw rows have no headers)
df1 = pd.read_csv(file1_path, header=None)
df2 = pd.read_csv(file2_path, header=None)

# Extract RAM usage values from the 3rd column (index 2) and force numeric type
data1 = pd.to_numeric(df1.iloc[:, 2], errors='coerce').values
data2 = pd.to_numeric(df2.iloc[:, 2], errors='coerce').values

# Drop any NaN values that might have resulted from conversion errors
data1 = data1[~np.isnan(data1)]
data2 = data2[~np.isnan(data2)]

# Count outliers (> TRESHOLD)
outliers1 = np.sum(data1 > TRESHOLD)
outliers2 = np.sum(data2 > TRESHOLD)

print(f"Active Rules: {outliers1} outliers discarded")
print(f"Inactive Rules: {outliers2} outliers discarded")

# Discard values greater than TRESHOLD
data1 = data1[data1 <= TRESHOLD]
data2 = data2[data2 <= TRESHOLD]

# Create the boxplot with outlier counts in labels
labels = [
    f"Active Rules\n({outliers1} outliers discarded)",
    f"Inactive Rules\n({outliers2} outliers discarded)",
]

plt.figure(figsize=(8, 6))
plt.boxplot([data1, data2], tick_labels=labels)

# Place the threshold text in the top-right corner using relative axes coordinates
plt.text(
    0.95,
    0.95,
    f"Threshold: {TRESHOLD}",
    transform=plt.gca().transAxes,
    ha="right",
    va="top",
    fontsize=10,
    bbox=dict(boxstyle="round,pad=0.4", facecolor="white", edgecolor="gray", alpha=0.8),
)

plt.ylabel("RAM Usage")
plt.title("")

# Save figure to file
plt.savefig(output_image_path, dpi=300, bbox_inches="tight")
plt.show()

print(f"Chart saved to {output_image_path}")
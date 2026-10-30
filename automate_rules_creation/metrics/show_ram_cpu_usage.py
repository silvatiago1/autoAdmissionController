import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# Define file paths
file1_path = "/home/lemon/Documents/UA/tese/autoAdmissionController/automate_rules_creation/benchmark_results_vm_325/active-anomalous/zipSlip_s3_combined/zipslip_ram_prom.csv"
file2_path = "/home/lemon/Documents/UA/tese/autoAdmissionController/automate_rules_creation/benchmark_results_vm_325/active-benign/zipSlip_s3_benign_combined/zipslip_ram_prom.csv"
output_image_path = "./prom_rssRam_anom_benign_zipslip.png"

# Read CSV files into DataFrames (header=None since raw rows have no headers)
df1 = pd.read_csv(file1_path, header=None)
df2 = pd.read_csv(file2_path, header=None)

# Extract values from the 4th column (index 3) and force numeric type
col_idx = 3

y1 = pd.to_numeric(df1.iloc[:, col_idx], errors='coerce').values
y2 = pd.to_numeric(df2.iloc[:, col_idx], errors='coerce').values

# Drop any NaN values that might have resulted from conversion errors
y1 = y1[~np.isnan(y1)]
y2 = y2[~np.isnan(y2)]

# Convert KB to GB
y1 = y1 / (1024 * 1024)
y2 = y2 / (1024 * 1024)

# Map row indices to a normalized 0% -> 100% range for each dataset
x1 = np.linspace(0, 100, len(y1))
x2 = np.linspace(0, 100, len(y2))

# Create plot
plt.figure(figsize=(10, 5))

plt.plot(x1, y1, label="Anomalous Workflow", color="tab:blue")
plt.plot(x2, y2, label="Benign Workflow", color="orange")

plt.xlabel("Sample Sequence Progress (%)")

#plt.ylabel("CPU Usage (%)")
#plt.title("Cpu Usage Comparison")
plt.ylabel("RAM RSS (GB)")
plt.title("RAM RSS Comparison")

#RAM
#plt.ylim(1500000, 3000000)
#CPU
#plt.ylim(0, 5)

plt.legend()
plt.grid(True)

# Save figure to file
plt.savefig(output_image_path, dpi=300, bbox_inches="tight")
plt.close()

print(f"Chart saved to {output_image_path}")
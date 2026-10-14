import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

# Define file paths
file1_path = "./raw_data_vm_updated_v1/artifacts_anomalous/prometheus_artifacts_ram_usage_timeseries_anomalous.csv"
file2_path = "./raw_data_vm_updated_v2/artifacts_benign/prometheus_artifacts_active_ram_usage_timeseries_anomalous.csv"
output_image_path = "./ram_usage_comparison.png"

# Read CSV files into DataFrames
df1 = pd.read_csv(file1_path)
df2 = pd.read_csv(file2_path)

# Extract RAM usage values (using 3rd column or 'ram_usage')
y1 = df1.iloc[:, 2] if "ram_usage" not in df1.columns else df1["ram_usage"]
y2 = df2.iloc[:, 2] if "ram_usage" not in df2.columns else df2["ram_usage"]

# Map row indices to a normalized 0% -> 100% range for each dataset
x1 = np.linspace(0, 100, len(y1))
x2 = np.linspace(0, 100, len(y2))

# Create plot
plt.figure(figsize=(10, 5))

# File 1 (Prometheus - Blue)
plt.plot(x1, y1, label="Anomalous Workflow", color="tab:blue")

# File 2 (Alertmanager - Orange)
plt.plot(x2, y2, label="Benign Workflow", color="orange")

plt.xlabel("Sample Sequence Progress (%)")
plt.ylabel("RAM Usage")
plt.title("RAM Usage Comparison")
plt.legend()
plt.grid(True)

# Save figure to file
plt.savefig(output_image_path, dpi=300, bbox_inches="tight")
plt.close()

print(f"Chart saved to {output_image_path}")
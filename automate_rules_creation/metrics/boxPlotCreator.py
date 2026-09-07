import numpy as np
import matplotlib.pyplot as plt

# Read the numbers from the text file
data1 = np.loadtxt("benchmark_workflow_times_no_monitor.txt")
data2 = np.loadtxt("benchmark_workflow_times_zipslip_monitor.txt")

# Create the boxplot
plt.boxplot([data1, data2], labels=["Monitoring Rules not Applied", "Monitoring Rules Applied"])

plt.ylabel("Time for the Pipeline to Run (ms)")
plt.title("Boxplot of Data")
plt.savefig("zipslip_workflow_run_boxplot.png", dpi=300, bbox_inches="tight")
plt.show()
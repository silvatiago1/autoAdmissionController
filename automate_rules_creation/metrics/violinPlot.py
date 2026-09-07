import numpy as np
import matplotlib.pyplot as plt

# Read the numbers from the text files
data1 = np.loadtxt("benchmark_workflow_times_no_monitor.txt")
data2 = np.loadtxt("benchmark_workflow_times_zipslip_monitor.txt")

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
import matplotlib.pyplot as plt

# Read values from the two files
with open("ms_to_create_rules_artifact_passing.txt") as f:
    values1 = [float(line.strip()) for line in f if line.strip()]

with open("benchmark_pipeline_times.txt") as f:
    values2 = [float(line.strip()) for line in f if line.strip()]

# Create the graph
plt.figure(figsize=(12, 6))

plt.plot(values1, label="Time to Create Artifacts")
plt.plot(values2, label="Time for Rules to be Applied")

plt.xlabel("Data point")
plt.ylabel("Value")
plt.title("Value Movement")
plt.legend()
plt.grid(True, alpha=0.3)

plt.savefig("create_rules_vs_untill_rules_applied.png", dpi=300, bbox_inches="tight")
plt.show()
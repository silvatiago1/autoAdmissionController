import matplotlib.pyplot as plt

# Read values from the two files
with open("./old_raw_data_pc/ms_zipslip_creation.txt") as f:
    values1 = [float(line.strip()) for line in f if line.strip()]

with open("./old_raw_data_pc/resource_limited_workflow_rule_apply_active_times_ms.txt") as f:
    values2 = [float(line.strip()) for line in f if line.strip()]

with open("./old_raw_data_pc/resource_limited_workflow_workflow_active_rules_times_ms.txt") as f:
    values3 = [float(line.strip()) for line in f if line.strip()]
# Create the graph
plt.figure(figsize=(12, 6))

plt.plot(values1, label="Time to Create Artifacts")
plt.plot(values2, label="Time for Rules to be Applied")
plt.plot(values3, label="Time for Workflow to Run")

plt.xlabel("Run")
plt.ylabel("Time(ms)")
plt.title("")
plt.legend()
plt.grid(True, alpha=0.3)

plt.savefig("create_rules_vs_untill_rules_applied.png", dpi=300, bbox_inches="tight")
plt.show()
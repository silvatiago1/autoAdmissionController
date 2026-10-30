import csv

input_file = "/home/lemon/Documents/UA/tese/autoAdmissionController/automate_rules_creation/benchmark_results_vm_325/active-anomalous/resource_limited_workflow_combined/resource_limited_workflow_cpu_usage_timeseries.csv"
falco_file = "/home/lemon/Documents/UA/tese/autoAdmissionController/automate_rules_creation/benchmark_results_vm_325/active-anomalous/resource_limited_workflow_combined/resource_cpu_falco.csv"
prometheus_file = "/home/lemon/Documents/UA/tese/autoAdmissionController/automate_rules_creation/benchmark_results_vm_325/active-anomalous/resource_limited_workflow_combined/resource_cpu_prom.csv"

with open(input_file, "r", newline="", encoding="utf-8") as infile:
    reader = csv.reader(infile)
    header = next(reader)

    with open(falco_file, "w", newline="", encoding="utf-8") as falco_out, \
         open(prometheus_file, "w", newline="", encoding="utf-8") as prometheus_out:
        falco_writer = csv.writer(falco_out)
        prometheus_writer = csv.writer(prometheus_out)

        # Write the header to all output files
        falco_writer.writerow(header)
        prometheus_writer.writerow(header)

        for row in reader:
            row_text = ",".join(row).lower()

            if "falco" in row_text:
                falco_writer.writerow(row)
            elif "prometheus" in row_text:
                prometheus_writer.writerow(row)

print(f"Created {falco_file}, {prometheus_file}")
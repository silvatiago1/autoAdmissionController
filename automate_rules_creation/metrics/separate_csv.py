import csv

input_file = "/home/lemon/Documents/UA/tese/autoAdmissionController/automate_rules_creation/benchmark_results_vm/inactive/artifacts_combined/artifacts_ram_usage_timeseries.csv"
falco_file = "/home/lemon/Documents/UA/tese/autoAdmissionController/automate_rules_creation/benchmark_results_vm/inactive/artifacts_combined/artifacts_ram_falco.csv"
prometheus_file = "/home/lemon/Documents/UA/tese/autoAdmissionController/automate_rules_creation/benchmark_results_vm/inactive/artifacts_combined/artifacts_ram_prom.csv"
alertmanager_file = "/home/lemon/Documents/UA/tese/autoAdmissionController/automate_rules_creation/benchmark_results_vm/inactive/artifacts_combined/artifacts_ram_alert.csv"

with open(input_file, "r", newline="", encoding="utf-8") as infile:
    reader = csv.reader(infile)
    header = next(reader)

    with open(falco_file, "w", newline="", encoding="utf-8") as falco_out, \
         open(prometheus_file, "w", newline="", encoding="utf-8") as prometheus_out, \
         open(alertmanager_file, "w", newline="", encoding="utf-8") as alertmanager_out:

        falco_writer = csv.writer(falco_out)
        prometheus_writer = csv.writer(prometheus_out)
        alertmanager_writer = csv.writer(alertmanager_out)

        # Write the header to all output files
        falco_writer.writerow(header)
        prometheus_writer.writerow(header)
        alertmanager_writer.writerow(header)

        for row in reader:
            row_text = ",".join(row).lower()

            if "falco" in row_text:
                falco_writer.writerow(row)
            # Check alertmanager FIRST because string "alertmanager-monitoring-kube-prometheus-..." 
            # also contains "prometheus"
            elif "alertmanager" in row_text:
                alertmanager_writer.writerow(row)
            elif "prometheus" in row_text:
                prometheus_writer.writerow(row)

print(f"Created {falco_file}, {prometheus_file}, and {alertmanager_file}")
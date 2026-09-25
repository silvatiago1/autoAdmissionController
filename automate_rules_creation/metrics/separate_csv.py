import csv

input_file = "./raw_data_vm_updated/zipSlip_s3_anomalous/zipSlip_s3_ram_usage_timeseries.csv"
falco_file = "./raw_data_vm_updated/zipSlip_s3_anomalous/falco_zipSlip_s3_anomalous.csv"
prometheus_file = "./raw_data_vm_updated/zipSlip_s3_anomalous/prometheus_zipSlip_s3_anomalous.csv"

with open(input_file, "r", newline="", encoding="utf-8") as infile:
    reader = csv.reader(infile)

    header = next(reader)

    with open(falco_file, "w", newline="", encoding="utf-8") as falco_out, \
         open(prometheus_file, "w", newline="", encoding="utf-8") as prometheus_out:

        falco_writer = csv.writer(falco_out)
        prometheus_writer = csv.writer(prometheus_out)

        # Write the header to both files
        falco_writer.writerow(header)
        prometheus_writer.writerow(header)

        for row in reader:
            # Check the entire row for the service name
            row_text = ",".join(row).lower()

            if "falco" in row_text:
                falco_writer.writerow(row)

            elif "prometheus" in row_text:
                prometheus_writer.writerow(row)

print(f"Created {falco_file} and {prometheus_file}")
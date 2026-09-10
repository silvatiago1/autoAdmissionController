from textwrap import dedent
import yaml


class LiteralStr(str):
    pass


def represent_literal_str(dumper, data):
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")


yaml.add_representer(LiteralStr, represent_literal_str)
yaml.SafeDumper.add_representer(LiteralStr, represent_literal_str)

DEFAULT_RESOURCES = {
    "requests": {
        "cpu": "100m",
        "memory": "128Mi",
    },
    "limits": {
        "cpu": "500m",
        "memory": "256Mi",
    },
}


def parse_k8s_quantity(val: str | float | int) -> float:
    """Converts Kubernetes quantity strings (e.g., 100m, 128Mi, 1Gi) to numerical values."""
    if not val:
        return 0.0
    val_str = str(val).strip()

    if val_str.endswith("Ki"):
        return float(val_str[:-2]) * 1024
    if val_str.endswith("Mi"):
        return float(val_str[:-2]) * 1024**2
    if val_str.endswith("Gi"):
        return float(val_str[:-2]) * 1024**3
    if val_str.endswith("Ti"):
        return float(val_str[:-2]) * 1024**4

    if val_str.endswith("m"):
        return float(val_str[:-1]) / 1000.0

    return float(val_str)


def _to_valid_alert_name(text: str) -> str:
    """Sanitizes names with hyphens to valid Prometheus alert identifier format."""
    return "".join(part.capitalize() for part in text.replace("-", "_").split("_"))


def prometheus_rules_create(
    resources_spec: dict,
    namespace: str,
    name_prefix: str,
    extra_template_container: str = None,
) -> dict:
    """Generates a Kubernetes PrometheusRule CRD for CPU and Memory, scoped to template pods."""
    resources = resources_spec or {}
    limits = resources.get("limits", {})

    cpu_limit_str = limits.get("cpu", DEFAULT_RESOURCES["limits"]["cpu"])
    mem_limit_str = limits.get("memory", DEFAULT_RESOURCES["limits"]["memory"])

    cpu_cores = parse_k8s_quantity(cpu_limit_str)
    mem_bytes = int(parse_k8s_quantity(mem_limit_str))

    cpu_threshold = round((cpu_cores * 10) * 0.85, 4)
    mem_threshold = int(mem_bytes * 0.85)

    # Match pods that start with name_prefix and contain extra_template_container
    if extra_template_container:
        pod_pattern = f"{name_prefix}.*{extra_template_container}.*"
        container_suffix = f"-{extra_template_container}"
    else:
        pod_pattern = f"{name_prefix}.*"
        container_suffix = ""

    alert_prefix = _to_valid_alert_name(f"{name_prefix}{container_suffix}")
    rule_resource_name = f"{name_prefix}{container_suffix}-cpu-rules"

    prom_crd_yaml = dedent(f"""\
        apiVersion: monitoring.coreos.com/v1
        kind: PrometheusRule
        metadata:
          name: {rule_resource_name}
          labels:
            release: monitoring
        spec:
          groups:
          - name: {name_prefix}{container_suffix}-k8s-pod-resources
            rules:
            - alert: {alert_prefix}HighPodCpuUsage
              expr: |
                rate(container_cpu_usage_seconds_total{{namespace="{namespace}", pod=~"{pod_pattern}"}}[30s]) * 10 > {cpu_threshold}
              labels:
                severity: warning
              annotations:
                summary: "High CPU usage"
                description: "Pod matching regex '{pod_pattern}' in namespace {namespace} is using more than {cpu_threshold} CPU 100ms units (85% of limit {cpu_limit_str})."

            - alert: {alert_prefix}HighPodMemoryUsage
              expr: |
                container_memory_working_set_bytes{{namespace="{namespace}", pod=~"{pod_pattern}"}} > {mem_threshold}
              labels:
                severity: warning
              annotations:
                summary: "High Memory usage"
                description: "Pod matching regex '{pod_pattern}' in namespace {namespace} is exceeding 85% of memory limit ({mem_limit_str})."
    """)

    filename = f"{name_prefix}{container_suffix}-prometheus-rules.yaml"
    return {filename: LiteralStr(prom_crd_yaml)}
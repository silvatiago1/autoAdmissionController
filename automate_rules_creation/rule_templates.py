from textwrap import dedent
import yaml

class LiteralStr(str):
    pass

def represent_literal_str(dumper, data):
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")

yaml.add_representer(LiteralStr, represent_literal_str)
yaml.SafeDumper.add_representer(LiteralStr, represent_literal_str)

def _indent(text, n=4):
    pad = " " * n
    return "\n".join(pad + line if line else line for line in text.splitlines())

def _build_extraction_rule_shared_block(cmd_evt_flags, path, name_prefix, art_name, mainctrfs_condition, rule_suffix, output_suffix):
    proc_name = cmd_evt_flags["command"][0]
    evt_type = cmd_evt_flags["events"]["items"][0]
    flags = cmd_evt_flags["flags"]["items"]

    # Construct the condition strings
    # Joining flags with 'and' for the macro
    flags_condition = " and ".join([f"evt.arg.flags contains {f}" for f in flags])
    macro_cmd_events = dedent(f"""\
(proc.cmdline startswith "{proc_name}" and
          {_indent(f'evt.type={evt_type}',2)} and
          {_indent(f'({flags_condition}))',2)}
        """).strip()

    return dedent(f"""\
        - macro: cmd_events_flags
          condition: >
            {macro_cmd_events}

        - macro: file_path
          condition: fs.path.name contains "{path}" or fs.path.name contains "/mainctrfs{path}"

        - macro: in_mainctrfs
          condition: fs.path.name contains "/mainctrfs/" or evt.arg.target contains "/mainctrfs/"

        - macro: in_pod
          condition: k8s.pod.name startswith "{name_prefix}"

        - macro: link_path_artifacts
          condition: evt.arg.linkpath startswith "/argo/inputs/artifacts/"

        - macro: wrong_target
          condition: not (evt.arg.target contains "{path}") and not (evt.arg.target contains "/mainctrfs{path}")

        - macro: benign_files
          condition: fs.path.name="/var/run/argo/argoexec" or fs.path.name="/argo/inputs/artifacts/{art_name}.tmp" or fs.path.name="/var/run/argo/template" or fs.path.name startswith "/argo/inputs/artifacts/{art_name}.tmpdir/"

        - rule: {name_prefix}detect-path-extraction-{rule_suffix}
          desc: File extraction outside {path}
          condition: ((cmd_events_flags and (not file_path) and not benign_files) or (create_symlink and link_path_artifacts and wrong_target)) and k8s.ns.name = "argo" and in_pod and proc.cmdline startswith "argoexec init" {mainctrfs_condition}
          output: "File extraction outside of the intended path, to {output_suffix}, {path} | user=%user.name command=%proc.cmdline file=%fd.name file_source=%fs.path.source file_target=%fs.path.target linkpath=%evt.arg.linkpath target=%evt.arg.target evt_type=%evt.type evt_arg_flags=%evt.arg.flags"
          priority: WARNING
    """)

def extraction_rule_create(cmd_evt_flags, path, namespace, name_prefix, art_name):
    yaml_mounted_volume = _build_extraction_rule_shared_block(
        cmd_evt_flags=cmd_evt_flags,
        path=path,
        name_prefix=name_prefix,
        art_name=art_name,
        mainctrfs_condition="and in_mainctrfs",
        rule_suffix="mnt-vol",
        output_suffix="a mounted volume's path",
    )

    yaml_argo_path = _build_extraction_rule_shared_block(
        cmd_evt_flags=cmd_evt_flags,
        path=path,
        name_prefix=name_prefix,
        art_name=art_name,
        mainctrfs_condition="and not in_mainctrfs",
        rule_suffix="arg-path",
        output_suffix="an Argo path",
    )

    return {
        "customRules": {
            f"{name_prefix}detect-path-extraction-mnt-vol.yaml": LiteralStr(yaml_mounted_volume),
            f"{name_prefix}detect-path-extraction-arg-path.yaml": LiteralStr(yaml_argo_path),
        }
    }
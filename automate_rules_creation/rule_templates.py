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


def extraction_rule_create(cmd_evt_flags, path, namespace, name_prefix, art_name):
    proc_name = cmd_evt_flags['command'][0]
    evt_type = cmd_evt_flags['events']['items'][0]
    flags = cmd_evt_flags['flags']['items']
    
    # Construct the condition strings
    # Joining flags with 'and' for the macro
    flags_condition = " and ".join([f"evt.arg.flags contains {f}" for f in flags])
    macro_cmd_events = dedent(f"""\
(proc.cmdline startswith "{proc_name}" and
      {_indent(f'evt.type={evt_type}',2)} and
      {_indent(f'({flags_condition}))',2)}
        """).strip()

    # Define the rule structure and create said rule
    yaml_mounted_volume = dedent(f"""\
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


    - rule: write_tmp_dir
      desc: File extraction outside {path}
      condition: ((cmd_events_flags and (not file_path) and not benign_files) or (create_symlink and link_path_artifacts and wrong_target)) and k8s.ns.name = "argo" and in_pod and proc.cmdline startswith "argoexec init" and in_mainctrfs
      output: "File extraction outside of the intended path, to a mounted volume's path, {path} | user=%user.name command=%proc.cmdline file=%fd.name file_source=%fs.path.source file_target=%fs.path.target linkpath=%evt.arg.linkpath target=%evt.arg.target evt_type=%evt.type evt_arg_flags=%evt.arg.flags"
      priority: WARNING
    """)

    yaml_argo_path = dedent(f"""\
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


    - rule: write_tmp_dir
      desc: File extraction outside {path}
      condition: ((cmd_events_flags and (not file_path) and not benign_files) or (create_symlink and link_path_artifacts and wrong_target)) and k8s.ns.name = "argo" and in_pod and proc.cmdline startswith "argoexec init" and not in_mainctrfs
      output: "File extraction outside of the intended path, to an Argo path, {path} | user=%user.name command=%proc.cmdline file=%fd.name file_source=%fs.path.source file_target=%fs.path.target linkpath=%evt.arg.linkpath target=%evt.arg.target evt_type=%evt.type evt_arg_flags=%evt.arg.flags"
      priority: WARNING
    """)

    final_output = {
        "customRules": {
            f"{name_prefix}detect_path_extraction_mnt_vol.yaml": LiteralStr(yaml_mounted_volume),
            f"{name_prefix}detect_path_extraction_arg_path.yaml": LiteralStr(yaml_argo_path)
        }
    }
    return final_output
    
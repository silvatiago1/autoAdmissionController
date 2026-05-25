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

def _build_extraction_rule_shared_block(cmd_evt_flags, path, namespace, name_prefix, art_name, mainctrfs_condition, rule_suffix, output_suffix, extra_pod_text):
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
          condition: k8s.pod.name startswith "{name_prefix}"{extra_pod_text}

        - macro: link_path_artifacts
          condition: evt.arg.linkpath startswith "/argo/inputs/artifacts/"

        - macro: wrong_target
          condition: not (evt.arg.target contains "{path}") and not (evt.arg.target contains "/mainctrfs{path}")

        - macro: benign_files
          condition: fs.path.name="/var/run/argo/argoexec" or fs.path.name="/argo/inputs/artifacts/{art_name}.tmp" or fs.path.name="/var/run/argo/template" or fs.path.name startswith "/argo/inputs/artifacts/{art_name}.tmpdir/"

        - rule: {name_prefix}detect-path-extraction-{rule_suffix}
          desc: File extraction outside {path}
          condition: ((cmd_events_flags and (not file_path) and not benign_files) or (create_symlink and link_path_artifacts and wrong_target)) and k8s.ns.name = "{namespace}" and in_pod and proc.cmdline startswith "argoexec init" {mainctrfs_condition}
          output: "File extraction outside of the intended path, to {output_suffix}, {path} | user=%user.name command=%proc.cmdline file=%fd.name file_source=%fs.path.source file_target=%fs.path.target linkpath=%evt.arg.linkpath target=%evt.arg.target evt_type=%evt.type evt_arg_flags=%evt.arg.flags"
          priority: WARNING
    """)

def extraction_rules_create(cmd_evt_flags, path, namespace, name_prefix, art_name, extra_template_container):
    extra_pod_text=''
    if(extra_template_container!=None):
        extra_pod_text = f' and k8s.pod.name contains "{extra_template_container}"'
    yaml_mounted_volume = _build_extraction_rule_shared_block(
        cmd_evt_flags=cmd_evt_flags,
        path=path,
        namespace=namespace,
        name_prefix=name_prefix,
        art_name=art_name,
        mainctrfs_condition="and in_mainctrfs",
        rule_suffix="mnt-vol",
        output_suffix="a mounted volume's path",
        extra_pod_text=extra_pod_text,
    )

    yaml_argo_path = _build_extraction_rule_shared_block(
        cmd_evt_flags=cmd_evt_flags,
        path=path,
        namespace=namespace,
        name_prefix=name_prefix,
        art_name=art_name,
        mainctrfs_condition="and not in_mainctrfs",
        rule_suffix="arg-path",
        output_suffix="an Argo path",
        extra_pod_text=extra_pod_text,
    )

    return {
            f"{name_prefix}{extra_template_container}-detect-path-extraction-mnt-vol.yaml": LiteralStr(yaml_mounted_volume),
            f"{name_prefix}{extra_template_container}-detect-path-extraction-arg-path.yaml": LiteralStr(yaml_argo_path),
    }

def _build_container_rules_create_shared_block(namespace, name_prefix, extra_template_container, command_name, non_argo_cmd, conf_cmd_args, rule_specific_condition, rule_specific_text):
    extra_pod_text=''
    if(extra_template_container!=None):
        extra_pod_text = f' and k8s.pod.name contains "{extra_template_container}"'
    return dedent(f"""\
        - macro: conf_cmd
          condition: proc.name="{command_name}"
{non_argo_cmd}
        - macro: in_pod
          condition: k8s.pod.name startswith "{name_prefix}"{extra_pod_text}
{conf_cmd_args}
        - rule: {name_prefix}detect-container-unconfigured-commands
          desc: Non-Argo default command/Non-Defined in yaml command detected
          condition: {rule_specific_condition} and k8s.ns.name = "{namespace}" and in_pod
          output: "{rule_specific_text} | user=%user.name command_name=%proc.name command=%proc.cmdline file=%fd.name file_source=%fs.path.source file_target=%fs.path.target linkpath=%evt.arg.linkpath target=%evt.arg.target evt_type=%evt.type evt_arg_flags=%evt.arg.flags"
          priority: WARNING
    """)

def container_rules_create(namespace, name_prefix, extra_template_container, command_name, command, args):
    '''conf_cmd_args =
    non_argo_cmd=
        - macro: non_argo_command
          condition: proc.name exists and not proc.name in (argoexec, pause, workflow-contro) and not proc.name startswith runc
{conf_cmd_args}
    rule_specific_condition = 'non_argo_command and not conf_cmd'
    rule_specific_text = 'Detected non-configured command'
    yaml_not_in_conf_cmds = _build_container_rules_create_shared_block(
        namespace,
        name_prefix,
        extra_template_container,
        command,
        non_argo_cmd,
        conf_cmd_args,
        rule_specific_condition,
        rule_specific_text,
    )'''
    non_argo_cmd=''
    conf_cmd_args = f'''
        - macro: conf_cmd_args
          condition: proc.cmdline="{command} {args}"
'''
    rule_specific_condition = 'conf_cmd and not conf_cmd_args'
    rule_specific_text = 'Detected unknown args in configured command'
    yaml_in_conf_cmds_not_args = _build_container_rules_create_shared_block(
        namespace,
        name_prefix,
        extra_template_container,
        command_name,
        non_argo_cmd,
        conf_cmd_args,
        rule_specific_condition,
        rule_specific_text,
    )

    return {
            #f"{name_prefix}{extra_template_container}-cmd-not-in-conf.yaml": LiteralStr(yaml_not_in_conf_cmds),
            f"{name_prefix}{extra_template_container}-cmd-in-conf-not-args.yaml": LiteralStr(yaml_in_conf_cmds_not_args),
    }
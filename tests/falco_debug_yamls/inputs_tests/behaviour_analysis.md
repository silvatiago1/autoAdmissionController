# Artifacts
Artifact Inputs are always collected by argoexec init. Input artifacts are placed in "/argo/inputs/artifacts/{name}.tmpdir/{file_name}"
Artifact Outputs are placed in /tmp/argo/outputs/artifacts/{name}, before that, they are placed inside their container, on the directory indicated by the workflow.

Mainctrfs is only used when the artifact path overlaps a user volume mount. Can't use it to detect if therewas a zipslip, but
can use it to distinguish whether the zipslip occured in a normal argo path, or in a mounted volume path.

# Parameters
As inputs: Can not receive parameters as inputs directly into a file, and from what I have seen, I do not think that there is a way to detect their currect placement.

As outputs: Can be detected when present in the following format:
```
outputs:
      parameters:
```
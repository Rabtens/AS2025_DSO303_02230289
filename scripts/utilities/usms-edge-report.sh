#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/configs/course.env"

python3 - <<'PY'
import json
import os
import subprocess
import sys


def aws_json(*args):
    command = ["aws", "--endpoint-url", os.environ["FLOCI_ENDPOINT"],
               "--region", os.environ["AWS_REGION_COURSE"], "--output", "json", *args]
    result = subprocess.run(command, check=True, stdout=subprocess.PIPE, text=True)
    return json.loads(result.stdout)


def report(function):
    name = function["FunctionName"]
    versions = aws_json("lambda", "list-versions-by-function", "--function-name", name)
    aliases = aws_json("lambda", "list-aliases", "--function-name", name)
    version_count = sum(item["Version"] != "$LATEST" for item in versions["Versions"])
    runtime = function.get("Runtime", "")
    memory = function["MemorySize"]
    timeout = function["Timeout"]
    env_vars = bool((function.get("Environment") or {}).get("Variables"))
    vpc = function.get("VpcConfig") or {}
    in_vpc = any(vpc.get(key) for key in ("VpcId", "SubnetIds", "SecurityGroupIds"))
    memory_cap, timeout_cap = (128, 5) if "viewer" in name else (10240, 30)
    eligible = (runtime.startswith(("nodejs", "python")) and not env_vars
                and not in_vpc and version_count > 0
                and memory <= memory_cap and timeout <= timeout_cap)
    return dict(name=name, runtime=runtime, memory=memory, timeout=timeout,
                versions=version_count, aliases=len(aliases["Aliases"]),
                env_vars=env_vars, edge_eligible=eligible)


try:
    functions = aws_json("lambda", "list-functions")["Functions"]
    rows = [report(fn) for fn in sorted(functions, key=lambda item: item["FunctionName"])
            if fn["FunctionName"].startswith("usms-")]
except (subprocess.CalledProcessError, KeyError, ValueError) as exc:
    print(f"Could not build edge report: {exc}", file=sys.stderr)
    sys.exit(1)

print(json.dumps(rows, indent=2))
PY

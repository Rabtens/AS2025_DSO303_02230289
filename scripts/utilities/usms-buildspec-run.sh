#!/usr/bin/env bash
# Run a buildspec's phases locally, in order, in one shell.
# Usage: usms-buildspec-run.sh <app-dir> [buildspec-file]
set -uo pipefail

APP_DIR="${1:-}"
SPEC="${2:-buildspec.yml}"
if [ -z "$APP_DIR" ] || [ ! -d "$APP_DIR" ]; then
  echo "usage: $0 <app-dir> [buildspec-file]" >&2
  exit 2
fi
APP_ABS="$(cd "$APP_DIR" && pwd)"
if [ ! -f "$APP_ABS/$SPEC" ]; then
  echo "no $SPEC in $APP_ABS" >&2
  exit 2
fi

GEN="${TMPDIR:-/tmp}/usms-buildspec-$$.sh"

python3 - "$APP_ABS/$SPEC" "$GEN" << 'PY'
import sys

spec_path, out_path = sys.argv[1], sys.argv[2]
ORDER = ("install", "pre_build", "build", "post_build")


def with_pyyaml(path):
    import yaml
    doc = yaml.safe_load(open(path))
    env = ((doc.get("env") or {}).get("variables") or {})
    phases = {}
    for name, body in (doc.get("phases") or {}).items():
        phases[name] = list((body or {}).get("commands") or [])
    return env, phases


def minimal(path):
    """Handles exactly the buildspec subset this course writes:
    env: -> variables: -> KEY: value ; phases: -> <phase>: -> commands: -> '- cmd'
    or '- |' followed by a more-indented literal block."""
    env, phases = {}, {}
    in_env = in_env_vars = in_phases = in_commands = False
    phase = None
    cmds = None
    block = None
    block_indent = 0

    def close_block():
        nonlocal block
        if block is not None:
            cmds.append("\n".join(block).rstrip())
            block = None

    for raw in open(path).read().splitlines():
        if block is not None:
            if raw.strip() == "":
                block.append("")
                continue
            if (len(raw) - len(raw.lstrip())) >= block_indent:
                block.append(raw[block_indent:])
                continue
            close_block()
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        if indent == 0:
            in_env = stripped.startswith("env:")
            in_phases = stripped.startswith("phases:")
            in_env_vars = in_commands = False
            phase = None
            continue
        if in_env and indent == 2:
            in_env_vars = (stripped == "variables:")
            continue
        if in_env_vars and indent == 4 and ":" in stripped:
            k, v = stripped.split(":", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
            continue
        if in_phases and indent == 2 and stripped.endswith(":"):
            phase = stripped[:-1]
            phases[phase] = []
            cmds = phases[phase]
            in_commands = False
            continue
        if in_phases and phase and indent == 4 and stripped == "commands:":
            in_commands = True
            continue
        if in_commands and stripped.startswith("- "):
            body = stripped[2:]
            if body.strip() == "|":
                block = []
                block_indent = indent + 2
            else:
                cmds.append(body)
            continue
    close_block()
    return env, phases


try:
    env, phases = with_pyyaml(spec_path)
    parser = "PyYAML"
except ImportError:
    env, phases = minimal(spec_path)
    parser = "built-in minimal parser"

lines = ["#!/usr/bin/env bash", "set -Eeuo pipefail", ""]
for k, v in env.items():
    # A value already in the environment wins, the way a CodeBuild project-level
    # environment variable overrides a buildspec env.variables default.
    lines.append('export %s="${%s:-%s}"' % (k, k, v))
lines.append("")
for name in ORDER:
    if name not in phases:
        continue
    lines.append('echo "=== phase: %s ==="' % name)
    lines.extend(phases[name])
    lines.append("")
lines.append('echo "=== all phases completed ==="')

open(out_path, "w").write("\n".join(lines) + "\n")
print("buildspec parsed with %s; %d phases" % (parser, len([p for p in ORDER if p in phases])))
PY

RC=$?
[ "$RC" -ne 0 ] && { echo "could not parse the buildspec" >&2; exit "$RC"; }

echo "--- generated script: $GEN ---"
bash -n "$GEN" && echo "generated script is valid bash"
echo "--- running in $APP_ABS ---"
( cd "$APP_ABS" && bash "$GEN" )
STATUS=$?
echo "--- local build exit status: $STATUS ---"
rm -f "$GEN"
exit "$STATUS"

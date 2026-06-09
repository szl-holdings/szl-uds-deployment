#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# lint-zarf-action-vars.py — Fail on the ###ZARF_VAR_*### template form inside a
# zarf action 'cmd:'. Zarf only substitutes ###ZARF_VAR_NAME### inside component
# files / manifests / chart values — NOT inside actions[].cmd, where a variable
# only arrives as the $ZARF_VAR_NAME environment variable. Using the template
# form in a cmd silently never substitutes (no error), so any comparison or
# interpolation against it is always wrong. Authors must use $ZARF_VAR_NAME /
# ${ZARF_VAR_NAME:-default} in action commands instead.
#
# Scope is intentionally narrow: only cmd values reached through
# components[].actions are checked, so a legitimate ###ZARF_VAR_*### in files /
# manifests / chart values is left alone.
import sys
import glob
import re

try:
    import yaml
except ImportError:
    sys.exit("::error::PyYAML is required (pip install pyyaml)")

PATTERN = re.compile(r"###ZARF_VAR_[A-Za-z0-9_]+###")


def iter_cmds(node):
    """Yield every 'cmd' string reached anywhere within an actions subtree."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "cmd":
                if isinstance(v, str):
                    yield v
                elif isinstance(v, list):
                    for item in v:
                        if isinstance(item, str):
                            yield item
            else:
                yield from iter_cmds(v)
    elif isinstance(node, list):
        for item in node:
            yield from iter_cmds(item)


def main(argv):
    files = argv[1:] or sorted(glob.glob("**/zarf.yaml", recursive=True))
    if not files:
        print("no zarf.yaml files found")
        return 0
    violations = []
    for f in files:
        try:
            docs = list(yaml.safe_load_all(open(f)))
        except yaml.YAMLError as e:
            print("::error file=%s::could not parse YAML: %s" % (f, e))
            violations.append((f, "<parse>", str(e)))
            continue
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            for comp in doc.get("components", []) or []:
                if not isinstance(comp, dict):
                    continue
                actions = comp.get("actions")
                if not actions:
                    continue
                cname = comp.get("name", "<unnamed>")
                for cmd in iter_cmds(actions):
                    for hit in dict.fromkeys(PATTERN.findall(cmd)):
                        var = hit[3:-3]
                        violations.append((f, cname, hit))
                        print(
                            "::error file=%s::component '%s': action cmd uses %s — "
                            "that template form never substitutes inside actions[].cmd; "
                            'use the $%s env var (e.g. "${%s:-default}") instead.'
                            % (f, cname, hit, var, var)
                        )
    print("checked %d zarf.yaml file(s)" % len(files))
    if violations:
        print(
            "FAIL: %d forbidden ###ZARF_VAR_*### use(s) inside action cmd blocks"
            % len(violations)
        )
        return 1
    print("OK: no ###ZARF_VAR_*### template form inside any action cmd block")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

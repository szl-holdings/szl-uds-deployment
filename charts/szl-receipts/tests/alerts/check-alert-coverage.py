# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# check-alert-coverage.py — close the "untested new alert" coverage hole.
#
# WHY THIS EXISTS
# ---------------
# run-alert-tests.sh already (1) diffs the rendered chart against
# rules.rendered.yaml (drift guard) and (2) runs `promtool test rules`. But
# promtool only runs the test cases it is GIVEN — it never complains that an
# alert in the rule has no test at all. So if someone adds a BRAND-NEW alert to
# templates/prometheusrule.yaml and updates rules.rendered.yaml to match (the
# drift guard then passes), the new alert ships with ZERO test coverage and CI
# stays green.
#
# This guard closes that hole. It parses every `alert:` name from the rendered
# rule fixture and every `alertname:` exercised in the promtool test file, and
# fails loudly if:
#   (a) a rule alert has NO matching test case at all, OR
#   (b) a rule alert is referenced ONLY by negative/silent checks (exp_alerts: [])
#       and never by a test that proves it FIRES (exp_alerts non-empty), OR
#   (c) a test references an alertname that does not exist in the rule (a typo or
#       a rename that left the test pointing at a dead name — promtool would pass
#       such a test vacuously, so the real alert would again be untested).
#
# Usage:
#   python3 check-alert-coverage.py <rules.rendered.yaml> <alerts_test.yaml>
#
# Exits 0 when every alert is covered, 1 otherwise (printing what is missing).
import sys
import yaml


def rule_alert_names(path):
    """Every `alert:` name in the rendered rule file (recording rules skipped)."""
    doc = yaml.safe_load(open(path))
    names = []
    for group in (doc or {}).get("groups", []) or []:
        for rule in group.get("rules", []) or []:
            name = rule.get("alert")
            if name:
                names.append(name)
    return names


def tested_alert_names(path):
    """
    Map alertname -> bool(has a firing assertion) across every test case.

    A test "fires" the alert when its alert_rule_test entry lists a non-empty
    exp_alerts. A test that only asserts exp_alerts: [] proves the alert stays
    SILENT, which is necessary but does not prove the alert ever fires.
    """
    doc = yaml.safe_load(open(path))
    fired = {}
    for test in (doc or {}).get("tests", []) or []:
        for case in test.get("alert_rule_test", []) or []:
            name = case.get("alertname")
            if not name:
                continue
            exp = case.get("exp_alerts") or []
            fired[name] = fired.get(name, False) or bool(exp)
    return fired


def main(argv):
    if len(argv) != 3:
        print("usage: check-alert-coverage.py <rules.rendered.yaml> <alerts_test.yaml>")
        return 2

    rules_path, tests_path = argv[1], argv[2]
    alerts = rule_alert_names(rules_path)
    fired = tested_alert_names(tests_path)

    if not alerts:
        print(f"COVERAGE: no alerts found in {rules_path} — nothing to test?")
        return 1

    errors = []

    # (a) + (b): every rule alert must be exercised by a FIRING test case.
    for name in alerts:
        if name not in fired:
            errors.append(
                f"  - {name}: NO test case in {tests_path} "
                f"(every alert must have a promtool test that proves it fires)"
            )
        elif not fired[name]:
            errors.append(
                f"  - {name}: only silent/negative checks (exp_alerts: []) — "
                f"add a test case that asserts it FIRES under its failure condition"
            )

    # (c): a test pointing at a name the rule does not define means a real alert
    # is (still) untested — catch the rename/typo before it ships green.
    rule_set = set(alerts)
    for name in fired:
        if name not in rule_set:
            errors.append(
                f"  - {name}: tested in {tests_path} but NO such alert in "
                f"{rules_path} (typo, or the alert was renamed/removed?)"
            )

    if errors:
        print("COVERAGE FAIL: receipt-stall alerts missing a matching test case:")
        print("\n".join(errors))
        print(
            "\nFix: add a test case to alerts_test.yaml that drives each alert's "
            "failure condition and asserts exp_alerts for it."
        )
        return 1

    print(
        f"OK: all {len(alerts)} alert(s) have a firing test case "
        f"({', '.join(alerts)})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

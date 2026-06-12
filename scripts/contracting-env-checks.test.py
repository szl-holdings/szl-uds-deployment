# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Self-test for contracting-env-checks.py. Proves the guard is not vacuous: a
# faithful fixture of each surface PASSES, and a fixture mutated to silently
# revert the founder's confirmed org facts (rename/drop a canonical var, drop a
# legacy alias, reverse an alias pair so the legacy name wins, or break the
# present->confirmed / absent->needs_founder_input flip) FAILS. No network.
#
# Run by file path (the leading-dot dir is not importable as a module):
#   python3 scripts/contracting-env-checks.test.py

import importlib.util
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "contracting_env_checks", os.path.join(_HERE, "contracting-env-checks.py"))
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

GuardError = _mod.GuardError

# ── Faithful minimal fixtures (mirror the real surfaces' shape) ───────────────
GOOD_CANONICAL = '''
import os
def _env_val(name):
    v = os.environ.get(name)
    return v if v else None

_ORG = {
    "uei": _env_val("SZL_CONTRACTING_UEI"),
    "cage": _env_val("SZL_CONTRACTING_CAGE"),
    "sam_status": _env_val("SZL_CONTRACTING_SAM_STATUS"),
    "sam_expires": _env_val("SZL_CONTRACTING_SAM_EXPIRES"),
    "sbc_control_id": _env_val("SZL_CONTRACTING_SBC_CONTROL_ID"),
    "employees": _env_val("SZL_CONTRACTING_EMPLOYEES"),
    "us_ownership_pct": _env_val("SZL_CONTRACTING_US_OWNERSHIP_PCT"),
    "legal_form": _env_val("SZL_CONTRACTING_LEGAL_FORM"),
    "for_profit_us": _env_val("SZL_CONTRACTING_FORPROFIT_US"),
}
_ORG_ENV = {
    "uei": "SZL_CONTRACTING_UEI", "cage": "SZL_CONTRACTING_CAGE",
    "sam_status": "SZL_CONTRACTING_SAM_STATUS", "sam_expires": "SZL_CONTRACTING_SAM_EXPIRES",
    "sbc_control_id": "SZL_CONTRACTING_SBC_CONTROL_ID", "employees": "SZL_CONTRACTING_EMPLOYEES",
    "us_ownership_pct": "SZL_CONTRACTING_US_OWNERSHIP_PCT", "legal_form": "SZL_CONTRACTING_LEGAL_FORM",
    "for_profit_us": "SZL_CONTRACTING_FORPROFIT_US",
}

ITEMS = [
    {"org_key": "uei", "status": "needs_founder_input"},
    {"org_key": "cage", "status": "needs_founder_input"},
]

def _resolve_item(it):
    out = dict(it)
    ok = it.get("org_key")
    if ok and _ORG.get(ok):
        out["status"] = "confirmed"
        out["value"] = _ORG.get(ok)
    return out
'''

GOOD_A11OY = '''
import os
def _ct_org_fact(env_key):
    keys = (env_key,) if isinstance(env_key, str) else tuple(env_key)
    for k in keys:
        v = os.environ.get(k)
        if v:
            return v, k
    return None, (keys[0] if keys else None)

def _ct_org(label, requirement, env_key, src_key, action_note, probe=False):
    val, matched = _ct_org_fact(env_key)
    it = {"label": label}
    if val:
        it["status"] = "confirmed"; it["value"] = val
    else:
        it["status"] = "needs_founder_input"
        it["note"] = action_note
    return it

def _ct_areas():
    return [
        _ct_org("UEI", "r", ("SZL_CONTRACTING_UEI", "A11OY_ORG_UEI"), "uei", "n"),
        _ct_org("CAGE", "r", ("SZL_CONTRACTING_CAGE", "A11OY_ORG_CAGE"), "cage", "n"),
        _ct_org("Legal name", "r", "A11OY_ORG_LEGAL_NAME", "sam_reg", "n"),
        _ct_org("SAM status", "r", ("SZL_CONTRACTING_SAM_STATUS",), "far_7", "n"),
        _ct_org("SAM expires", "r", ("SZL_CONTRACTING_SAM_EXPIRES",), "sam_reg", "n"),
        _ct_org("Legal form", "r", ("SZL_CONTRACTING_LEGAL_FORM",), "sbir_elig", "n"),
        _ct_org("Employees", "r", ("SZL_CONTRACTING_EMPLOYEES", "A11OY_ORG_HEADCOUNT"), "naics", "n"),
        _ct_org("Ownership", "r", ("SZL_CONTRACTING_US_OWNERSHIP_PCT", "A11OY_ORG_OWNERSHIP"), "sbir_size", "n"),
        _ct_org("For-profit", "r", ("SZL_CONTRACTING_FORPROFIT_US",), "sbir_elig", "n"),
        _ct_org("SBC control", "r", ("SZL_CONTRACTING_SBC_CONTROL_ID",), "sbir_elig", "n"),
    ]
'''

_FAILS = 0


def expect_pass(fn, text, name):
    global _FAILS
    try:
        fn(text)
        print("PASS (accepts faithful): %s" % name)
    except GuardError as exc:
        _FAILS += 1
        print("FAIL: %s rejected a faithful fixture: %s" % (name, exc))


def expect_fail(fn, text, name):
    global _FAILS
    try:
        fn(text)
        _FAILS += 1
        print("FAIL: %s ACCEPTED a broken fixture (guard is vacuous!)" % name)
    except GuardError:
        print("PASS (rejects broken): %s" % name)


def main():
    # Faithful fixtures must pass.
    expect_pass(_mod.check_canonical, GOOD_CANONICAL, "canonical faithful")
    expect_pass(_mod.check_a11oy, GOOD_A11OY, "a11oy faithful")

    # ── canonical negative fixtures ───────────────────────────────────────────
    expect_fail(_mod.check_canonical,
                GOOD_CANONICAL.replace("SZL_CONTRACTING_UEI", "SZL_CONTRACTING_UEY"),
                "canonical: renamed UEI var")
    expect_fail(_mod.check_canonical,
                GOOD_CANONICAL.replace(
                    '"cage": "SZL_CONTRACTING_CAGE",', '"cage": "WRONG_NAME",'),
                "canonical: _ORG_ENV mapping dropped for CAGE")
    expect_fail(_mod.check_canonical,
                GOOD_CANONICAL.replace(
                    "if ok and _ORG.get(ok):", "if ok:"),
                "canonical: confirmed no longer gated on a present value")
    expect_fail(_mod.check_canonical,
                GOOD_CANONICAL.replace('"confirmed"', '"verified"'),
                "canonical: present-value no longer maps to confirmed")
    expect_fail(_mod.check_canonical,
                GOOD_CANONICAL.replace("needs_founder_input", "ready"),
                "canonical: honest needs_founder_input default removed")

    # ── a11oy negative fixtures ───────────────────────────────────────────────
    expect_fail(_mod.check_a11oy,
                GOOD_A11OY.replace("SZL_CONTRACTING_FORPROFIT_US", "SZL_CONTRACTING_FORPROFIT"),
                "a11oy: renamed FORPROFIT_US var")
    expect_fail(_mod.check_a11oy,
                GOOD_A11OY.replace('"A11OY_ORG_HEADCOUNT"', '"OLD_HEADCOUNT"'),
                "a11oy: legacy alias A11OY_ORG_HEADCOUNT dropped")
    expect_fail(_mod.check_a11oy,
                GOOD_A11OY.replace(
                    '("SZL_CONTRACTING_UEI", "A11OY_ORG_UEI")',
                    '("A11OY_ORG_UEI", "SZL_CONTRACTING_UEI")'),
                "a11oy: alias pair reversed so legacy name wins")
    expect_fail(_mod.check_a11oy,
                GOOD_A11OY.replace('it["status"] = "confirmed"; it["value"] = val',
                                   'it["value"] = val'),
                "a11oy: present-value no longer maps to confirmed")
    expect_fail(_mod.check_a11oy,
                GOOD_A11OY.replace("if val:", "if True:"),
                "a11oy: confirmed no longer gated on a present env value")
    expect_fail(_mod.check_a11oy,
                GOOD_A11OY.replace('it["status"] = "needs_founder_input"', 'pass'),
                "a11oy: honest needs_founder_input default removed")

    print("")
    if _FAILS:
        print("SELF-TEST FAILED: %d case(s) wrong." % _FAILS)
        return 1
    print("SELF-TEST OK: guard accepts faithful surfaces and rejects every "
          "silent-revert mutation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

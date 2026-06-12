# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# contracting-env-checks.py — assert the founder's confirmed Contracting Readiness
# org-fact env vars cannot silently revert on EITHER surface that serves them.
#
# The Contracting Readiness panel reads the org's own federal-registration facts
# ONLY from container env vars (see box-scripts/contracting-env.README.md). A fact
# is shown `confirmed` exactly when an operator supplied the value; otherwise it
# stays `needs_founder_input` (an honest unknown). Two independent code surfaces
# implement that env-var -> confirmed mapping, and they live in OTHER repos:
#
#   * canonical : szl-holdings/killinchu  szl_contracting.py
#                 (`_ORG` reads each canonical var via `_env_val(...)`, `_ORG_ENV`
#                  maps the internal key -> canonical name, `_resolve_item` flips
#                  present -> "confirmed" / absent -> "needs_founder_input").
#   * a11oy     : szl-holdings/a11oy      serve.py  (inline `contracting-tab-patch`
#                 route: `_ct_org_fact` reads the env keys canonical-first,
#                 `_ct_org` flips present -> "confirmed" / absent ->
#                 "needs_founder_input"; the a11oy route ALSO honors the legacy
#                 A11OY_ORG_* aliases, canonical winning).
#
# A sibling edit on either surface could rename/drop a canonical var, reverse an
# alias pair so the legacy alias wins, or remove the present->confirmed /
# absent->needs_founder_input flip — silently breaking the founder's confirmed
# company details with NOTHING failing. This checker turns each of those into a
# cluster-free CI failure. The workflow checks the two PUBLIC source repos out and
# feeds their files here; the self-test feeds deliberately-broken fixtures and
# asserts each check still FAILS (green-while-guarding-nothing protection).
#
# Pure stdlib. Usage:
#   python3 scripts/contracting-env-checks.py canonical <path-to-szl_contracting.py>
#   python3 scripts/contracting-env-checks.py a11oy     <path-to-serve.py>

import re
import sys

# ── The contract (canonical names = the env-var -> confirmed mapping) ──────────
# Keep in lockstep with box-scripts/contracting-env.README.md "Supported variable
# names (canonical)" + "Legacy aliases".
CANONICAL_VARS = [
    "SZL_CONTRACTING_UEI",
    "SZL_CONTRACTING_CAGE",
    "SZL_CONTRACTING_SAM_STATUS",
    "SZL_CONTRACTING_SAM_EXPIRES",
    "SZL_CONTRACTING_SBC_CONTROL_ID",
    "SZL_CONTRACTING_EMPLOYEES",
    "SZL_CONTRACTING_US_OWNERSHIP_PCT",
    "SZL_CONTRACTING_LEGAL_FORM",
    "SZL_CONTRACTING_FORPROFIT_US",
]

# Legacy alias -> the canonical var it backs on the a11oy inline route (canonical
# wins). A11OY_ORG_LEGAL_NAME has NO canonical equivalent (a standalone "legal
# entity name" fact) -> value None: assert presence only, no pairing.
LEGACY_ALIASES = {
    "A11OY_ORG_UEI": "SZL_CONTRACTING_UEI",
    "A11OY_ORG_CAGE": "SZL_CONTRACTING_CAGE",
    "A11OY_ORG_HEADCOUNT": "SZL_CONTRACTING_EMPLOYEES",
    "A11OY_ORG_OWNERSHIP": "SZL_CONTRACTING_US_OWNERSHIP_PCT",
    "A11OY_ORG_LEGAL_NAME": None,
}

CONFIRMED = "confirmed"            # status when an operator supplied the value
ABSENT = "needs_founder_input"     # honest-unknown status when the var is unset


class GuardError(Exception):
    pass


def _q(name):
    """A regex matching the var name as a single- or double-quoted string."""
    return r"""['"]""" + re.escape(name) + r"""['"]"""


def _slice_block(text, start_pat, label):
    """Return the brace-balanced { ... } block whose opening is matched by
    start_pat (which must end at the opening '{'). Raises if not found."""
    m = re.search(start_pat, text)
    if not m:
        raise GuardError("could not locate %s (pattern %r)" % (label, start_pat))
    i = text.index("{", m.start())
    depth = 0
    for j in range(i, len(text)):
        c = text[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    raise GuardError("unterminated %s block" % label)


def _slice_func(text, name):
    """Return the source text of a top-level / nested `def name(...)` body, from
    the `def` line to (but not including) the next line at the SAME indent that
    is not blank/comment. Good enough to scope status-flip assertions."""
    m = re.search(r"(?m)^([ \t]*)def %s\(" % re.escape(name), text)
    if not m:
        raise GuardError("could not find function def %s(...)" % name)
    indent = m.group(1)
    rest = text[m.end():]
    # Walk forward line by line; stop at the next line with indent <= def indent
    # that opens a new statement (def/class or any code at that column).
    lines = text[m.start():].splitlines(keepends=True)
    out = [lines[0]]
    for ln in lines[1:]:
        stripped = ln.strip()
        cur_indent = ln[:len(ln) - len(ln.lstrip(" \t"))]
        if stripped and not stripped.startswith("#") and len(cur_indent) <= len(indent):
            break
        out.append(ln)
    return "".join(out)


# ── Shared assertions ─────────────────────────────────────────────────────────
def _assert_all_vars_present(text, surface):
    for v in CANONICAL_VARS:
        if not re.search(_q(v), text):
            raise GuardError(
                "%s: canonical env var %s is no longer read (renamed/dropped). "
                "The founder's confirmed value for it would silently revert."
                % (surface, v))


def _assert_status_flip(confirmed_text, absent_text, surface, where):
    """Map present-value -> confirmed AND absent -> the honest needs_founder_input
    default. `confirmed_text` is the flip function body (the confirmed assignment
    must be scoped there); `absent_text` is where the honest default lives (the
    flip body for a11oy's explicit else, the items default for canonical)."""
    if CONFIRMED not in confirmed_text:
        raise GuardError(
            "%s: %s no longer assigns status %r for an operator-supplied value."
            % (surface, where, CONFIRMED))
    if ABSENT not in absent_text:
        raise GuardError(
            "%s: the honest %r default for an absent env var is gone."
            % (surface, ABSENT))


# ── canonical surface: killinchu szl_contracting.py ───────────────────────────
def check_canonical(text):
    surface = "canonical (szl_contracting.py)"
    _assert_all_vars_present(text, surface)

    # _ORG must read every canonical var via _env_val("VAR").
    for v in CANONICAL_VARS:
        if not re.search(r"_env_val\(\s*%s\s*\)" % _q(v), text):
            raise GuardError(
                "%s: _ORG no longer reads %s via _env_val(...); the env value "
                "would never reach the panel." % (surface, v))

    # _ORG_ENV must map each internal key to its canonical name string.
    org_env = _slice_block(text, r"_ORG_ENV\s*=\s*", "_ORG_ENV")
    for v in CANONICAL_VARS:
        if not re.search(_q(v), org_env):
            raise GuardError(
                "%s: _ORG_ENV no longer maps to %s (the 'Operator-confirmed via "
                "<VAR>' label would break)." % (surface, v))

    # _resolve_item flips present -> confirmed / absent -> needs_founder_input.
    body = _slice_func(text, "_resolve_item")
    if not re.search(r"if\s+ok\s+and\s+_ORG\.get\(\s*ok\s*\)\s*:", body):
        raise GuardError(
            "%s: _resolve_item no longer gates 'confirmed' on a present "
            "value (`if ok and _ORG.get(ok):`); an absent var could be "
            "confirmed." % surface)
    # confirmed is scoped to the resolver; the honest needs_founder_input default
    # is the items' pre-set status (canonical surface never confirms an absent var
    # because the flip is gated on _ORG.get(ok) above).
    _assert_status_flip(body, text, surface, "_resolve_item")
    print("OK: canonical surface reads all %d canonical vars and maps "
          "present->confirmed / absent->needs_founder_input." % len(CANONICAL_VARS))


# ── a11oy surface: serve.py inline contracting-tab-patch route ────────────────
def check_a11oy(text):
    surface = "a11oy (serve.py inline route)"
    _assert_all_vars_present(text, surface)

    # Every legacy alias must still be read.
    for alias in LEGACY_ALIASES:
        if not re.search(_q(alias), text):
            raise GuardError(
                "%s: legacy alias %s is no longer read; an operator still using "
                "the old name would silently lose their confirmed value."
                % (surface, alias))

    # Paired aliases must appear canonical-FIRST in the env tuple so the canonical
    # name wins (a reversal would let a stale legacy value override canonical).
    for alias, canon in LEGACY_ALIASES.items():
        if canon is None:
            continue
        pair = r"\(\s*%s\s*,\s*%s\s*[,)]" % (_q(canon), _q(alias))
        if not re.search(pair, text):
            raise GuardError(
                "%s: env tuple for %s is not (canonical, %s) canonical-first; "
                "canonical must win over the legacy alias." % (surface, canon, alias))

    # Every canonical var must actually be wired into a _ct_org(...) env tuple
    # (read as an org fact), not merely mentioned in a comment.
    for v in CANONICAL_VARS:
        if not re.search(r"\(\s*%s\s*[,)]" % _q(v), text):
            raise GuardError(
                "%s: %s is not passed as the first element of a _ct_org env "
                "tuple; it would not be read as an org fact." % (surface, v))

    # _ct_org flips present -> confirmed / absent -> needs_founder_input.
    body = _slice_func(text, "_ct_org")
    if "if val:" not in body:
        raise GuardError(
            "%s: _ct_org no longer gates 'confirmed' on a present env value "
            "(if val:)." % surface)
    # a11oy's _ct_org carries BOTH branches (confirmed + explicit else ->
    # needs_founder_input) in its own body.
    _assert_status_flip(body, body, surface, "_ct_org")

    # _ct_org_fact resolves the first non-empty env value (present) else None
    # (absent) -> the basis of the flip above.
    fact = _slice_func(text, "_ct_org_fact")
    if "environ.get" not in fact:
        raise GuardError(
            "%s: _ct_org_fact no longer reads the env vars via environ.get(...)."
            % surface)
    print("OK: a11oy surface reads all %d canonical vars + %d legacy aliases "
          "(canonical-first) and maps present->confirmed / absent->"
          "needs_founder_input." % (len(CANONICAL_VARS), len(LEGACY_ALIASES)))


CHECKS = {"canonical": check_canonical, "a11oy": check_a11oy}


def run(mode, path):
    if mode not in CHECKS:
        raise SystemExit("unknown mode %r; expected one of %s"
                         % (mode, ", ".join(sorted(CHECKS))))
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    CHECKS[mode](text)


def main(argv):
    if len(argv) != 3:
        raise SystemExit(
            "usage: contracting-env-checks.py {canonical|a11oy} <source-file>")
    try:
        run(argv[1], argv[2])
    except GuardError as exc:
        print("CONTRACTING-ENV GUARD FAILED: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

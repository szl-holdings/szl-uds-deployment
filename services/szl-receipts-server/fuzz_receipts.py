#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Atheris fuzz harness for the SZL receipts server's untrusted-input parsing
# surface (OSSF Scorecard "Fuzzing"). A receipt POST body is attacker-controlled,
# so the three pure parsers it flows through must never raise an *undocumented*
# exception:
#
#   * b64u_decode    — base64url decode of the signature / payload fields;
#   * dsse_pae        — canonical DSSE Pre-Authentication Encoding (must be total);
#   * _receipt_hash   — JSON canonicalisation + SHA-256 over the signed envelope.
#
# A crash with anything other than the parse errors enumerated in _expected()
# below is a real bug (e.g. an unhandled overflow / recursion / type confusion).
#
# Run locally:
#     pip install atheris
#     python3 fuzz_receipts.py -atheris_runs=200000
#
# In CI it is built and exercised by ClusterFuzzLite (.clusterfuzzlite/build.sh).
import os
import sys
import tempfile

# server.py runs `os.makedirs(SZL_RECEIPT_STORE)` at import time; point it at a
# throwaway temp dir so importing the module has no side effect on the host.
os.environ.setdefault("SZL_RECEIPT_STORE", tempfile.mkdtemp(prefix="szl-fuzz-"))
os.environ.setdefault("SZL_SIGNING_BACKEND", "file")

import atheris  # noqa: E402

# fuzz_receipts.py lives next to server.py, so a plain `import server` resolves
# both at PyInstaller analysis time (compile_python_fuzzer) and at runtime.
with atheris.instrument_imports():
    import server  # noqa: E402


def _expected(exc: BaseException) -> bool:
    """Exceptions a parser is allowed to raise on malformed input. Anything else
    propagates and is reported by atheris as a genuine crash."""
    return isinstance(exc, (ValueError, KeyError, TypeError, UnicodeDecodeError))


def TestOneInput(data: bytes) -> None:
    fdp = atheris.FuzzedDataProvider(data)
    text = fdp.ConsumeUnicodeNoSurrogates(fdp.ConsumeIntInRange(0, 256))
    body = fdp.ConsumeBytes(fdp.remaining_bytes())

    # 1) base64url decode of attacker-supplied text.
    try:
        server.b64u_decode(text)
    except Exception as exc:  # noqa: BLE001
        if not _expected(exc):
            raise

    # 2) canonical DSSE PAE must be total over (type, body) — never crash.
    server.dsse_pae(text, body)

    # 3) stable receipt hash over an attacker-shaped envelope.
    try:
        server._receipt_hash({"envelope": {"payload": text, "body": list(body[:16])}})
    except Exception as exc:  # noqa: BLE001
        if not _expected(exc):
            raise


def main() -> None:
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()

"""
SZL Energy Harvest — operational backend engine (pure stdlib, no key).

Doctrine v11: this is REAL public GRID DATA under the HONEST "grid" source. It
tells us when the grid is WASTING power — negative wholesale price (the grid is
PAYING to offload load) or renewables exceeding demand (curtailment) — so that
running our own compute is effectively soaking already-wasted energy. We never
invent numbers: each feed is fetched independently and tolerantly; a down feed
is reported "unreachable", not faked. This signal NEVER flips the sovereign
label, and joules stay SAMPLE until an on-box hardware meter (NVML) feeds them.

No free-energy claims. No greenwashing. Not one of the locked-8. Lambda =
Conjecture 1. Logic ported byte-for-byte (semantics) from szl-router core.
"""
from __future__ import annotations

import json
import time
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

# Real, no-key, public grid feeds.
_HARVEST_FEEDS = {
    "wholesale_price": "https://api.awattar.de/v1/marketdata",            # DE wholesale, EUR/MWh
    "renewable_share": "https://api.energy-charts.info/ren_share?country=de",
    "carbon_intensity": "https://api.carbonintensity.org.uk/intensity",   # UK gCO2/kWh + index
}
_HARVEST_TTL = 300.0  # seconds; don't hammer the public feeds
_HARVEST_CACHE: Dict[str, Any] = {"ts": 0.0, "data": None}


def _get_json(url: str, timeout: float) -> Any:
    req = urllib.request.Request(url, method="GET")
    req.add_header("User-Agent", "szl-energy-harvest/1.0 (+harvest)")
    req.add_header("Accept", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _fetch_awattar(timeout: float) -> Dict[str, Any]:
    try:
        d = _get_json(_HARVEST_FEEDS["wholesale_price"], timeout)
        rows = d.get("data") or []
        now_ms = time.time() * 1000
        price_now: Optional[float] = None
        nxt: List[float] = []
        for r in rows:
            st, en, mp = r.get("start_timestamp"), r.get("end_timestamp"), r.get("marketprice")
            if st is None or en is None or mp is None:
                continue
            if st <= now_ms < en:
                price_now = mp
            elif st > now_ms:
                nxt.append(mp)
        return {
            "status": "live", "market": "DE", "unit": "EUR/MWh",
            "price_now": price_now,
            "next_min": (min(nxt) if nxt else None),
            "next_max": (max(nxt) if nxt else None),
            "next_negative_windows": sum(1 for p in nxt if p < 0),
            "source": "api.awattar.de",
        }
    except Exception as e:  # noqa: BLE001 - honest unreachable, never faked
        return {"status": "unreachable", "error": f"{type(e).__name__}: {e}"[:120],
                "source": "api.awattar.de"}


def _fetch_ren_share_de(timeout: float) -> Dict[str, Any]:
    try:
        d = _get_json(_HARVEST_FEEDS["renewable_share"], timeout)
        series = d[0] if isinstance(d, list) and d else {}
        data = series.get("data") or []
        vals = [v for v in data if isinstance(v, (int, float))]
        return {"status": "live", "country": "DE",
                "renewable_share_pct": (vals[-1] if vals else None),
                "source": "api.energy-charts.info"}
    except Exception as e:  # noqa: BLE001
        return {"status": "unreachable", "error": f"{type(e).__name__}: {e}"[:120],
                "source": "api.energy-charts.info"}


def _fetch_uk_carbon(timeout: float) -> Dict[str, Any]:
    try:
        d = _get_json(_HARVEST_FEEDS["carbon_intensity"], timeout)
        intensity = ((d.get("data") or [{}])[0] or {}).get("intensity") or {}
        return {"status": "live", "region": "UK",
                "gco2_per_kwh": intensity.get("actual") if intensity.get("actual") is not None
                else intensity.get("forecast"),
                "index": intensity.get("index"),
                "source": "api.carbonintensity.org.uk"}
    except Exception as e:  # noqa: BLE001
        return {"status": "unreachable", "error": f"{type(e).__name__}: {e}"[:120],
                "source": "api.carbonintensity.org.uk"}


# Posture thresholds. Pure function so classification is deterministic and
# unit-testable WITHOUT any network.
_CHEAP_EUR_MWH = 30.0
_EXPENSIVE_EUR_MWH = 100.0
_CURTAILMENT_REN_PCT = 100.0  # renewables meeting/exceeding load


def _classify_harvest(
    price_now: Optional[float],
    next_min: Optional[float],
    ren_share_pct: Optional[float],
) -> Tuple[str, bool, bool]:
    """-> (grid_price_posture, wasted_energy_available, next_window_negative).

    Pure. posture in
    {negative-price, curtailed-renewable, cheap, normal, expensive, unknown}."""
    window_ahead = next_min is not None and next_min < 0
    if price_now is not None and price_now < 0:
        return "negative-price", True, window_ahead       # grid PAYING to offload
    if ren_share_pct is not None and ren_share_pct >= _CURTAILMENT_REN_PCT:
        return "curtailed-renewable", True, window_ahead  # clean power > demand
    if price_now is not None and price_now < _CHEAP_EUR_MWH:
        return "cheap", False, window_ahead
    if price_now is not None and price_now > _EXPENSIVE_EUR_MWH:
        return "expensive", False, window_ahead
    if price_now is not None or ren_share_pct is not None:
        return "normal", False, window_ahead
    return "unknown", False, window_ahead


def harvest_status(allow_network: bool = True, timeout: float = 8.0,
                   force: bool = False) -> Dict[str, Any]:
    """Live wasted-energy harvest posture from real public grid feeds.

    Cached for _HARVEST_TTL so callers stay cheap. With allow_network=False it
    serves the last cache (or an honest 'not-probed' if none). NEVER fabricates:
    a down feed is reported 'unreachable' and simply doesn't drive the posture."""
    now = time.time()
    cached = _HARVEST_CACHE.get("data")
    if cached is not None and not force and (now - float(_HARVEST_CACHE["ts"])) < _HARVEST_TTL:
        out = dict(cached); out["cached"] = True; return out
    if not allow_network:
        if cached is not None:
            out = dict(cached); out["cached"] = True; return out
        return {
            "status": "not-probed", "grid_price_posture": "unknown",
            "wasted_energy_available": False, "next_window_negative": False,
            "energy_source": "free-public-grid-feeds", "joules_label": "sample",
            "sovereign": False, "note": "offline: no network probe performed",
        }

    awattar = _fetch_awattar(timeout)
    ren = _fetch_ren_share_de(timeout)
    carbon = _fetch_uk_carbon(timeout)
    price_now = awattar.get("price_now") if awattar.get("status") == "live" else None
    next_min = awattar.get("next_min") if awattar.get("status") == "live" else None
    ren_pct = ren.get("renewable_share_pct") if ren.get("status") == "live" else None
    posture, wasted, window_ahead = _classify_harvest(price_now, next_min, ren_pct)
    any_live = any(s.get("status") == "live" for s in (awattar, ren, carbon))

    data = {
        "status": "live" if any_live else "unreachable",
        "grid_price_posture": posture,
        "wasted_energy_available": wasted,
        "next_window_negative": window_ahead,
        "energy_source": "free-public-grid-feeds",
        "joules_label": "sample",   # no on-box meter here — MEASURED only via NVML on metal
        "sovereign": False,         # grid data NEVER flips the sovereign label
        "signals": {"wholesale_price": awattar, "renewable_share": ren,
                    "carbon_intensity": carbon},
        "doctrine": ("we soak ALREADY-WASTED grid energy; no free-energy; joules SAMPLE "
                     "until an on-box meter; this grid signal NEVER sets sovereign:true."),
        "ts": now,
        "cached": False,
    }
    _HARVEST_CACHE["ts"] = now
    _HARVEST_CACHE["data"] = data
    return dict(data)


def should_soak_wasted_energy(allow_network: bool = True) -> bool:
    """PROACTIVE/batch admission gate: True only when the grid is effectively
    paying us to absorb load (negative wholesale price) or renewables exceed
    demand (curtailment). Reactive/user turns NEVER consult this — they always
    serve. Fail closed: no soak if we can't read the grid."""
    try:
        return bool(harvest_status(allow_network=allow_network).get("wasted_energy_available"))
    except Exception:  # noqa: BLE001
        return False


def posture_summary(allow_network: bool = True) -> Dict[str, Any]:
    """Compact, honest one-glance posture for the frontend tab."""
    h = harvest_status(allow_network=allow_network)
    sig = h.get("signals") or {}
    wp = sig.get("wholesale_price") or {}
    ren = sig.get("renewable_share") or {}
    carbon = sig.get("carbon_intensity") or {}
    feeds_live = sum(1 for s in (wp, ren, carbon) if s.get("status") == "live")
    return {
        "status": h.get("status"),
        "grid_price_posture": h.get("grid_price_posture"),
        "wasted_energy_available": h.get("wasted_energy_available"),
        "next_window_negative": h.get("next_window_negative"),
        "should_soak": bool(h.get("wasted_energy_available")),
        "price_now_eur_mwh": wp.get("price_now"),
        "next_min_eur_mwh": wp.get("next_min"),
        "next_negative_windows": wp.get("next_negative_windows"),
        "renewable_share_pct": ren.get("renewable_share_pct"),
        "uk_gco2_per_kwh": carbon.get("gco2_per_kwh"),
        "uk_carbon_index": carbon.get("index"),
        "feeds_live": feeds_live,
        "feeds_total": 3,
        "energy_source": h.get("energy_source"),
        "joules_label": h.get("joules_label"),
        "sovereign": h.get("sovereign"),
        "cached": h.get("cached"),
        "ts": h.get("ts"),
    }

"""
SZL Energy Harvest — operational backend (FastAPI).

Doctrine v11: REAL public GRID DATA under the HONEST "grid" source. Tells us when
the grid is WASTING power (negative wholesale price / curtailed renewables) so we
can soak ALREADY-WASTED energy. No free-energy claims, no greenwashing. This
signal NEVER flips sovereign:true; joules stay SAMPLE until an on-box NVML meter.
Not one of the locked-8. Lambda = Conjecture 1.

Serves BOTH the self-contained tab page (GET /) and the JSON API so a single box
service + one nginx route powers the a11oy.net tab AND any HF/console caller.

Endpoints:
  GET /            self-contained Energy Harvest tab (HTML)
  GET /healthz     liveness
  GET /health      liveness alias
  GET /harvest     full live harvest status (3 feeds + posture)
  GET /posture     compact one-glance posture for the frontend
  GET /fabric      energy/sovereignty posture overlay (honest)
  GET /soak        proactive-batch admission gate boolean
"""
import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse

import engine

app = FastAPI(title="SZL Energy Harvest", version="1.0.0")

# Public read-only grid data — allow both a11oy.net and the HF Space console to read.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET"],
    allow_headers=["*"],
)

DOCTRINE_NOTE = (
    "REAL public grid data under the HONEST 'grid' source. We soak ALREADY-WASTED "
    "energy (negative wholesale price / curtailed renewables); NO free-energy. "
    "joules_label=SAMPLE until an on-box NVML meter; this signal NEVER sets "
    "sovereign:true. NOT one of the locked-8. Lambda = Conjecture 1."
)

_HERE = os.path.dirname(os.path.abspath(__file__))
_INDEX = os.path.join(_HERE, "index.html")


@app.get("/")
def index():
    if os.path.isfile(_INDEX):
        return FileResponse(_INDEX, media_type="text/html")
    return JSONResponse({"service": "szl-energy-harvest", "see": "/harvest"})


@app.get("/health")
@app.get("/healthz")
def healthz():
    return {"status": "ok", "service": "szl-energy-harvest", "doctrine": "v11",
            "kind": "real-public-grid-data", "honesty": DOCTRINE_NOTE}


@app.get("/harvest")
def harvest():
    out = engine.harvest_status(allow_network=True)
    out["honesty"] = DOCTRINE_NOTE
    return out


@app.get("/posture")
def posture():
    out = engine.posture_summary(allow_network=True)
    out["honesty"] = DOCTRINE_NOTE
    return out


@app.get("/soak")
def soak():
    return {"should_soak": engine.should_soak_wasted_energy(allow_network=True),
            "honesty": DOCTRINE_NOTE}


def _g(name, val, help_, typ="gauge"):
    if val is None:
        return ""
    return (
        "# HELP %s %s\n# TYPE %s %s\n%s %s\n"
        % (name, help_, name, typ, name, val)
    )


@app.get("/metrics")
def metrics():
    """Honest Prometheus exposition. Gauges are derived ONLY from the live grid
    signal — no fabricated joules, no sovereign claim. joules stay SAMPLE."""
    try:
        p = engine.posture_summary(allow_network=True)
    except Exception:
        p = {}
    wasted = 1 if p.get("wasted_energy_available") else 0
    body = "".join([
        _g("szl_energy_harvest_up", 1, "Energy-harvest backend is serving."),
        _g("szl_energy_harvest_feeds_live", p.get("feeds_live"),
           "Number of grid feeds returning live 200 data this scrape."),
        _g("szl_energy_harvest_feeds_total", p.get("feeds_total"),
           "Number of grid feeds queried."),
        _g("szl_energy_harvest_wasted_energy", wasted,
           "1 when a real wasted-energy window is open per live feeds, else 0."),
        _g("szl_energy_harvest_grid_price_eur_mwh", p.get("price_now_eur_mwh"),
           "Live wholesale grid price (EUR/MWh); negative = grid paying to offload."),
        _g("szl_energy_harvest_renewable_share_pct", p.get("renewable_share_pct"),
           "Live renewable generation share (%)."),
        _g("szl_energy_harvest_uk_gco2_per_kwh", p.get("uk_gco2_per_kwh"),
           "Live UK carbon intensity (gCO2/kWh)."),
        _g("szl_energy_harvest_sovereign", 0,
           "Always 0 — this signal NEVER sets sovereign:true (doctrine v11)."),
        _g("szl_energy_harvest_joules_sample", 1,
           "1 = joules are SAMPLE (no on-box NVML meter yet), never measured here."),
    ])
    return PlainTextResponse(body, media_type="text/plain; version=0.0.4")


@app.get("/fabric")
def fabric():
    h = engine.harvest_status(allow_network=True)
    wasted = bool(h.get("wasted_energy_available"))
    # Honest fabric overlay: this service knows ONLY the grid signal. It never
    # claims a sovereign node is up (that lives in the sovereign-compute layer).
    display_state = "HARVESTING" if wasted else "STANDBY"
    return {
        "display_state": display_state,
        "wasted_energy_available": wasted,
        "grid_price_posture": h.get("grid_price_posture"),
        "energy_source": h.get("energy_source"),
        "joules_label": h.get("joules_label"),
        "sovereign": False,
        "note": ("HARVESTING = a real wasted-energy window is open per live grid feeds; "
                 "sovereign status is owned by the sovereign-compute layer, not this signal."),
        "honesty": DOCTRINE_NOTE,
    }

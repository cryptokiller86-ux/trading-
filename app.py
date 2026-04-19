import logging
import threading
import time
from datetime import datetime, timezone
from flask import Flask, jsonify, render_template
from flask_cors import CORS
from apscheduler.schedulers.background import BackgroundScheduler
from signals import generate_signal

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)
CORS(app)

# In-memory cache: last computed signals
_cache: dict = {}
_cache_lock = threading.Lock()
_loading: dict = {"GOLD": False, "BTC": False}


def refresh_signal(asset_key: str):
    """Fetch fresh signal and store in cache."""
    _loading[asset_key] = True
    try:
        logger.info("Refreshing signal for %s …", asset_key)
        result = generate_signal(asset_key)
        with _cache_lock:
            _cache[asset_key] = result
        logger.info("Signal for %s: %s (score %s)", asset_key, result["direction"], result["score"])
    except Exception as e:
        logger.error("Error refreshing %s: %s", asset_key, e)
        with _cache_lock:
            if asset_key not in _cache:
                _cache[asset_key] = {"error": str(e), "asset": asset_key}
    finally:
        _loading[asset_key] = False


def refresh_all():
    """Refresh both assets in parallel threads."""
    threads = [
        threading.Thread(target=refresh_signal, args=("GOLD",), daemon=True),
        threading.Thread(target=refresh_signal, args=("BTC",),  daemon=True),
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


# ── Routes ──────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/signals")
def api_signals():
    """Return cached signals for both assets."""
    with _cache_lock:
        data = dict(_cache)
    return jsonify({
        "signals": data,
        "server_time": datetime.now(timezone.utc).isoformat(),
        "loading": dict(_loading),
    })


@app.route("/api/signals/<asset_key>")
def api_signal_asset(asset_key: str):
    asset_key = asset_key.upper()
    if asset_key not in ("GOLD", "BTC"):
        return jsonify({"error": "Unknown asset. Use GOLD or BTC"}), 404
    with _cache_lock:
        data = _cache.get(asset_key)
    if not data:
        return jsonify({"error": "Signal not ready yet", "loading": _loading.get(asset_key)}), 202
    return jsonify(data)


@app.route("/api/refresh/<asset_key>", methods=["POST"])
def api_force_refresh(asset_key: str):
    asset_key = asset_key.upper()
    if asset_key not in ("GOLD", "BTC"):
        return jsonify({"error": "Unknown asset"}), 404
    if _loading.get(asset_key):
        return jsonify({"message": "Already loading…"}), 202
    t = threading.Thread(target=refresh_signal, args=(asset_key,), daemon=True)
    t.start()
    return jsonify({"message": f"Refresh started for {asset_key}"}), 202


# ── Startup ──────────────────────────────────────────────────────────────────

def start_scheduler():
    scheduler = BackgroundScheduler(timezone="UTC")
    # Refresh every hour at :00
    scheduler.add_job(refresh_all, "cron", minute=0, id="hourly_refresh")
    # Also refresh every 5 minutes for live price updates
    scheduler.add_job(refresh_all, "interval", minutes=5, id="live_price")
    scheduler.start()
    logger.info("Scheduler started — signals refresh every 5 min, full analysis every hour.")


if __name__ == "__main__":
    logger.info("Loading initial signals…")
    # Load initial data in background so server starts immediately
    t = threading.Thread(target=refresh_all, daemon=True)
    t.start()
    start_scheduler()
    app.run(host="0.0.0.0", port=5000, debug=False)

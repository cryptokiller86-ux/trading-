"""
Central configuration — loaded from environment variables (.env file).
"""
import os
from dotenv import load_dotenv

load_dotenv()

# ── Telegram ──────────────────────────────────────────────────────────────────
TELEGRAM_API_ID    = int(os.environ["TELEGRAM_API_ID"])
TELEGRAM_API_HASH  = os.environ["TELEGRAM_API_HASH"]
TELEGRAM_PHONE     = os.environ["TELEGRAM_PHONE"]          # e.g. +33612345678
TELEGRAM_SESSION   = os.getenv("TELEGRAM_SESSION", "yasso_session")

# Group to monitor (username or invite link)
TELEGRAM_GROUP     = os.getenv("TELEGRAM_GROUP", "TheYassoGroup")

# ── MetaTrader 5 ──────────────────────────────────────────────────────────────
MT5_LOGIN          = int(os.environ["MT5_LOGIN"])
MT5_PASSWORD       = os.environ["MT5_PASSWORD"]
MT5_SERVER         = os.getenv("MT5_SERVER", "PUPrime-Live")
MT5_PATH           = os.getenv("MT5_PATH", "")  # leave empty for auto-detect

# ── Trade settings ────────────────────────────────────────────────────────────
DEFAULT_LOT_SIZE   = float(os.getenv("DEFAULT_LOT_SIZE", "0.01"))
MAX_LOT_SIZE       = float(os.getenv("MAX_LOT_SIZE", "1.0"))
SLIPPAGE           = int(os.getenv("SLIPPAGE", "10"))
MAGIC_NUMBER       = int(os.getenv("MAGIC_NUMBER", "20250510"))

# Take only TP1 by default; set to 0 to trade all TPs (separate positions)
MAX_TP_COUNT       = int(os.getenv("MAX_TP_COUNT", "1"))

# ── Risk management ───────────────────────────────────────────────────────────
USE_RISK_PERCENT   = os.getenv("USE_RISK_PERCENT", "false").lower() == "true"
RISK_PERCENT       = float(os.getenv("RISK_PERCENT", "1.0"))  # % of balance per trade

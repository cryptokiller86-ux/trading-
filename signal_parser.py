"""
Parse trading signals from raw Telegram message text.

Handles formats commonly used in signal groups:

  XAUUSD BUY
  Entry: 1920.00 - 1922.00
  SL: 1915.00
  TP1: 1930.00
  TP2: 1940.00
  TP3: 1950.00

  🟢 EURUSD SELL NOW
  📍 Entry: 1.0850
  🛑 SL: 1.0880
  🎯 TP1: 1.0820 | TP2: 1.0800

Returns a TradeSignal dataclass or None if the message is not a signal.
"""
import re
import logging
from dataclasses import dataclass, field
from typing import Optional

logger = logging.getLogger(__name__)

# ── Known tradable symbols ────────────────────────────────────────────────────
FOREX_PAIRS = {
    "EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "USDCAD", "USDCHF",
    "NZDUSD", "EURGBP", "EURJPY", "GBPJPY", "AUDJPY", "CADJPY",
    "EURAUD", "EURCAD", "EURCHF", "GBPAUD", "GBPCAD", "GBPCHF",
    "AUDCAD", "AUDCHF", "AUDNZD", "NZDCAD", "NZDCHF", "NZDJPY",
    "CADCHF",
}
COMMODITY_SYMBOLS = {
    "XAUUSD", "XAGUSD", "GOLD", "SILVER",
    "USOIL", "UKOIL", "OIL", "WTI", "BRENT",
    "XAUEUR",
}
CRYPTO_SYMBOLS = {
    "BTCUSD", "ETHUSD", "LTCUSD", "XRPUSD",
    "BTCUSDT", "ETHUSDT",
}
INDICES = {
    "US30", "US500", "US100", "NAS100", "SPX500",
    "GER40", "UK100", "JP225", "AUS200",
    "DJ30", "DOW", "NASDAQ",
}

ALL_SYMBOLS = FOREX_PAIRS | COMMODITY_SYMBOLS | CRYPTO_SYMBOLS | INDICES

# Aliases → canonical MT5 symbol
SYMBOL_ALIASES = {
    "GOLD":   "XAUUSD",
    "SILVER": "XAGUSD",
    "OIL":    "USOIL",
    "WTI":    "USOIL",
    "BRENT":  "UKOIL",
    "DOW":    "US30",
    "DJ30":   "US30",
    "NASDAQ": "US100",
    "NAS100": "US100",
}


@dataclass
class TradeSignal:
    symbol: str
    direction: str          # "BUY" or "SELL"
    entry_min: float
    entry_max: float        # == entry_min when single value
    sl: float
    tps: list = field(default_factory=list)   # [tp1, tp2, ...]
    raw_text: str = ""

    @property
    def entry(self) -> float:
        """Mid-point of entry zone."""
        return (self.entry_min + self.entry_max) / 2


# ── Regex patterns ────────────────────────────────────────────────────────────
_PRICE = r"[\d][\d\s]*(?:[.,]\d+)?"  # matches  1920.50  or  1 920,50

_SYM_PAT = r"\b(" + "|".join(sorted(ALL_SYMBOLS, key=len, reverse=True)) + r")\b"
_DIR_PAT  = r"\b(BUY|SELL)\b"

# Entry: 1920.00 - 1922.00  or  Entry: 1920.00
_ENTRY_PAT = re.compile(
    r"(?:entry|buy\s*(?:zone|range|limit|now)|sell\s*(?:zone|range|limit|now)|price)"
    r"\s*[:\-]?\s*"
    r"([\d,.\s]+)"
    r"(?:\s*[-–]\s*([\d,.\s]+))?",
    re.IGNORECASE,
)

# SL: 1915.00
_SL_PAT = re.compile(
    r"(?:sl|stop\s*loss|stop)\s*[:\-]?\s*([\d,.\s]+)",
    re.IGNORECASE,
)

# TP1: 1925.00  TP2: 1930  or  TP: 1925
_TP_PAT = re.compile(
    r"(?:tp|take\s*profit|target)\s*\d*\s*[:\-]?\s*([\d,.\s]+)",
    re.IGNORECASE,
)


def _clean_price(raw: str) -> Optional[float]:
    """Convert a raw price string to float, handling spaces and commas."""
    cleaned = raw.strip().replace(" ", "").replace(",", ".")
    try:
        return float(cleaned)
    except ValueError:
        return None


def _resolve_symbol(raw: str) -> str:
    sym = raw.upper().strip()
    return SYMBOL_ALIASES.get(sym, sym)


def _has_signal_keywords(text: str) -> bool:
    """Quick pre-filter: message must look like a trade signal."""
    t = text.upper()
    has_direction = bool(re.search(r"\b(BUY|SELL)\b", t))
    has_price_keyword = bool(re.search(
        r"\b(SL|STOP|TP|TAKE\s*PROFIT|TARGET|ENTRY)\b", t
    ))
    has_symbol = bool(re.search(_SYM_PAT, t))
    return has_direction and (has_price_keyword or has_symbol)


def parse_signal(text: str) -> Optional[TradeSignal]:
    """
    Return a TradeSignal if the message is a valid trade signal, else None.
    """
    if not text or len(text) < 10:
        return None

    text_clean = re.sub(r"[^\w\s.,:\-/|+%@#!$€£°]", " ", text)

    if not _has_signal_keywords(text_clean):
        return None

    # ── Symbol ────────────────────────────────────────────────────────────────
    sym_match = re.search(_SYM_PAT, text_clean.upper())
    if not sym_match:
        return None
    symbol = _resolve_symbol(sym_match.group(1))

    # ── Direction ─────────────────────────────────────────────────────────────
    dir_match = re.search(_DIR_PAT, text_clean.upper())
    if not dir_match:
        return None
    direction = dir_match.group(1)

    # ── Entry ─────────────────────────────────────────────────────────────────
    entry_match = _ENTRY_PAT.search(text_clean)
    if entry_match:
        entry_min = _clean_price(entry_match.group(1))
        entry_max_raw = entry_match.group(2)
        entry_max = _clean_price(entry_max_raw) if entry_max_raw else entry_min
    else:
        # Fallback: first numeric value after the symbol/direction line
        numbers = re.findall(r"\b(\d+[.,]\d+)\b", text_clean)
        entry_min = _clean_price(numbers[0]) if numbers else None
        entry_max = entry_min

    if entry_min is None:
        logger.debug("Signal ignored — no entry price found: %s", text[:80])
        return None

    # ── Stop-loss ─────────────────────────────────────────────────────────────
    sl_match = _SL_PAT.search(text_clean)
    sl = _clean_price(sl_match.group(1)) if sl_match else None
    if sl is None:
        logger.debug("Signal ignored — no SL found: %s", text[:80])
        return None

    # ── Take-profits ──────────────────────────────────────────────────────────
    tps = []
    for m in _TP_PAT.finditer(text_clean):
        price = _clean_price(m.group(1))
        if price and price not in tps:
            tps.append(price)

    signal = TradeSignal(
        symbol=symbol,
        direction=direction,
        entry_min=entry_min,
        entry_max=entry_max if entry_max else entry_min,
        sl=sl,
        tps=tps,
        raw_text=text,
    )
    logger.info("Signal parsed: %s %s entry=%.5f sl=%.5f tps=%s",
                signal.symbol, signal.direction, signal.entry, signal.sl, signal.tps)
    return signal

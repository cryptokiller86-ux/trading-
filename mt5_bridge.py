"""
MetaTrader 5 bridge — connects to MT5 (PUPrime) and executes trade signals.

NOTE: MetaTrader5 Python library only works on Windows where MT5 terminal is installed.
"""
import logging
import time
import math
from typing import Optional

import MetaTrader5 as mt5

from config import (
    MT5_LOGIN, MT5_PASSWORD, MT5_SERVER, MT5_PATH,
    DEFAULT_LOT_SIZE, MAX_LOT_SIZE, SLIPPAGE, MAGIC_NUMBER,
    MAX_TP_COUNT, USE_RISK_PERCENT, RISK_PERCENT,
)
from signal_parser import TradeSignal

logger = logging.getLogger(__name__)


# ── Connection ────────────────────────────────────────────────────────────────

def connect() -> bool:
    """Initialize and login to the MT5 terminal."""
    kwargs = {"login": MT5_LOGIN, "password": MT5_PASSWORD, "server": MT5_SERVER}
    if MT5_PATH:
        kwargs["path"] = MT5_PATH

    if not mt5.initialize(**kwargs):
        logger.error("MT5 initialize failed: %s", mt5.last_error())
        return False

    info = mt5.account_info()
    if info is None:
        logger.error("MT5 login failed: %s", mt5.last_error())
        mt5.shutdown()
        return False

    logger.info(
        "MT5 connected | Account: %s | Balance: %.2f %s | Server: %s",
        info.login, info.balance, info.currency, info.server,
    )
    return True


def disconnect():
    mt5.shutdown()
    logger.info("MT5 disconnected.")


# ── Symbol helpers ────────────────────────────────────────────────────────────

def _resolve_mt5_symbol(symbol: str) -> Optional[str]:
    """
    Find the exact symbol name as listed in MT5 (broker may add suffixes
    like 'XAUUSDm', 'GOLD.', etc.).
    """
    # Try exact match first
    info = mt5.symbol_info(symbol)
    if info is not None:
        mt5.symbol_select(symbol, True)
        return symbol

    # Try common broker suffixes / prefixes
    candidates = [
        symbol + "m", symbol + ".", symbol + "+",
        symbol + "_", "m" + symbol,
    ]
    for c in candidates:
        info = mt5.symbol_info(c)
        if info is not None:
            mt5.symbol_select(c, True)
            logger.info("Symbol %s resolved to %s", symbol, c)
            return c

    # Search in all symbols
    all_symbols = mt5.symbols_get()
    if all_symbols:
        for s in all_symbols:
            if symbol in s.name:
                mt5.symbol_select(s.name, True)
                logger.info("Symbol %s resolved to %s", symbol, s.name)
                return s.name

    logger.warning("Symbol %s not found in MT5.", symbol)
    return None


def _get_lot_size(symbol: str, sl_pips: float) -> float:
    """
    Calculate lot size.
    If USE_RISK_PERCENT: risk a % of balance based on SL distance.
    Otherwise: return DEFAULT_LOT_SIZE.
    """
    if not USE_RISK_PERCENT or sl_pips <= 0:
        return DEFAULT_LOT_SIZE

    account = mt5.account_info()
    if account is None:
        return DEFAULT_LOT_SIZE

    balance = account.balance
    risk_amount = balance * (RISK_PERCENT / 100.0)

    sym_info = mt5.symbol_info(symbol)
    if sym_info is None:
        return DEFAULT_LOT_SIZE

    tick_value  = sym_info.trade_tick_value   # value of 1 tick per lot
    tick_size   = sym_info.trade_tick_size

    if tick_size == 0 or tick_value == 0:
        return DEFAULT_LOT_SIZE

    pip_value_per_lot = tick_value * (sl_pips / tick_size)
    if pip_value_per_lot == 0:
        return DEFAULT_LOT_SIZE

    lot = risk_amount / pip_value_per_lot
    lot = max(sym_info.volume_min, min(MAX_LOT_SIZE, lot))
    # Round to lot step
    step = sym_info.volume_step
    lot = math.floor(lot / step) * step
    return round(lot, 2)


# ── Order execution ───────────────────────────────────────────────────────────

def _send_order(
    symbol: str,
    order_type: int,
    lot: float,
    price: float,
    sl: float,
    tp: float,
    comment: str = "YassoBot",
) -> Optional[mt5.TradeResult]:
    request = {
        "action":   mt5.TRADE_ACTION_DEAL,
        "symbol":   symbol,
        "volume":   lot,
        "type":     order_type,
        "price":    price,
        "sl":       sl,
        "tp":       tp,
        "slippage": SLIPPAGE,
        "magic":    MAGIC_NUMBER,
        "comment":  comment,
        "type_time":    mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }

    result = mt5.order_send(request)

    if result is None:
        logger.error("order_send returned None: %s", mt5.last_error())
        return None

    if result.retcode != mt5.TRADE_RETCODE_DONE:
        logger.error(
            "Order failed | retcode=%s | symbol=%s | %s",
            result.retcode, symbol, result.comment,
        )
        return None

    logger.info(
        "Order DONE | ticket=%s | symbol=%s | type=%s | lot=%.2f | price=%.5f | sl=%.5f | tp=%.5f",
        result.order, symbol,
        "BUY" if order_type == mt5.ORDER_TYPE_BUY else "SELL",
        lot, result.price, sl, tp,
    )
    return result


def _normalize_price(symbol: str, price: float) -> float:
    """Round price to symbol's tick size."""
    info = mt5.symbol_info(symbol)
    if info is None:
        return price
    digits = info.digits
    return round(price, digits)


def execute_signal(signal: TradeSignal) -> list:
    """
    Execute a TradeSignal on MT5.
    Returns list of ticket IDs for opened positions.
    """
    mt5_symbol = _resolve_mt5_symbol(signal.symbol)
    if mt5_symbol is None:
        logger.error("Cannot trade %s — symbol not found in MT5.", signal.symbol)
        return []

    tick = mt5.symbol_info_tick(mt5_symbol)
    if tick is None:
        logger.error("Cannot get tick for %s.", mt5_symbol)
        return []

    # Use market price (entry from signal is advisory for limit orders;
    # here we use immediate market execution)
    if signal.direction == "BUY":
        order_type = mt5.ORDER_TYPE_BUY
        price = tick.ask
    else:
        order_type = mt5.ORDER_TYPE_SELL
        price = tick.bid

    sl = _normalize_price(mt5_symbol, signal.sl)

    # SL distance in price units
    sl_distance = abs(price - sl)
    lot = _get_lot_size(mt5_symbol, sl_distance)

    # Determine which TPs to use
    tps_to_use = signal.tps[:MAX_TP_COUNT] if signal.tps else [0.0]

    tickets = []
    for tp_price in tps_to_use:
        tp = _normalize_price(mt5_symbol, tp_price) if tp_price else 0.0

        # Brief pause between orders
        if tickets:
            time.sleep(0.5)

        result = _send_order(
            symbol=mt5_symbol,
            order_type=order_type,
            lot=lot,
            price=price,
            sl=sl,
            tp=tp,
            comment=f"YassoBot {signal.direction}",
        )
        if result:
            tickets.append(result.order)

    return tickets


# ── Convenience check ─────────────────────────────────────────────────────────

def is_market_open(symbol: str) -> bool:
    """Return True if the market is currently open for trading."""
    mt5_symbol = _resolve_mt5_symbol(symbol)
    if mt5_symbol is None:
        return False
    info = mt5.symbol_info(mt5_symbol)
    if info is None:
        return False
    # trade_mode 0 = disabled, 4 = full access
    return info.trade_mode != mt5.SYMBOL_TRADE_MODE_DISABLED

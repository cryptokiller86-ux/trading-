import yfinance as yf
import pandas as pd
import numpy as np
from datetime import datetime, timezone
import requests
import logging

logger = logging.getLogger(__name__)

ASSETS = {
    "GOLD": {"ticker": "GC=F", "name": "Gold (XAU/USD)", "pip": 0.1},
    "BTC":  {"ticker": "BTC-USD", "name": "Bitcoin (BTC/USD)", "pip": 1.0},
}


def fetch_ohlcv(ticker: str, period: str = "5d", interval: str = "1h") -> pd.DataFrame:
    """Download OHLCV data from Yahoo Finance."""
    try:
        df = yf.download(ticker, period=period, interval=interval, progress=False, auto_adjust=True)
        if df.empty:
            raise ValueError(f"No data for {ticker}")
        df.columns = [c[0] if isinstance(c, tuple) else c for c in df.columns]
        df = df[["Open", "High", "Low", "Close", "Volume"]].dropna()
        return df
    except Exception as e:
        logger.error("fetch_ohlcv error: %s", e)
        raise


def _ema(series: pd.Series, period: int) -> pd.Series:
    return series.ewm(span=period, adjust=False).mean()


def _rsi(series: pd.Series, period: int = 14) -> pd.Series:
    delta = series.diff()
    gain = delta.clip(lower=0)
    loss = -delta.clip(upper=0)
    avg_gain = gain.ewm(com=period - 1, adjust=False).mean()
    avg_loss = loss.ewm(com=period - 1, adjust=False).mean()
    rs = avg_gain / avg_loss.replace(0, np.nan)
    return 100 - (100 / (1 + rs))


def _macd(series: pd.Series, fast=12, slow=26, signal=9):
    ema_fast = _ema(series, fast)
    ema_slow = _ema(series, slow)
    macd_line = ema_fast - ema_slow
    signal_line = _ema(macd_line, signal)
    histogram = macd_line - signal_line
    return macd_line, signal_line, histogram


def _bollinger(series: pd.Series, period=20, std_dev=2):
    sma = series.rolling(period).mean()
    std = series.rolling(period).std()
    upper = sma + std_dev * std
    lower = sma - std_dev * std
    return upper, sma, lower


def _atr(high: pd.Series, low: pd.Series, close: pd.Series, period=14) -> pd.Series:
    prev_close = close.shift(1)
    tr = pd.concat([
        high - low,
        (high - prev_close).abs(),
        (low - prev_close).abs()
    ], axis=1).max(axis=1)
    return tr.ewm(com=period - 1, adjust=False).mean()


def _stoch_rsi(rsi: pd.Series, period=14) -> pd.Series:
    min_rsi = rsi.rolling(period).min()
    max_rsi = rsi.rolling(period).max()
    denom = (max_rsi - min_rsi).replace(0, np.nan)
    return (rsi - min_rsi) / denom * 100


def compute_indicators(df: pd.DataFrame) -> pd.DataFrame:
    close = df["Close"]
    high  = df["High"]
    low   = df["Low"]

    df["ema9"]   = _ema(close, 9)
    df["ema21"]  = _ema(close, 21)
    df["ema50"]  = _ema(close, 50)
    df["ema200"] = _ema(close, 200)

    df["rsi"] = _rsi(close, 14)
    df["stoch_rsi"] = _stoch_rsi(df["rsi"], 14)

    df["macd"], df["macd_signal"], df["macd_hist"] = _macd(close)

    df["bb_upper"], df["bb_mid"], df["bb_lower"] = _bollinger(close, 20, 2)
    df["bb_width"] = (df["bb_upper"] - df["bb_lower"]) / df["bb_mid"]

    df["atr"] = _atr(high, low, close, 14)

    df["vol_sma"] = df["Volume"].rolling(20).mean()
    df["vol_ratio"] = df["Volume"] / df["vol_sma"].replace(0, np.nan)

    return df


def _score_signal(row: pd.Series, prev: pd.Series) -> dict:
    """
    Score based on confluence of indicators.
    Returns {"direction": "BUY"|"SELL"|"NEUTRAL", "score": int, "reasons": []}
    """
    buy_score  = 0
    sell_score = 0
    reasons_buy  = []
    reasons_sell = []

    close = float(row["Close"])

    # --- RSI ---
    rsi = float(row["rsi"])
    if rsi < 35:
        buy_score += 2
        reasons_buy.append(f"RSI survendu ({rsi:.1f})")
    elif rsi < 45:
        buy_score += 1
        reasons_buy.append(f"RSI bas ({rsi:.1f})")
    elif rsi > 65:
        sell_score += 2
        reasons_sell.append(f"RSI suracheté ({rsi:.1f})")
    elif rsi > 55:
        sell_score += 1
        reasons_sell.append(f"RSI haut ({rsi:.1f})")

    # --- Stoch RSI ---
    srsi = float(row["stoch_rsi"]) if not np.isnan(row["stoch_rsi"]) else 50
    if srsi < 20:
        buy_score += 2
        reasons_buy.append(f"StochRSI survendu ({srsi:.1f})")
    elif srsi > 80:
        sell_score += 2
        reasons_sell.append(f"StochRSI suracheté ({srsi:.1f})")

    # --- MACD crossover ---
    macd_h  = float(row["macd_hist"])
    p_macd_h = float(prev["macd_hist"]) if not np.isnan(prev["macd_hist"]) else 0
    if p_macd_h < 0 and macd_h > 0:
        buy_score += 3
        reasons_buy.append("MACD croisement haussier")
    elif p_macd_h > 0 and macd_h < 0:
        sell_score += 3
        reasons_sell.append("MACD croisement baissier")
    elif macd_h > 0 and macd_h > p_macd_h:
        buy_score += 1
        reasons_buy.append("MACD histogramme haussier")
    elif macd_h < 0 and macd_h < p_macd_h:
        sell_score += 1
        reasons_sell.append("MACD histogramme baissier")

    # --- EMA trend ---
    ema9  = float(row["ema9"])
    ema21 = float(row["ema21"])
    ema50 = float(row["ema50"])
    if close > ema50 and ema9 > ema21:
        buy_score += 2
        reasons_buy.append("Tendance haussière (EMA 9>21, prix>EMA50)")
    elif close < ema50 and ema9 < ema21:
        sell_score += 2
        reasons_sell.append("Tendance baissière (EMA 9<21, prix<EMA50)")

    if close > ema9 > ema21 > ema50:
        buy_score += 1
        reasons_buy.append("Alignement EMA haussier parfait")
    elif close < ema9 < ema21 < ema50:
        sell_score += 1
        reasons_sell.append("Alignement EMA baissier parfait")

    # --- Bollinger Bands ---
    bb_upper = float(row["bb_upper"])
    bb_lower = float(row["bb_lower"])
    bb_mid   = float(row["bb_mid"])
    bb_pct   = (close - bb_lower) / (bb_upper - bb_lower) if (bb_upper - bb_lower) != 0 else 0.5

    if bb_pct < 0.15:
        buy_score += 2
        reasons_buy.append("Prix proche bande BB inférieure")
    elif bb_pct < 0.30:
        buy_score += 1
        reasons_buy.append("Prix dans zone BB basse")
    elif bb_pct > 0.85:
        sell_score += 2
        reasons_sell.append("Prix proche bande BB supérieure")
    elif bb_pct > 0.70:
        sell_score += 1
        reasons_sell.append("Prix dans zone BB haute")

    # --- Volume confirmation ---
    vol_ratio = float(row["vol_ratio"]) if not np.isnan(row["vol_ratio"]) else 1.0
    if vol_ratio > 1.5:
        if buy_score >= sell_score:
            buy_score += 1
            reasons_buy.append(f"Volume élevé x{vol_ratio:.1f}")
        else:
            sell_score += 1
            reasons_sell.append(f"Volume élevé x{vol_ratio:.1f}")

    # --- Decision ---
    if buy_score >= 5 and buy_score > sell_score + 1:
        return {"direction": "BUY", "score": buy_score, "reasons": reasons_buy}
    elif sell_score >= 5 and sell_score > buy_score + 1:
        return {"direction": "SELL", "score": sell_score, "reasons": reasons_sell}
    else:
        all_reasons = reasons_buy if buy_score >= sell_score else reasons_sell
        return {"direction": "NEUTRAL", "score": max(buy_score, sell_score), "reasons": all_reasons}


def _strength_label(score: int) -> str:
    if score >= 9:
        return "FORT"
    elif score >= 7:
        return "MODÉRÉ"
    return "FAIBLE"


def generate_signal(asset_key: str) -> dict:
    """Main function: fetch data, compute indicators, generate signal with SL/TP."""
    asset = ASSETS[asset_key]
    ticker = asset["ticker"]

    df = fetch_ohlcv(ticker, period="10d", interval="1h")
    df = compute_indicators(df)
    df = df.dropna(subset=["rsi", "macd", "atr", "ema50"])

    if len(df) < 3:
        raise ValueError("Not enough data")

    row  = df.iloc[-1]
    prev = df.iloc[-2]

    signal_info = _score_signal(row, prev)
    direction   = signal_info["direction"]
    score       = signal_info["score"]

    entry  = float(row["Close"])
    atr    = float(row["atr"])
    ema50  = float(row["ema50"])
    ema200 = float(row["ema200"])

    # SL/TP based on ATR with structure-aware adjustment
    atr_sl  = atr * 1.8
    atr_tp1 = atr * 1.5
    atr_tp2 = atr * 3.2

    if direction == "BUY":
        # SL below recent low + ATR buffer
        recent_low = float(df["Low"].iloc[-5:].min())
        sl  = min(entry - atr_sl, recent_low - atr * 0.5)
        tp1 = entry + atr_tp1
        tp2 = entry + atr_tp2
        risk = entry - sl
    elif direction == "SELL":
        # SL above recent high + ATR buffer
        recent_high = float(df["High"].iloc[-5:].max())
        sl  = max(entry + atr_sl, recent_high + atr * 0.5)
        tp1 = entry - atr_tp1
        tp2 = entry - atr_tp2
        risk = sl - entry
    else:
        sl  = entry - atr_sl
        tp1 = entry + atr_tp1
        tp2 = entry + atr_tp2
        risk = atr_sl

    rr1 = abs(tp1 - entry) / risk if risk > 0 else 0
    rr2 = abs(tp2 - entry) / risk if risk > 0 else 0

    # Price precision
    decimals = 2 if asset_key == "BTC" else 2

    def fmt(v):
        return round(float(v), decimals)

    # Recent price history for chart (last 48 candles)
    history = []
    for ts, r in df.iloc[-48:].iterrows():
        history.append({
            "time": int(pd.Timestamp(ts).timestamp()),
            "open":  fmt(r["Open"]),
            "high":  fmt(r["High"]),
            "low":   fmt(r["Low"]),
            "close": fmt(r["Close"]),
            "volume": float(r["Volume"]),
        })

    # Key indicators for display
    indicators = {
        "rsi":        round(float(row["rsi"]), 1),
        "stoch_rsi":  round(float(row["stoch_rsi"]) if not np.isnan(row["stoch_rsi"]) else 50, 1),
        "macd":       round(float(row["macd"]), 4),
        "macd_signal":round(float(row["macd_signal"]), 4),
        "macd_hist":  round(float(row["macd_hist"]), 4),
        "ema9":       fmt(row["ema9"]),
        "ema21":      fmt(row["ema21"]),
        "ema50":      fmt(row["ema50"]),
        "ema200":     fmt(row["ema200"]),
        "bb_upper":   fmt(row["bb_upper"]),
        "bb_mid":     fmt(row["bb_mid"]),
        "bb_lower":   fmt(row["bb_lower"]),
        "atr":        round(float(row["atr"]), 4),
        "vol_ratio":  round(float(row["vol_ratio"]) if not np.isnan(row["vol_ratio"]) else 1.0, 2),
        "trend":      "HAUSSIER" if float(row["ema9"]) > float(row["ema21"]) > float(row["ema50"]) else
                      "BAISSIER" if float(row["ema9"]) < float(row["ema21"]) < float(row["ema50"]) else
                      "NEUTRE",
    }

    return {
        "asset":      asset_key,
        "name":       asset["name"],
        "direction":  direction,
        "strength":   _strength_label(score),
        "score":      score,
        "entry":      fmt(entry),
        "sl":         fmt(sl),
        "tp1":        fmt(tp1),
        "tp2":        fmt(tp2),
        "risk_reward_tp1": round(rr1, 2),
        "risk_reward_tp2": round(rr2, 2),
        "risk_pips":  fmt(risk),
        "reasons":    signal_info["reasons"],
        "indicators": indicators,
        "history":    history,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "next_update": "Prochain signal dans ~60 min",
    }

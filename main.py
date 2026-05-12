"""
Entry point — wires together Telegram listener, signal parser, and MT5 bridge.

Run:
    python main.py

On first run Telethon will ask for the SMS/Telegram code to authenticate
your account. The session is then saved locally so subsequent runs are silent.
"""
import asyncio
import logging
import sys

from config import TELEGRAM_GROUP
from signal_parser import parse_signal
from mt5_bridge import connect as mt5_connect, disconnect as mt5_disconnect, execute_signal
from telegram_listener import YassoListener

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("yasso_bot.log", encoding="utf-8"),
    ],
)
logger = logging.getLogger("main")


# ── Signal handler (called for every new Telegram message) ───────────────────

async def on_message(text: str):
    """Parse message and execute on MT5 if it's a valid signal."""
    signal = parse_signal(text)
    if signal is None:
        return  # not a trading signal — ignore

    logger.info(
        "═══ SIGNAL DETECTED ═══\n"
        "  Symbol   : %s\n"
        "  Direction: %s\n"
        "  Entry    : %.5f (%.5f – %.5f)\n"
        "  SL       : %.5f\n"
        "  TPs      : %s",
        signal.symbol, signal.direction,
        signal.entry, signal.entry_min, signal.entry_max,
        signal.sl,
        signal.tps,
    )

    # Execute on MT5 (blocking call — run in thread to not block event loop)
    loop = asyncio.get_event_loop()
    tickets = await loop.run_in_executor(None, execute_signal, signal)

    if tickets:
        logger.info("Positions opened: tickets=%s", tickets)
    else:
        logger.warning("No position was opened for signal: %s %s", signal.symbol, signal.direction)


# ── Main ──────────────────────────────────────────────────────────────────────

async def main():
    logger.info("Starting YassoBot …")

    # Connect to MT5 first
    if not mt5_connect():
        logger.critical("Cannot connect to MT5. Aborting.")
        sys.exit(1)

    logger.info("MT5 connected. Connecting to Telegram group '%s' …", TELEGRAM_GROUP)

    listener = YassoListener(handler=on_message)

    try:
        await listener.start()
    except KeyboardInterrupt:
        logger.info("Interrupted by user.")
    except Exception as e:
        logger.exception("Fatal error: %s", e)
    finally:
        await listener.stop()
        mt5_disconnect()
        logger.info("YassoBot stopped.")


if __name__ == "__main__":
    asyncio.run(main())

"""
Telegram listener using Telethon (user-account client).

Connects to Telegram as YOUR account (not a bot token) so it can read
messages from any group — including private ones — that you are a member of.

The on_message callback receives every new message from the target group.
The signal_parser then decides whether it's a trade signal.
"""
import logging
from typing import Callable, Awaitable

from telethon import TelegramClient, events
from telethon.tl.types import Message

from config import (
    TELEGRAM_API_ID,
    TELEGRAM_API_HASH,
    TELEGRAM_PHONE,
    TELEGRAM_SESSION,
    TELEGRAM_GROUP,
)

logger = logging.getLogger(__name__)

MessageHandler = Callable[[str], Awaitable[None]]


class YassoListener:
    """
    Listens to new messages in TheYassoGroup and calls `handler`
    with the raw message text for every new message.
    """

    def __init__(self, handler: MessageHandler):
        self._handler = handler
        self._client = TelegramClient(
            TELEGRAM_SESSION,
            TELEGRAM_API_ID,
            TELEGRAM_API_HASH,
        )

    async def _on_new_message(self, event: events.NewMessage.Event):
        msg: Message = event.message
        text = msg.message or ""

        if not text.strip():
            return  # ignore media-only messages

        logger.debug("New message from group: %s", text[:120])
        await self._handler(text)

    async def start(self):
        """Connect, resolve the group, and start listening."""
        await self._client.start(phone=TELEGRAM_PHONE)
        logger.info("Telegram client started.")

        # Resolve the group entity
        try:
            entity = await self._client.get_entity(TELEGRAM_GROUP)
            logger.info("Monitoring group: %s (id=%s)", TELEGRAM_GROUP, entity.id)
        except Exception as e:
            logger.error("Cannot resolve group '%s': %s", TELEGRAM_GROUP, e)
            raise

        # Register handler scoped to this group only
        self._client.add_event_handler(
            self._on_new_message,
            events.NewMessage(chats=entity),
        )

        logger.info("Listening for signals in '%s' …", TELEGRAM_GROUP)
        await self._client.run_until_disconnected()

    async def stop(self):
        await self._client.disconnect()
        logger.info("Telegram client disconnected.")

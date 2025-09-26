import logging

LOGGER = logging.getLogger(__name__)


_activities: list[str] = []


def report_activity(text: str) -> None:
    LOGGER.info(f"Activity reported: {text}")
    _activities.append(text)

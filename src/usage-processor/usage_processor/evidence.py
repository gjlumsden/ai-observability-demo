from dataclasses import dataclass
from datetime import datetime, timezone


@dataclass(frozen=True)
class EventEvidence:
    partition_id: str | None = None
    sequence_number: int | None = None
    offset: str | None = None
    enqueued_time: datetime | None = None

    def as_state_properties(self):
        return {
            "EventHubPartition": self.partition_id,
            "EventHubSequenceNumber": self.sequence_number,
            "EventHubOffset": self.offset,
            "EventHubEnqueuedTime": (
                self.enqueued_time.astimezone(timezone.utc).isoformat()
                if self.enqueued_time
                else None
            ),
        }


def extract_event_evidence(event):
    metadata = getattr(event, "metadata", None) or {}
    partition_id = _partition_from_metadata(metadata)
    return EventEvidence(
        partition_id=str(partition_id) if partition_id is not None else None,
        sequence_number=_integer_or_none(getattr(event, "sequence_number", None)),
        offset=_string_or_none(getattr(event, "offset", None)),
        enqueued_time=_datetime_or_none(getattr(event, "enqueued_time", None)),
    )


def archive_prefix(evidence, namespace, event_hub_name, container_name):
    if not evidence.partition_id or not evidence.enqueued_time:
        return None
    timestamp = evidence.enqueued_time.astimezone(timezone.utc)
    namespace_name = (namespace or "").split(".")[0]
    if not namespace_name or not event_hub_name or not container_name:
        return None
    return (
        f"{container_name}/{namespace_name}/{event_hub_name}/"
        f"{evidence.partition_id}/{timestamp:%Y/%m/%d/%H}/"
    )


def _partition_from_metadata(metadata):
    for key in ("PartitionId", "partitionId", "partition_id"):
        if key in metadata:
            return metadata[key]
    context = metadata.get("PartitionContext") or metadata.get("partitionContext")
    if isinstance(context, dict):
        return context.get("PartitionId") or context.get("partitionId")
    return None


def _integer_or_none(value):
    if isinstance(value, bool) or value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _string_or_none(value):
    return None if value is None else str(value)


def _datetime_or_none(value):
    if not isinstance(value, datetime):
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value

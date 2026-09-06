from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
import logging

from azure.core.exceptions import ResourceNotFoundError


CHECKPOINT_CONTAINER_NAME = "azure-webjobs-eventhub"
CHECKPOINT_TRACE_MESSAGE = "UsageProcessorCheckpointStatus"


@dataclass(frozen=True)
class PartitionCheckpointStatus:
    event_hub_name: str
    consumer_group: str
    partition_id: str
    status: str
    checkpoint_age_seconds: int | None
    event_age_seconds: int | None
    checkpoint_sequence_number: int | None
    last_enqueued_sequence_number: int
    sequence_lag: int | None
    checkpoint_last_modified_utc: datetime | None
    last_enqueued_time_utc: datetime | None
    stale_threshold_seconds: int
    idle_threshold_seconds: int

    def telemetry_fields(self):
        return {
            "eventHubName": self.event_hub_name,
            "consumerGroup": self.consumer_group,
            "partitionId": self.partition_id,
            "status": self.status,
            "checkpointAgeSeconds": _optional_number(
                self.checkpoint_age_seconds
            ),
            "eventAgeSeconds": _optional_number(self.event_age_seconds),
            "checkpointSequenceNumber": _optional_number(
                self.checkpoint_sequence_number
            ),
            "lastEnqueuedSequenceNumber": str(
                self.last_enqueued_sequence_number
            ),
            "sequenceLag": _optional_number(self.sequence_lag),
            "checkpointLastModifiedUtc": _optional_timestamp(
                self.checkpoint_last_modified_utc
            ),
            "lastEnqueuedTimeUtc": _optional_timestamp(
                self.last_enqueued_time_utc
            ),
            "staleThresholdSeconds": str(self.stale_threshold_seconds),
            "idleThresholdSeconds": str(self.idle_threshold_seconds),
        }


def monitor_checkpoints(
    *,
    event_hub_client,
    checkpoint_container_client,
    event_hub_namespace,
    event_hub_name,
    consumer_group,
    stale_after,
    idle_after,
    logger=None,
    now=None,
):
    current_time = _as_utc(now or datetime.now(timezone.utc))
    stale_seconds = _positive_seconds(stale_after, "stale_after")
    idle_seconds = _positive_seconds(idle_after, "idle_after")
    telemetry_logger = logger or logging.getLogger(
        "usage_processor.checkpoint_monitor"
    )

    statuses = []
    partition_ids = sorted(
        (str(value) for value in event_hub_client.get_partition_ids()),
        key=_partition_sort_key,
    )
    for partition_id in partition_ids:
        checkpoint = _get_checkpoint(
            checkpoint_container_client,
            checkpoint_blob_name(
                event_hub_namespace,
                event_hub_name,
                consumer_group,
                partition_id,
            ),
        )
        partition = event_hub_client.get_partition_properties(partition_id)
        status = _inspect_partition(
            event_hub_name=event_hub_name,
            consumer_group=consumer_group,
            partition_id=partition_id,
            partition=partition,
            checkpoint=checkpoint,
            stale_seconds=stale_seconds,
            idle_seconds=idle_seconds,
            now=current_time,
        )
        _log_status(telemetry_logger, status)
        statuses.append(status)

    return statuses


def checkpoint_blob_name(
    event_hub_namespace,
    event_hub_name,
    consumer_group,
    partition_id,
):
    return (
        f"{event_hub_namespace.lower()}/{event_hub_name.lower()}/"
        f"{consumer_group.lower()}/checkpoint/{partition_id}"
    )


def _inspect_partition(
    *,
    event_hub_name,
    consumer_group,
    partition_id,
    partition,
    checkpoint,
    stale_seconds,
    idle_seconds,
    now,
):
    is_empty = bool(partition["is_empty"])
    last_sequence = int(partition["last_enqueued_sequence_number"])
    last_enqueued_time = _optional_utc(
        partition.get("last_enqueued_time_utc")
    )
    event_age = _age_seconds(now, last_enqueued_time)

    checkpoint_age = _age_seconds(
        now,
        checkpoint["last_modified"] if checkpoint else None,
    )
    checkpoint_sequence = (
        checkpoint["sequence_number"] if checkpoint else None
    )
    sequence_lag = (
        last_sequence - checkpoint_sequence
        if checkpoint_sequence is not None
        else None
    )

    if sequence_lag is not None and sequence_lag < 0:
        state = "invalid"
    elif is_empty:
        state = "idle"
    elif checkpoint is None:
        state = "missing"
    elif checkpoint_sequence is None:
        state = "invalid"
    elif sequence_lag == 0:
        state = (
            "idle"
            if event_age is not None and event_age >= idle_seconds
            else "healthy"
        )
    elif checkpoint_age is not None and checkpoint_age >= stale_seconds:
        state = "stale"
    else:
        state = "lagging"

    return PartitionCheckpointStatus(
        event_hub_name=event_hub_name,
        consumer_group=consumer_group,
        partition_id=partition_id,
        status=state,
        checkpoint_age_seconds=checkpoint_age,
        event_age_seconds=event_age,
        checkpoint_sequence_number=checkpoint_sequence,
        last_enqueued_sequence_number=last_sequence,
        sequence_lag=sequence_lag,
        checkpoint_last_modified_utc=(
            checkpoint["last_modified"] if checkpoint else None
        ),
        last_enqueued_time_utc=last_enqueued_time,
        stale_threshold_seconds=stale_seconds,
        idle_threshold_seconds=idle_seconds,
    )


def _get_checkpoint(container_client, blob_name):
    try:
        properties = container_client.get_blob_client(
            blob_name
        ).get_blob_properties()
    except ResourceNotFoundError as error:
        error_code = getattr(error, "error_code", None)
        if error_code and error_code != "BlobNotFound":
            raise
        return None

    metadata = properties.metadata or {}
    sequence_number = _parse_sequence_number(
        metadata.get("sequencenumber")
    )
    return {
        "last_modified": _as_utc(properties.last_modified),
        "sequence_number": sequence_number,
    }


def _parse_sequence_number(value):
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _log_status(logger, status):
    payload = json.dumps(
        status.telemetry_fields(),
        separators=(",", ":"),
        sort_keys=True,
    )
    message = f"{CHECKPOINT_TRACE_MESSAGE} {payload}"
    if status.status in {"stale", "missing", "invalid"}:
        logger.warning(message)
    else:
        logger.info(message)


def _positive_seconds(value, name):
    if not isinstance(value, timedelta) or value <= timedelta(0):
        raise ValueError(f"{name} must be a positive timedelta.")
    return int(value.total_seconds())


def _age_seconds(now, value):
    if value is None:
        return None
    return max(0, int((now - _as_utc(value)).total_seconds()))


def _as_utc(value):
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("Checkpoint monitor timestamps must include a timezone.")
    return value.astimezone(timezone.utc)


def _optional_utc(value):
    return _as_utc(value) if value is not None else None


def _optional_number(value):
    return "" if value is None else str(value)


def _optional_timestamp(value):
    return "" if value is None else value.isoformat().replace("+00:00", "Z")


def _partition_sort_key(value):
    return (0, int(value)) if value.isdigit() else (1, value)

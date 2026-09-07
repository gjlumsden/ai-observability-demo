from datetime import datetime, timedelta, timezone
import json
import logging
import unittest

from azure.core.exceptions import ResourceNotFoundError
from azure.storage.blob import BlobProperties

import bootstrap  # noqa: F401

from usage_processor.checkpoint_monitor import (
    CHECKPOINT_TRACE_MESSAGE,
    checkpoint_blob_name,
    monitor_checkpoints,
)
from usage_processor.errors import ConfigurationError
from usage_processor.settings import Settings


NOW = datetime(2026, 9, 6, 18, tzinfo=timezone.utc)
NAMESPACE = "AiObs-Usage.servicebus.windows.net"
EVENT_HUB = "AI-Usage"
CONSUMER_GROUP = "Processor"


def not_found_error(message, error_code):
    error = ResourceNotFoundError(message)
    error.error_code = error_code
    return error


class FakeBlobClient:
    def __init__(self, properties):
        self.properties = properties

    def get_blob_properties(self):
        if isinstance(self.properties, Exception):
            raise self.properties
        if self.properties is None:
            raise not_found_error("checkpoint not found", "BlobNotFound")
        return self.properties


class FakeContainerClient:
    def __init__(self, checkpoints):
        self.checkpoints = checkpoints
        self.requested_names = []

    def get_blob_client(self, name):
        self.requested_names.append(name)
        return FakeBlobClient(self.checkpoints.get(name))


class FakeEventHubClient:
    def __init__(self, partitions):
        self.partitions = partitions

    def get_partition_ids(self):
        return list(self.partitions)

    def get_partition_properties(self, partition_id):
        return self.partitions[partition_id]


class RecordingHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records = []

    def emit(self, record):
        self.records.append(record)


def partition(sequence, event_age_seconds, *, is_empty=False):
    return {
        "is_empty": is_empty,
        "last_enqueued_sequence_number": sequence,
        "last_enqueued_time_utc": (
            None
            if is_empty
            else NOW - timedelta(seconds=event_age_seconds)
        ),
    }


def checkpoint(sequence, age_seconds):
    properties = BlobProperties(
        metadata={
            "offset": str(sequence * 10),
            "sequencenumber": str(sequence),
            "clientidentifier": "processor-instance",
        }
    )
    properties.last_modified = NOW - timedelta(seconds=age_seconds)
    return properties


def run_monitor(partitions, checkpoints):
    handler = RecordingHandler()
    logger = logging.getLogger(
        f"checkpoint-monitor-test-{id(handler)}"
    )
    logger.handlers = [handler]
    logger.propagate = False
    logger.setLevel(logging.INFO)
    container = FakeContainerClient(checkpoints)
    statuses = monitor_checkpoints(
        event_hub_client=FakeEventHubClient(partitions),
        checkpoint_container_client=container,
        event_hub_namespace=NAMESPACE,
        event_hub_name=EVENT_HUB,
        consumer_group=CONSUMER_GROUP,
        stale_after=timedelta(minutes=15),
        idle_after=timedelta(minutes=15),
        logger=logger,
        now=NOW,
    )
    return statuses, handler.records, container


class CheckpointMonitorTests(unittest.TestCase):
    def test_settings_load_checkpoint_defaults_and_required_values(self):
        configured = Settings.from_env(
            {
                "USAGE_STORAGE_BLOB_ENDPOINT": (
                    "https://storage.blob.core.windows.net"
                ),
                "AIUsageEventHub__fullyQualifiedNamespace": NAMESPACE,
                "AI_USAGE_EVENT_HUB_NAME": EVENT_HUB,
                "AI_USAGE_CONSUMER_GROUP": CONSUMER_GROUP,
            }
        )

        configured.require_checkpoint_monitor()
        self.assertEqual(configured.event_hub_consumer_group, CONSUMER_GROUP)
        self.assertEqual(configured.checkpoint_stale_seconds, 900)
        self.assertEqual(configured.checkpoint_idle_seconds, 900)

    def test_settings_reject_nonpositive_checkpoint_threshold(self):
        with self.assertRaisesRegex(
            ConfigurationError,
            "CHECKPOINT_STALE_SECONDS",
        ):
            Settings.from_env({"CHECKPOINT_STALE_SECONDS": "0"})

    def test_uses_official_lowercase_functions_checkpoint_path(self):
        expected = (
            "aiobs-usage.servicebus.windows.net/ai-usage/"
            "processor/checkpoint/7"
        )

        self.assertEqual(
            checkpoint_blob_name(
                NAMESPACE,
                EVENT_HUB,
                CONSUMER_GROUP,
                "7",
            ),
            expected,
        )

    def test_reports_actual_checkpoint_age_and_sequence_lag(self):
        blob_name = checkpoint_blob_name(
            NAMESPACE,
            EVENT_HUB,
            CONSUMER_GROUP,
            "0",
        )

        statuses, records, container = run_monitor(
            {"0": partition(105, 5)},
            {blob_name: checkpoint(100, 120)},
        )

        self.assertEqual(container.requested_names, [blob_name])
        self.assertEqual(statuses[0].status, "lagging")
        self.assertEqual(statuses[0].checkpoint_age_seconds, 120)
        self.assertEqual(statuses[0].sequence_lag, 5)
        prefix, payload = records[0].getMessage().split(" ", 1)
        self.assertEqual(prefix, CHECKPOINT_TRACE_MESSAGE)
        self.assertEqual(
            json.loads(payload)["checkpointAgeSeconds"],
            "120",
        )

    def test_old_caught_up_partition_is_idle_not_stale(self):
        blob_name = checkpoint_blob_name(
            NAMESPACE,
            EVENT_HUB,
            CONSUMER_GROUP,
            "0",
        )

        statuses, records, _ = run_monitor(
            {"0": partition(100, 3600)},
            {blob_name: checkpoint(100, 3600)},
        )

        self.assertEqual(statuses[0].status, "idle")
        self.assertEqual(records[0].levelno, logging.INFO)

    def test_old_checkpoint_with_backlog_is_stale(self):
        blob_name = checkpoint_blob_name(
            NAMESPACE,
            EVENT_HUB,
            CONSUMER_GROUP,
            "0",
        )

        statuses, records, _ = run_monitor(
            {"0": partition(101, 10)},
            {blob_name: checkpoint(100, 901)},
        )

        self.assertEqual(statuses[0].status, "stale")
        self.assertEqual(records[0].levelno, logging.WARNING)

    def test_empty_partition_without_checkpoint_is_idle(self):
        statuses, records, _ = run_monitor(
            {"0": partition(-1, 0, is_empty=True)},
            {},
        )

        self.assertEqual(statuses[0].status, "idle")
        self.assertIsNone(statuses[0].checkpoint_age_seconds)
        self.assertEqual(records[0].levelno, logging.INFO)

    def test_recent_nonempty_partition_without_checkpoint_is_missing(self):
        statuses, records, _ = run_monitor(
            {"0": partition(10, 30)},
            {},
        )

        self.assertEqual(statuses[0].status, "missing")
        self.assertEqual(records[0].levelno, logging.WARNING)

    def test_old_nonempty_partition_without_checkpoint_is_missing(self):
        statuses, records, _ = run_monitor(
            {"0": partition(10, 901)},
            {},
        )

        self.assertEqual(statuses[0].status, "missing")
        self.assertEqual(records[0].levelno, logging.WARNING)

    def test_checkpoint_without_sequence_metadata_is_invalid(self):
        blob_name = checkpoint_blob_name(
            NAMESPACE,
            EVENT_HUB,
            CONSUMER_GROUP,
            "0",
        )
        invalid_checkpoint = BlobProperties(
            metadata={"offset": "", "clientidentifier": "processor-instance"},
        )
        invalid_checkpoint.last_modified = NOW - timedelta(seconds=60)

        statuses, records, _ = run_monitor(
            {"0": partition(10, 30)},
            {blob_name: invalid_checkpoint},
        )

        self.assertEqual(statuses[0].status, "invalid")
        self.assertEqual(records[0].levelno, logging.WARNING)

    def test_checkpoint_ahead_of_partition_tail_is_invalid(self):
        blob_name = checkpoint_blob_name(
            NAMESPACE,
            EVENT_HUB,
            CONSUMER_GROUP,
            "0",
        )

        statuses, records, _ = run_monitor(
            {"0": partition(10, 30)},
            {blob_name: checkpoint(100, 60)},
        )

        self.assertEqual(statuses[0].status, "invalid")
        self.assertEqual(statuses[0].sequence_lag, -90)
        self.assertEqual(records[0].levelno, logging.WARNING)

    def test_missing_checkpoint_container_is_treated_as_no_checkpoints(self):
        first_blob_name = checkpoint_blob_name(
            NAMESPACE,
            EVENT_HUB,
            CONSUMER_GROUP,
            "0",
        )
        second_blob_name = checkpoint_blob_name(
            NAMESPACE,
            EVENT_HUB,
            CONSUMER_GROUP,
            "1",
        )

        statuses, records, _ = run_monitor(
            {
                "0": partition(10, 30),
                "1": partition(-1, 0, is_empty=True),
            },
            {
                first_blob_name: not_found_error(
                    "container not found",
                    "ContainerNotFound",
                ),
                second_blob_name: not_found_error(
                    "container not found",
                    "ContainerNotFound",
                ),
            },
        )

        self.assertEqual(
            [status.status for status in statuses],
            ["missing", "idle"],
        )
        self.assertEqual(
            [record.levelno for record in records],
            [logging.WARNING, logging.INFO],
        )

    def test_unknown_checkpoint_store_not_found_error_is_not_hidden(self):
        blob_name = checkpoint_blob_name(
            NAMESPACE,
            EVENT_HUB,
            CONSUMER_GROUP,
            "0",
        )

        with self.assertRaises(ResourceNotFoundError):
            run_monitor(
                {"0": partition(10, 30)},
                {
                    blob_name: not_found_error(
                        "unexpected not found",
                        "FilesystemNotFound",
                    )
                },
            )

    def test_telemetry_has_a_fixed_safe_dimension_set(self):
        statuses, records, _ = run_monitor(
            {"0": partition(-1, 0, is_empty=True)},
            {},
        )

        self.assertEqual(len(statuses), 1)
        _, payload = records[0].getMessage().split(" ", 1)
        self.assertEqual(
            set(json.loads(payload)),
            {
                "eventHubName",
                "consumerGroup",
                "partitionId",
                "status",
                "checkpointAgeSeconds",
                "eventAgeSeconds",
                "checkpointSequenceNumber",
                "lastEnqueuedSequenceNumber",
                "sequenceLag",
                "checkpointLastModifiedUtc",
                "lastEnqueuedTimeUtc",
                "staleThresholdSeconds",
                "idleThresholdSeconds",
            },
        )


if __name__ == "__main__":
    unittest.main()

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import threading


@dataclass(frozen=True)
class StateClaim:
    partition_key: str
    row_key: str
    outcome: str
    status: str
    etag: str | None
    properties: dict


def state_row_key(source_id, source_etag=None):
    material = f"{source_id}\0{source_etag or ''}".encode("utf-8")
    return hashlib.sha256(material).hexdigest()


def _utc_now():
    return datetime.now(timezone.utc).isoformat()


class InMemoryStateStore:
    def __init__(self):
        self._entities = {}
        self._lock = threading.Lock()

    def claim_event(self, event_id, properties=None):
        return self._claim("event", event_id, None, {"ingested"}, properties)

    def claim_cost(self, source_path, source_etag, properties=None):
        return self._claim(
            "cost", source_path, source_etag, {"allocated", "rejected"}, properties
        )

    def _claim(
        self, partition_key, source_id, source_etag, terminal_statuses, properties
    ):
        key = (partition_key, state_row_key(source_id, source_etag))
        with self._lock:
            existing = self._entities.get(key)
            if existing:
                outcome = (
                    "complete"
                    if existing["Status"] in terminal_statuses
                    else "retry"
                )
                return self._to_claim(existing, outcome)
            entity = {
                "PartitionKey": partition_key,
                "RowKey": key[1],
                "Status": "claimed",
                "SourceId": source_id,
                "SourceETag": source_etag,
                "UpdatedAt": _utc_now(),
                "_version": 1,
            }
            entity.update(_without_none(properties or {}))
            self._entities[key] = entity
            return self._to_claim(entity, "new")

    def transition(self, claim, status, properties=None):
        key = (claim.partition_key, claim.row_key)
        with self._lock:
            current = self._entities[key]
            if claim.etag != str(current["_version"]):
                raise RuntimeError("State ETag changed before the transition.")
            current["Status"] = status
            current["UpdatedAt"] = _utc_now()
            current.update(_without_none(properties or {}))
            current["_version"] += 1
            return self._to_claim(current, claim.outcome)

    @staticmethod
    def _to_claim(entity, outcome):
        return StateClaim(
            partition_key=entity["PartitionKey"],
            row_key=entity["RowKey"],
            outcome=outcome,
            status=entity["Status"],
            etag=str(entity["_version"]),
            properties=dict(entity),
        )


class AzureTableStateStore:
    def __init__(self, endpoint, table_name, credential):
        from azure.data.tables import TableServiceClient

        service = TableServiceClient(endpoint=endpoint, credential=credential)
        self._table = service.get_table_client(table_name)

    def claim_event(self, event_id, properties=None):
        return self._claim("event", event_id, None, {"ingested"}, properties)

    def claim_cost(self, source_path, source_etag, properties=None):
        return self._claim(
            "cost", source_path, source_etag, {"allocated", "rejected"}, properties
        )

    def _claim(
        self, partition_key, source_id, source_etag, terminal_statuses, properties
    ):
        from azure.core.exceptions import ResourceExistsError

        row_key = state_row_key(source_id, source_etag)
        entity = {
            "PartitionKey": partition_key,
            "RowKey": row_key,
            "Status": "claimed",
            "SourceId": source_id,
            "UpdatedAt": _utc_now(),
        }
        if source_etag is not None:
            entity["SourceETag"] = source_etag
        entity.update(_without_none(properties or {}))
        try:
            self._table.create_entity(entity)
            stored = self._table.get_entity(partition_key, row_key)
            return _azure_claim(stored, "new")
        except ResourceExistsError:
            stored = self._table.get_entity(partition_key, row_key)
            outcome = (
                "complete" if stored["Status"] in terminal_statuses else "retry"
            )
            return _azure_claim(stored, outcome)

    def transition(self, claim, status, properties=None):
        from azure.core import MatchConditions
        from azure.data.tables import UpdateMode

        entity = {
            "PartitionKey": claim.partition_key,
            "RowKey": claim.row_key,
            "Status": status,
            "UpdatedAt": _utc_now(),
        }
        entity.update(_without_none(properties or {}))
        self._table.update_entity(
            entity,
            mode=UpdateMode.MERGE,
            etag=claim.etag,
            match_condition=MatchConditions.IfNotModified,
        )
        stored = self._table.get_entity(claim.partition_key, claim.row_key)
        return _azure_claim(stored, claim.outcome)


def _azure_claim(entity, outcome):
    metadata = getattr(entity, "metadata", {}) or {}
    return StateClaim(
        partition_key=entity["PartitionKey"],
        row_key=entity["RowKey"],
        outcome=outcome,
        status=entity["Status"],
        etag=metadata.get("etag"),
        properties=dict(entity),
    )


def _without_none(values):
    return {key: value for key, value in values.items() if value is not None}

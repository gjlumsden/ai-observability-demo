from datetime import datetime, timezone
import hashlib
import json
import uuid


def build_quarantine_record(payload, reason, evidence, validation_paths=()):
    body = payload if isinstance(payload, bytes) else str(payload).encode("utf-8")
    return {
        "quarantinedAt": datetime.now(timezone.utc).isoformat(),
        "reason": reason,
        "validationPaths": list(validation_paths),
        "payloadSha256": hashlib.sha256(body).hexdigest(),
        "payloadBytes": len(body),
        "eventHubPartition": evidence.partition_id,
        "eventHubSequenceNumber": evidence.sequence_number,
        "eventHubOffset": evidence.offset,
        "eventHubEnqueuedTime": (
            evidence.enqueued_time.astimezone(timezone.utc).isoformat()
            if evidence.enqueued_time
            else None
        ),
    }


class BlobQuarantineWriter:
    def __init__(self, endpoint, container_name, credential):
        from azure.storage.blob import BlobServiceClient

        service = BlobServiceClient(account_url=endpoint, credential=credential)
        self._container = service.get_container_client(container_name)

    def write(self, record):
        now = datetime.now(timezone.utc)
        sequence = record.get("eventHubSequenceNumber")
        sequence_part = str(sequence) if sequence is not None else "unknown"
        blob_name = (
            f"{now:%Y/%m/%d/%H}/"
            f"{sequence_part}-{uuid.uuid4().hex}.json"
        )
        data = json.dumps(
            record, separators=(",", ":"), sort_keys=True, allow_nan=False
        ).encode("utf-8")
        self._container.upload_blob(blob_name, data, overwrite=False)
        return blob_name

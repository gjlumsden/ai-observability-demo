from dataclasses import dataclass
import os

from .errors import ConfigurationError


def canonical_resource_id(value):
    if not value:
        return ""
    return "/" + value.strip().strip("/").lower()


def _split_resource_ids(value):
    if not value:
        return ()
    normalized = value.replace(";", ",")
    return tuple(
        canonical_resource_id(item)
        for item in normalized.split(",")
        if item.strip()
    )


@dataclass(frozen=True)
class Settings:
    storage_blob_endpoint: str
    storage_table_endpoint: str
    state_table_name: str
    quarantine_container_name: str
    capture_container_name: str
    event_hub_namespace: str
    event_hub_name: str
    dcr_endpoint: str
    dcr_immutable_id: str
    dcr_usage_stream: str
    dcr_allocation_stream: str
    workload_resource_group_id: str
    workload_model_resource_ids: tuple[str, ...]
    subscription_id: str
    credential_client_id: str | None
    finops_blob_endpoint: str | None
    finops_container_name: str
    log_analytics_workspace_id: str | None

    @classmethod
    def from_env(cls, environ=None):
        values = os.environ if environ is None else environ
        credential_client_id = (
            values.get("FINOPS_HUB_STORAGE_CLIENT_ID")
            or values.get("AIUsageEventHub__clientId")
            or values.get("AzureWebJobsStorage__clientId")
        )
        return cls(
            storage_blob_endpoint=values.get("USAGE_STORAGE_BLOB_ENDPOINT", ""),
            storage_table_endpoint=values.get("USAGE_STORAGE_TABLE_ENDPOINT", ""),
            state_table_name=values.get("USAGE_PROCESSOR_STATE_TABLE", ""),
            quarantine_container_name=values.get("USAGE_QUARANTINE_CONTAINER", ""),
            capture_container_name=values.get("USAGE_CAPTURE_CONTAINER", ""),
            event_hub_namespace=values.get("AIUsageEventHub__fullyQualifiedNamespace", ""),
            event_hub_name=values.get("AI_USAGE_EVENT_HUB_NAME", ""),
            dcr_endpoint=values.get("DCR_ENDPOINT", ""),
            dcr_immutable_id=values.get("DCR_IMMUTABLE_ID", ""),
            dcr_usage_stream=values.get("DCR_USAGE_STREAM", ""),
            dcr_allocation_stream=values.get("DCR_ALLOCATION_STREAM", ""),
            workload_resource_group_id=canonical_resource_id(
                values.get("WORKLOAD_RESOURCE_GROUP_ID", "")
            ),
            workload_model_resource_ids=_split_resource_ids(
                values.get("WORKLOAD_MODEL_RESOURCE_IDS", "")
            ),
            subscription_id=values.get("AZURE_SUBSCRIPTION_ID", ""),
            credential_client_id=credential_client_id,
            finops_blob_endpoint=values.get("FINOPS_HUB_STORAGE_BLOB_ENDPOINT"),
            finops_container_name=values.get(
                "FINOPS_HUB_INGESTION_CONTAINER", "ingestion"
            ),
            log_analytics_workspace_id=values.get("LOG_ANALYTICS_WORKSPACE_ID"),
        )

    def require_usage_ingestion(self):
        required = {
            "USAGE_STORAGE_BLOB_ENDPOINT": self.storage_blob_endpoint,
            "USAGE_STORAGE_TABLE_ENDPOINT": self.storage_table_endpoint,
            "USAGE_PROCESSOR_STATE_TABLE": self.state_table_name,
            "USAGE_QUARANTINE_CONTAINER": self.quarantine_container_name,
            "DCR_ENDPOINT": self.dcr_endpoint,
            "DCR_IMMUTABLE_ID": self.dcr_immutable_id,
            "DCR_USAGE_STREAM": self.dcr_usage_stream,
            "WORKLOAD_RESOURCE_GROUP_ID": self.workload_resource_group_id,
        }
        self._require(required)

    def require_focus_allocation(self):
        required = {
            "USAGE_STORAGE_TABLE_ENDPOINT": self.storage_table_endpoint,
            "USAGE_PROCESSOR_STATE_TABLE": self.state_table_name,
            "DCR_ENDPOINT": self.dcr_endpoint,
            "DCR_IMMUTABLE_ID": self.dcr_immutable_id,
            "DCR_ALLOCATION_STREAM": self.dcr_allocation_stream,
            "WORKLOAD_RESOURCE_GROUP_ID": self.workload_resource_group_id,
            "FINOPS_HUB_STORAGE_BLOB_ENDPOINT": self.finops_blob_endpoint,
            "LOG_ANALYTICS_WORKSPACE_ID": self.log_analytics_workspace_id,
        }
        self._require(required)
        if not self.workload_model_resource_ids:
            raise ConfigurationError(
                "WORKLOAD_MODEL_RESOURCE_IDS must contain the exact model resource ID."
            )

    def require_cost_context(self):
        self._require(
            {
                "AZURE_SUBSCRIPTION_ID": self.subscription_id,
                "DCR_ENDPOINT": self.dcr_endpoint,
                "DCR_IMMUTABLE_ID": self.dcr_immutable_id,
                "DCR_ALLOCATION_STREAM": self.dcr_allocation_stream,
            }
        )

    @staticmethod
    def _require(values):
        missing = sorted(name for name, value in values.items() if not value)
        if missing:
            raise ConfigurationError(
                "Missing required application settings: " + ", ".join(missing)
            )

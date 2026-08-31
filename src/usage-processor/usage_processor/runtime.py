from functools import lru_cache

from .allocation_service import (
    default_external_query_range,
    process_external_claude_context,
    process_focus_manifests,
)
from .cost_context import SubscriptionCostQuery
from .credentials import build_credential
from .event_service import process_event_batch
from .focus import AzureFocusSource
from .ingestion import LogsIngestionWriter
from .quarantine import BlobQuarantineWriter
from .rates import RateCard
from .settings import Settings
from .state import AzureTableStateStore
from .usage_query import MonitorUsageQuery
from .validation import ContractValidator


@lru_cache(maxsize=1)
def _common_services():
    settings = Settings.from_env()
    credential = build_credential(settings.credential_client_id)
    state_store = AzureTableStateStore(
        settings.storage_table_endpoint,
        settings.state_table_name,
        credential,
    )
    ingestion_writer = LogsIngestionWriter(
        settings.dcr_endpoint,
        settings.dcr_immutable_id,
        credential,
    )
    return (
        settings,
        credential,
        state_store,
        ingestion_writer,
        ContractValidator(),
    )


def run_usage_event_batch(events):
    settings = Settings.from_env()
    settings.require_usage_ingestion()
    (
        _,
        credential,
        state_store,
        ingestion_writer,
        validator,
    ) = _common_services()
    quarantine_writer = BlobQuarantineWriter(
        settings.storage_blob_endpoint,
        settings.quarantine_container_name,
        credential,
    )
    return process_event_batch(
        events,
        settings=settings,
        validator=validator,
        rate_card=RateCard.load(),
        state_store=state_store,
        quarantine_writer=quarantine_writer,
        ingestion_writer=ingestion_writer,
    )


def run_focus_allocation():
    settings = Settings.from_env()
    settings.require_focus_allocation()
    (
        _,
        credential,
        state_store,
        ingestion_writer,
        validator,
    ) = _common_services()
    source = AzureFocusSource(
        settings.finops_blob_endpoint,
        settings.finops_container_name,
        credential,
    )
    usage_query = MonitorUsageQuery(
        settings.log_analytics_workspace_id,
        credential,
        settings.workload_model_resource_ids,
    )
    return process_focus_manifests(
        settings=settings,
        source=source,
        state_store=state_store,
        usage_query=usage_query,
        ingestion_writer=ingestion_writer,
        validator=validator,
    )


def run_external_claude_context():
    settings = Settings.from_env()
    settings.require_cost_context()
    (
        _,
        credential,
        state_store,
        ingestion_writer,
        validator,
    ) = _common_services()
    start, end = default_external_query_range()
    return process_external_claude_context(
        settings=settings,
        start=start,
        end=end,
        cost_query=SubscriptionCostQuery(settings.subscription_id, credential),
        state_store=state_store,
        ingestion_writer=ingestion_writer,
        validator=validator,
    )

from dataclasses import dataclass
import json
import logging

from .evidence import extract_event_evidence
from .errors import EventValidationError, ScopeViolation
from .normalization import normalize_event_usage
from .quarantine import build_quarantine_record
from .usage_rows import build_usage_row, enforce_usage_scope


LOGGER = logging.getLogger("usage_processor.events")
MAX_EVENT_BYTES = 262_144


@dataclass
class PreparedEvent:
    row: dict
    claim: object


def process_event_batch(
    events,
    *,
    settings,
    validator,
    rate_card,
    state_store,
    quarantine_writer,
    ingestion_writer,
):
    prepared = []
    quarantined = 0
    quarantine_failures = []
    duplicates = 0
    for binding_event in events:
        evidence = extract_event_evidence(binding_event)
        body = bytes(binding_event.get_body())
        try:
            event = parse_event(body)
            validator.validate_event(event)
            enforce_usage_scope(event, settings.workload_resource_group_id)
            if (
                settings.workload_model_resource_ids
                and event["modelResourceId"].strip("/").casefold()
                not in {
                    item.strip("/").casefold()
                    for item in settings.workload_model_resource_ids
                }
            ):
                raise ScopeViolation("usage-model-resource-not-allowlisted")
        except EventValidationError as error:
            try:
                quarantine_writer.write(
                    build_quarantine_record(
                        body,
                        error.code,
                        evidence,
                        validation_paths=error.paths,
                    )
                )
            except Exception as write_error:
                quarantine_failures.append(write_error)
                LOGGER.error(
                    "A quarantine write failed: %s",
                    write_error.__class__.__name__,
                )
            quarantined += 1
            continue
        except ScopeViolation as error:
            try:
                quarantine_writer.write(
                    build_quarantine_record(body, str(error), evidence)
                )
            except Exception as write_error:
                quarantine_failures.append(write_error)
                LOGGER.error(
                    "A quarantine write failed: %s",
                    write_error.__class__.__name__,
                )
            quarantined += 1
            continue

        claim = state_store.claim_event(
            event["eventId"],
            {
                **evidence.as_state_properties(),
                "CorrelationId": event["correlationId"],
            },
        )
        if claim.outcome == "complete":
            duplicates += 1
            continue

        usage = normalize_event_usage(event)
        estimate = rate_card.estimate(
            provider=event["provider"],
            model=event["requestModel"],
            deployment_type=event["deploymentType"],
            event_time=event["eventTimeUtc"],
            usage=usage,
        )
        row = build_usage_row(event, usage, estimate, evidence, settings)
        claim = state_store.transition(
            claim,
            "ingesting",
            {
                "RateCardStatus": estimate.status,
                "RateCardVersionId": row["RateCardVersionId"],
            },
        )
        prepared.append(PreparedEvent(row=row, claim=claim))

    if prepared:
        ingestion_writer.upload(
            settings.dcr_usage_stream,
            [item.row for item in prepared],
        )
        for item in prepared:
            state_store.transition(item.claim, "ingested")

    LOGGER.info(
        "Usage batch processed: accepted=%d quarantined=%d duplicates=%d",
        len(prepared),
        quarantined,
        duplicates,
    )
    if quarantine_failures:
        raise RuntimeError(
            f"{len(quarantine_failures)} quarantine record(s) could not be stored."
        ) from quarantine_failures[0]
    return {
        "accepted": len(prepared),
        "quarantined": quarantined,
        "duplicates": duplicates,
    }


def parse_event(body):
    if len(body) > MAX_EVENT_BYTES:
        raise EventValidationError("event-too-large")
    try:
        text = body.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise EventValidationError("event-not-utf8") from error
    try:
        value = json.loads(text, parse_constant=_reject_nonfinite)
    except (json.JSONDecodeError, ValueError) as error:
        raise EventValidationError("event-not-json") from error
    if not isinstance(value, dict):
        raise EventValidationError("event-not-object")
    return value


def _reject_nonfinite(value):
    raise ValueError(f"Non-finite JSON number: {value}")

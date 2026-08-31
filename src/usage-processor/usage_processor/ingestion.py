from dataclasses import dataclass
import time


@dataclass(frozen=True)
class RetryPolicy:
    attempts: int = 4
    initial_delay_seconds: float = 0.5
    maximum_delay_seconds: float = 4.0


def retry_call(operation, is_retryable, policy=RetryPolicy(), sleep=time.sleep):
    delay = policy.initial_delay_seconds
    for attempt in range(1, policy.attempts + 1):
        try:
            return operation()
        except Exception as error:
            if attempt == policy.attempts or not is_retryable(error):
                raise
            sleep(delay)
            delay = min(delay * 2, policy.maximum_delay_seconds)


def is_transient_azure_error(error):
    status_code = getattr(error, "status_code", None)
    if status_code in {408, 409, 429}:
        return True
    if isinstance(status_code, int) and status_code >= 500:
        return True
    return error.__class__.__name__ in {
        "ServiceRequestError",
        "ServiceResponseError",
    }


class LogsIngestionWriter:
    def __init__(
        self,
        endpoint,
        immutable_rule_id,
        credential,
        retry_policy=RetryPolicy(),
        sleep=time.sleep,
    ):
        from azure.monitor.ingestion import LogsIngestionClient

        self._client = LogsIngestionClient(endpoint=endpoint, credential=credential)
        self._rule_id = immutable_rule_id
        self._retry_policy = retry_policy
        self._sleep = sleep

    def upload(self, stream_name, rows):
        if not rows:
            return

        def send():
            return self._client.upload(
                rule_id=self._rule_id,
                stream_name=stream_name,
                logs=rows,
            )

        return retry_call(
            send,
            is_transient_azure_error,
            policy=self._retry_policy,
            sleep=self._sleep,
        )

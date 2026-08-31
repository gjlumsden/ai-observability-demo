class UsageProcessorError(Exception):
    """Base error for the usage processor."""


class ConfigurationError(UsageProcessorError):
    """A required application setting is absent or invalid."""


class EventValidationError(UsageProcessorError):
    """An event is unsafe or does not match the event contract."""

    def __init__(self, code, paths=()):
        super().__init__(code)
        self.code = code
        self.paths = tuple(paths)


class ScopeViolation(UsageProcessorError):
    """A usage or cost record is outside the configured workload scope."""


class FocusContractError(UsageProcessorError):
    """A FOCUS dataset does not contain the required contract."""

import logging

import azure.functions as func

from usage_processor.runtime import (
    run_external_claude_context,
    run_focus_allocation,
    run_usage_event_batch,
)


app = func.FunctionApp()
LOGGER = logging.getLogger("usage_processor.functions")


@app.function_name(name="ProcessAIUsage")
@app.event_hub_message_trigger(
    arg_name="events",
    event_hub_name="%AI_USAGE_EVENT_HUB_NAME%",
    connection="AIUsageEventHub",
    consumer_group="%AI_USAGE_CONSUMER_GROUP%",
    cardinality="many",
)
def process_ai_usage(events: list[func.EventHubEvent]):
    run_usage_event_batch(events)


@app.function_name(name="AllocateFocusCost")
@app.timer_trigger(
    arg_name="timer",
    schedule="0 15 2 * * *",
    run_on_startup=False,
    use_monitor=True,
)
def allocate_focus_cost(timer: func.TimerRequest):
    if timer.past_due:
        LOGGER.warning("The FOCUS allocation timer is past due.")
    run_focus_allocation()


@app.function_name(name="RecordClaudeCcuContext")
@app.timer_trigger(
    arg_name="timer",
    schedule="0 45 2 * * *",
    run_on_startup=False,
    use_monitor=True,
)
def record_claude_ccu_context(timer: func.TimerRequest):
    if timer.past_due:
        LOGGER.warning("The Claude CCU context timer is past due.")
    run_external_claude_context()

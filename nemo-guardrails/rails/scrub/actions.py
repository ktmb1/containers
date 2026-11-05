"""The masking action the rails in rails.co call.

The built-in "mask sensitive data on input" rail masks only $user_message, the
latest user turn. In passthrough mode NeMo forwards the client's entire
message list - system prompt, earlier turns, tool results - so everything but
that one turn would reach the provider verbatim.

There is no supported hook for rewriting the other messages in 0.24.1. What
does work is the context variable holding the outgoing request: it is the very
list NeMo hands to the model, so masking it in place masks what is sent. That
is reliance on an internal, which is why verify.sh inspects what actually
reaches a fake upstream rather than trusting this code, and why a NeMo bump is
never automerged on a build alone.
"""

from nemoguardrails.actions import action
from nemoguardrails.context import raw_llm_request

import scrubber


@action(name="mask_all_messages")
async def mask_all_messages():
    messages = raw_llm_request.get()
    if not isinstance(messages, list):
        # Not a chat request (a raw prompt string). Nothing this image serves
        # sends one, and a silent pass here would forward it unmasked - so
        # refuse it rather than guess.
        raise RuntimeError("scrub: expected a chat message list, got %s" % type(messages).__name__)
    return scrubber.mask_messages(messages)

"""Requests for verify.sh: send each shape of request through the proxy, then
check what the fake upstream actually received.

Usage: check.py <proxy-url> <upstream-log>

The assertion that matters is the last one: no canary appears anywhere in
anything the upstream received, across every request. Each case also checks
its own reply, because a proxy that masks by never calling the model would
pass the leak check perfectly.
"""

import json
import sys
import urllib.error
import urllib.request

PROXY, LOG = sys.argv[1], sys.argv[2]

# Must match the names file verify.sh mounts. Fake, like everything here.
LEAKS = [
    "zebedee",
    "quillon",
    "jane citizen",
    "jane.citizen@example.com",
    "0412 345 678",
    "4782 1234",
    "123 456 782",
]
# Measurements and places the scrubber must not touch.
KEEPS = ["21.5 °C", "63 %", "5.2 kW", "Katoomba"]

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "GetLiveContext",
            "description": "Read the house state",
            "parameters": {"type": "object", "properties": {"area": {"type": "string"}}},
        },
    }
]

SYSTEM = {
    "role": "system",
    "content": "You help the Zebedee Quillon household. Escalate to jane.citizen@example.com.",
}
STATE = (
    "person.zebedee: home\n"
    "device_tracker.quillon_phone: not_home\n"
    "Jane Citizen is at home.\n"
    "Living: 21.5 °C, humidity 63 %, solar 5.2 kW. Katoomba min 4 max 17.\n"
    "Caller ID 0412 345 678, office +61 2 4782 1234, TFN 123 456 782."
)
TOOL_CALL = {
    "role": "assistant",
    "content": None,
    "tool_calls": [
        {
            "id": "call_1",
            "type": "function",
            "function": {"name": "GetLiveContext", "arguments": '{"area": "zebedee_bedroom"}'},
        }
    ],
}

failures: list[str] = []


def post(body: dict, headers: dict | None = None) -> tuple[int, dict | str]:
    request = urllib.request.Request(
        f"{PROXY}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", **(headers or {})},
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            raw = response.read().decode()
            try:
                return response.status, json.loads(raw)
            except json.JSONDecodeError:
                return response.status, raw
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def received() -> list[dict]:
    try:
        with open(LOG, encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]
    except FileNotFoundError:
        return []


def case(name: str, body: dict, expect: str) -> None:
    """Send body; expect 'text' or 'tool_calls' back from exactly one upstream call."""
    before = len(received())
    status, reply = post({"model": "fake-model", **body}, {"Authorization": "Bearer caller-key"})
    calls = received()[before:]
    print(f"==> {name}: HTTP {status}, {len(calls)} upstream call(s)")

    if status != 200 or not isinstance(reply, dict):
        failures.append(f"{name}: HTTP {status}: {str(reply)[:400]}")
        return
    message = reply["choices"][0]["message"]
    if expect == "text" and not message.get("content"):
        # The 0.24.1 tool_input bug looks exactly like this: HTTP 200, an
        # empty reply, and no upstream call.
        failures.append(f"{name}: empty reply (was the model ever called?): {message}")
    if expect == "tool_calls" and not message.get("tool_calls"):
        failures.append(f"{name}: expected tool_calls back, got {message}")
    if len(calls) != 1:
        failures.append(f"{name}: expected exactly 1 upstream call, got {len(calls)}")
        return

    sent = calls[0]
    if sent["body"].get("model") != "fake-model":
        failures.append(f"{name}: upstream got model {sent['body'].get('model')!r}, not the caller's")
    # NeMo authenticates upstream with its own OPENAI_API_KEY and does not pass
    # the caller's Authorization through. The deployment relies on that: the
    # gateway key lives here, never in the caller.
    if sent["auth"] != "Bearer verify-upstream-key":
        failures.append(f"{name}: upstream Authorization was {sent['auth']!r}")
    text = json.dumps(sent["body"], ensure_ascii=False)
    for keep in KEEPS:
        if keep in json.dumps(body, ensure_ascii=False) and keep not in text:
            failures.append(f"{name}: {keep!r} was masked; measurements must pass through")


case(
    "system, history and user turn",
    {
        "messages": [
            SYSTEM,
            {"role": "user", "content": "Jane Citizen is at home."},
            {"role": "assistant", "content": "Noted."},
            {"role": "user", "content": "Ring 0412 345 678 when person.zebedee is home. " + STATE},
        ]
    },
    "text",
)

case(
    "multi-part user content",
    {"messages": [SYSTEM, {"role": "user", "content": [{"type": "text", "text": STATE}]}]},
    "text",
)

case(
    "tools offered",
    {"messages": [SYSTEM, {"role": "user", "content": "Is Zebedee home? " + STATE}], "tools": TOOLS},
    "tool_calls",
)

# Requests ending in a tool result skip the input rails entirely; this is the
# case the tool_input rail and the resume flow in rails.co exist for. The
# Home Assistant answer is where most of the names are.
case(
    "ends in a tool result",
    {
        "messages": [
            SYSTEM,
            {"role": "user", "content": "Is Zebedee home?"},
            TOOL_CALL,
            {"role": "tool", "tool_call_id": "call_1", "content": STATE},
        ],
        "tools": TOOLS,
    },
    "text",
)

case(
    "ends in two tool results",
    {
        "messages": [
            SYSTEM,
            {"role": "user", "content": "Where is everyone?"},
            {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    TOOL_CALL["tool_calls"][0],
                    {**TOOL_CALL["tool_calls"][0], "id": "call_2"},
                ],
            },
            {"role": "tool", "tool_call_id": "call_1", "content": STATE},
            {"role": "tool", "tool_call_id": "call_2", "content": "device_tracker.quillon_phone: home"},
        ],
        "tools": TOOLS,
    },
    "text",
)

# A caller must not be able to pick a config without the masking rails.
before = len(received())
status, reply = post(
    {
        "model": "fake-model",
        "messages": [{"role": "user", "content": STATE}],
        "guardrails": {"config_ids": ["anything-else"]},
    }
)
print(f"==> another config id: HTTP {status}")
if status == 200 or len(received()) != before:
    failures.append(f"another config id: HTTP {status}, {len(received()) - before} upstream call(s); must be refused")

# NeMo refuses streaming together with tools. That must stay a refusal, never
# a fallback that skips the rails.
before = len(received())
status, reply = post({"model": "fake-model", "stream": True, "messages": [SYSTEM, {"role": "user", "content": STATE}], "tools": TOOLS})
print(f"==> streaming with tools: HTTP {status}, {len(received()) - before} upstream call(s)")

# The check that matters: nothing personal in anything the upstream saw.
everything = received()
print(f"==> checking all {len(everything)} upstream requests for leaks")
for i, call in enumerate(everything):
    text = json.dumps(call["body"], ensure_ascii=False).lower()
    for leak in LEAKS:
        if leak in text:
            failures.append(f"upstream request {i} contains {leak!r}: {text[:600]}")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    sys.exit(1)
print("==> no leaks, every case answered")

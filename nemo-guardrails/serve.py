"""Entrypoint: prove the scrubber masks, then exec the NeMo server.

The proxy's only job is masking, and the ways masking can quietly stop are all
runtime ones: a names file mounted empty or at the wrong path, a spaCy model
that fails to load, a recognizer an upgrade renamed. None of them stops the
server from answering. So before it starts, run the same scrubber the rails
use over a canary and every household name, and refuse to start if anything
survives. A pod that will not start fails closed - its caller gets connection
errors, not an unmasked request upstream.

This checks the scrubber, not NeMo's wiring of it into the request path; that
is fixed in the image and proven per build by verify.sh.
"""

import logging
import os
import sys

import scrubber

logging.basicConfig(level=logging.INFO, format="%(levelname)s:%(name)s:%(message)s")
log = logging.getLogger("serve")

# Fake data in every shape the scrubber must handle. None of it is real.
CANARY_LEAKS = {
    "Jane Citizen is at home.": ["Jane Citizen"],
    "Call 0412 345 678 or +61 2 4782 1234": ["0412 345 678", "4782 1234"],
    "Mail jane.citizen@example.com": ["jane.citizen@example.com"],
    "TFN 123 456 782": ["123 456 782"],
}
# And things it must leave alone: masking these would make the requests
# useless, which pushes people to route around the proxy.
CANARY_KEEPS = ["21.5 °C", "63 %", "5.2 kW", "12345 Wh", "Katoomba"]


def self_check() -> list[str]:
    failures = []
    for text, leaks in CANARY_LEAKS.items():
        masked = scrubber.mask(text)
        failures += [f"{leak!r} survived in {masked!r}" for leak in leaks if leak in masked]

    kept = scrubber.mask("Living " + ", ".join(CANARY_KEEPS))
    failures += [f"{keep!r} was masked: {kept!r}" for keep in CANARY_KEEPS if keep not in kept]

    for name in scrubber.household_names():
        for text in (f"person.{name.lower()}", f"{name} is home", f"device_tracker.{name.lower()}_phone"):
            masked = scrubber.mask(text)
            if name.lower() in masked.lower():
                failures.append(f"household name survived in {masked!r}")
    return failures


def main() -> None:
    failures = self_check()
    if failures:
        for failure in failures:
            log.error("self-check: %s", failure)
        sys.exit("self-check failed: refusing to start an unmasking proxy")
    log.info("self-check passed (%d household names)", len(scrubber.household_names()))

    # NeMo needs both to build the per-request main model; without them every
    # request fails at the first model call with a less obvious message.
    for var in ("MAIN_MODEL_BASE_URL", "OPENAI_API_KEY"):
        if not os.environ.get(var):
            sys.exit(f"{var} is not set")

    os.execvp(
        "nemoguardrails",
        [
            "nemoguardrails",
            "server",
            "--config",
            "/app/rails",
            # The only config. A request may still name a config id; any id
            # but this one is rejected, so a caller cannot opt out of masking.
            "--default-config-id",
            "scrub",
            "--port",
            os.environ.get("PORT", "8000"),
            "--disable-chat-ui",
        ],
    )


if __name__ == "__main__":
    main()

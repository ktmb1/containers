"""Presidio masking shared by the NeMo action and the startup self-check.

Kept outside the rails config directory so serve.py can exercise exactly the
code the rails run, before the server starts, without going through NeMo.
"""

import logging
import os
import re
from functools import lru_cache

log = logging.getLogger("scrubber")

# What gets replaced with <ENTITY_TYPE>. LOCATION is left out on purpose: spaCy
# tags place names, and the requests this proxies are about a house - "Katoomba"
# in a weather forecast is the data, not a leak, and masking it made the
# forecasts useless. Street addresses are not something spaCy finds reliably
# either way.
ENTITIES = [
    "PERSON",
    "EMAIL_ADDRESS",
    "PHONE_NUMBER",
    "IP_ADDRESS",
    "CREDIT_CARD",
    "IBAN_CODE",
    "AU_TFN",
    "AU_ABN",
    "AU_ACN",
    "AU_MEDICARE",
]

# Presidio scores below this are noise: NER guesses on capitalised words.
SCORE_THRESHOLD = 0.4

# One name per line; blank lines and # comments ignored. The deployment
# mounts it from a Secret. It is not in the image because this repository and
# its images are public - the list is exactly the data being protected.
NAMES_FILE_ENV = "SCRUBBER_NAMES_FILE"


def household_names() -> list[str]:
    """Names from SCRUBBER_NAMES_FILE. Unset means none; set-but-missing raises.

    A set path that does not exist is a broken mount, and running without the
    list would silently forward every name spaCy does not recognise - which is
    most of them in entity ids like person.<name>. Failing is the safe outcome.
    """
    path = os.environ.get(NAMES_FILE_ENV)
    if not path:
        return []
    with open(path, encoding="utf-8") as f:
        names = [line.strip() for line in f]
    return [n for n in names if n and not n.startswith("#")]


@lru_cache
def engines():
    from presidio_analyzer import AnalyzerEngine, Pattern, PatternRecognizer
    from presidio_analyzer.predefined_recognizers import (
        AuAbnRecognizer,
        AuAcnRecognizer,
        AuMedicareRecognizer,
        AuTfnRecognizer,
        PhoneRecognizer,
    )
    from presidio_anonymizer import AnonymizerEngine

    analyzer = AnalyzerEngine()
    registry = analyzer.registry

    # The AU recognizers exist in Presidio but are not in its default
    # registry.
    for recognizer in (AuTfnRecognizer(), AuAbnRecognizer(), AuAcnRecognizer(), AuMedicareRecognizer()):
        registry.add_recognizer(recognizer)

    # The default phone recognizer only knows US/UK/DE/IL/IN/CA/BR numbering,
    # so "0412 345 678" passed straight through. Replace it with one that also
    # parses Australian numbers.
    registry.remove_recognizer("PhoneRecognizer")
    registry.add_recognizer(PhoneRecognizer(supported_regions=["AU", "US", "GB", "NZ"]))

    # spaCy finds names in prose, not in identifiers: person.alice,
    # device_tracker.alice_phone and "alice_s_iphone" are invisible to it, and
    # Home Assistant answers are mostly identifiers. Match the household's
    # names wherever they are not part of a longer alphanumeric word, so "_"
    # and "." count as separators (\b would treat "_" as part of the word).
    names = household_names()
    if names:
        alternation = "|".join(sorted((re.escape(n) for n in names), key=len, reverse=True))
        registry.add_recognizer(
            PatternRecognizer(
                supported_entity="PERSON",
                name="HouseholdNamesRecognizer",
                patterns=[
                    Pattern(
                        name="household_name",
                        regex=rf"(?<![A-Za-z0-9])(?:{alternation})(?![A-Za-z0-9])",
                        score=1.0,
                    )
                ],
                # Presidio applies IGNORECASE to every pattern by default.
            )
        )
    log.info("scrubber ready: %d household names", len(names))
    return analyzer, AnonymizerEngine()


def mask(text: str) -> str:
    """Replace every detected entity in text with <ENTITY_TYPE>."""
    if not text:
        return text
    analyzer, anonymizer = engines()
    results = analyzer.analyze(text=text, language="en", entities=ENTITIES, score_threshold=SCORE_THRESHOLD)
    # spaCy tags some measurements as people - "12345 Wh" came back PERSON
    # 0.85 - and masking the numbers would destroy exactly the data these
    # requests carry. No name contains a digit, so a PERSON span with one is
    # dropped. The household-names recognizer matches letters only, so this
    # never removes one of its hits.
    results = [r for r in results if not (r.entity_type == "PERSON" and any(c.isdigit() for c in text[r.start : r.end]))]
    if not results:
        return text
    return anonymizer.anonymize(text=text, analyzer_results=results).text


def mask_messages(messages: list) -> str | None:
    """Mask an OpenAI-style message list in place.

    Covers string content, multi-part text content and the arguments of
    assistant tool calls. Returns the masked text of the last user turn (see
    rails.co for why the caller needs it), or None if there is none.
    """
    for message in messages:
        content = message.get("content")
        if isinstance(content, str):
            message["content"] = mask(content)
        elif isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    part["text"] = mask(part.get("text", ""))
        # Earlier assistant turns carry the tool calls the model made. Their
        # arguments are JSON in a string; a replacement inside a JSON string
        # value keeps it valid JSON.
        for call in message.get("tool_calls") or []:
            function = call.get("function") or {}
            if isinstance(function.get("arguments"), str):
                function["arguments"] = mask(function["arguments"])
    for message in reversed(messages):
        if message.get("role") == "user" and isinstance(message.get("content"), str):
            return message["content"]
    return None

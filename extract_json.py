"""Triple-fallback JSON extraction from LLM responses.
  1. Direct json.loads
  2. Strip ```json``` fences and parse
  3. Slice from first '{' to last '}' and parse
Returns None if all three strategies fail.

Source: hackathon-winners/natsec-2026/argus-oracle (TypeScript), ported.
"""
from __future__ import annotations

import json
import re
from typing import Any, Optional


def extract_json(text: str) -> Optional[Any]:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    fenced = re.search(r"```(?:json)?\s*([\s\S]*?)```", text)
    if fenced:
        try:
            return json.loads(fenced.group(1))
        except json.JSONDecodeError:
            pass
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        try:
            return json.loads(text[start:end + 1])
        except json.JSONDecodeError:
            pass
    return None

#!/usr/bin/env python3
"""HA-local stdin adapter; credentials and previous events never reside on the Mac."""
import json
import sys
import urllib.request

MAX_PAYLOAD_BYTES = 16 * 1024 * 1024


def parse_snapshot(stream):
    raw = stream.read(MAX_PAYLOAD_BYTES + 1)
    if len(raw) > MAX_PAYLOAD_BYTES:
        raise ValueError("payload too large")
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate field")
            result[key] = value
        return result
    payload = json.loads(raw, object_pairs_hook=unique_pairs,
                         parse_constant=lambda _: (_ for _ in ()).throw(ValueError("invalid number")))
    # The native publish service validates the full wire contract atomically before mutation.
    if not isinstance(payload, dict) or set(payload) != {"version", "observedAt", "window", "calendars", "removals"}:
        raise ValueError("invalid root")
    if type(payload["version"]) is not int or payload["version"] != 1:
        raise ValueError("unsupported version")
    if not isinstance(payload["observedAt"], str) or not isinstance(payload["window"], dict):
        raise ValueError("invalid observation")
    if not isinstance(payload["calendars"], list) or not isinstance(payload["removals"], list):
        raise ValueError("invalid calendars")
    return payload


def publish(snapshot, resolver, opener=urllib.request.urlopen):
    url, token = resolver()
    request = urllib.request.Request(
        url.rstrip("/") + "/api/services/belovodie_calendar_bridge/publish",
        data=json.dumps({"snapshot": snapshot}, allow_nan=False).encode("utf-8"),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        method="POST",
    )
    with opener(request, timeout=20) as response:
        if response.status != 200:
            raise ValueError("service failed")
        # HA returns states; consume only bounded bytes, never expose their attributes.
        body = response.read(MAX_PAYLOAD_BYTES + 1)
        if len(body) > MAX_PAYLOAD_BYTES or not isinstance(json.loads(body), list):
            raise ValueError("invalid service response")


def main():
    try:
        snapshot = parse_snapshot(sys.stdin.buffer)
        sys.path.insert(0, "/config/_tools")
        from ai_ollama import common
        publish(snapshot, common._get_ha_config)
    except Exception:
        print("Calendar snapshot rejected or publication failed", file=sys.stderr)
        return 1
    print("Calendar snapshot published")
    return 0


if __name__ == "__main__":
    sys.exit(main())

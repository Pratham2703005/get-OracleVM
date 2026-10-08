"""Count a failed launch attempt in keep-going.json, grouped by error code.

Usage: record_error.py <json-file>   (raw CLI error text on stdin)
Stores only counts and a timestamp - never the error text, so no OCIDs or request ids.
"""
import datetime
import json
import re
import sys

path = sys.argv[1]
text = sys.stdin.read()

code = re.search(r'"code":\s*"([^"]+)"', text)
if re.search(r"out of host capacity", text, re.I):
    key = "OutOfHostCapacity"
elif code:
    key = code.group(1)
else:
    key = "Unknown"

try:
    with open(path) as f:
        data = json.load(f)
except (OSError, ValueError):
    data = {}

errors = data.setdefault("errors", {})
errors[key] = errors.get(key, 0) + 1
data["totalFailedAttempts"] = sum(errors.values())
data["lastError"] = key
data["lastAttemptAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

"""Write the app's real local WatchConnectivity snapshot format for the isolated Watch sim."""
import json
import pathlib
import sys
import time

DIARY_ID = "D919A7EF-96A9-4F63-8B30-B5E409412F18"
FEED_ID = "36233F1B-40B6-438F-8C90-F0257A0DE7F0"
# Swift's default JSONEncoder date reference is 2001-01-01T00:00:00Z.
now = time.time() - 978_307_200
start = now - 62 * 60
bottle = {
    "id": "D782F345-8BD8-45A8-9A86-C67DEDA9CD80",
    "babyID": DIARY_ID, "kind": "bottle", "start": start, "end": start + 12 * 60,
    "createdAt": start + 12 * 60, "modifiedAt": start + 12 * 60, "side": "left",
    "leftSeconds": 0, "rightSeconds": 0, "volumeML": 120, "bottleType": "expressed",
    "diaperType": "wet", "note": "",
}
events = [bottle]
if sys.argv[2] in ("active", "sleep"):
    feeding_start = now - 6 * 60
    events.append(dict(bottle, id=FEED_ID, kind="sleep" if sys.argv[2] == "sleep" else "breast", start=feeding_start, end=None,
                       createdAt=feeding_start, modifiedAt=feeding_start, sideStartedAt=feeding_start))
snapshot = {
    "streamID": "D8C7B9E1-E29B-4E54-A5DD-07D69BE08AF9", "revision": 1, "generatedAt": now,
    "selectedID": DIARY_ID,
    "diaries": [{"id": DIARY_ID, "name": "Ванечка", "canWrite": True, "events": events}],
}
path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({"snapshot": snapshot, "retiredStreams": [], "pending": []}, ensure_ascii=False))

"""Keep only the vectors X2 needs: patterns IK, IKpsk1, IKpsk2, XX with 25519 + SHA256.

usage: python3 -I filter-vectors.py <raw dir> <out.json>
"""
import json
import sys

PATTERNS = {"IK", "IKpsk1", "IKpsk2", "XX"}
SOURCES = {
    "cacophony.txt": "cacophony@18b7348",
    "snow.txt": "snow@d00b360",
}

raw, out = sys.argv[1], sys.argv[2]
keep = []
for fname, tag in SOURCES.items():
    with open(f"{raw}/{fname}") as f:
        for v in json.load(f)["vectors"]:
            name = v.get("protocol_name", "")
            parts = name.split("_")
            if len(parts) == 5 and parts[1] in PATTERNS and parts[2] == "25519" and parts[4] == "SHA256":
                keep.append({"source": tag, **v})
with open(out, "w") as f:
    json.dump({"vectors": keep}, f, indent=1)
    f.write("\n")
print(f"wrote {len(keep)} vectors to {out}")

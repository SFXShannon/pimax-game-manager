"""Reads a 'Share a Performance setup' issue (from env), checks it and adds it to community/setups.json.
Writes ok / game / message to $GITHUB_OUTPUT for the workflow. Same rules as the relay (relay/src/setups.js)."""
import json, os, re

GAMES = {
    "ats": "American Truck Simulator", "ets2": "Euro Truck Simulator 2", "msfs2024": "Microsoft Flight Simulator 2024",
    "msfs2020": "Microsoft Flight Simulator 2020", "dcs": "DCS World", "bms": "Falcon BMS", "iracing": "iRacing (VR)",
    "ac": "Assetto Corsa", "ams2": "Automobilista 2", "r3e": "RaceRoom Racing Experience",
}
PATH = "community/setups.json"


def out(**kv):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
        for k, v in kv.items():
            f.write(f"{k}={str(v).replace(chr(10), ' ').replace(chr(13), ' ')}\n")


def fields(body):
    """Issue forms render as '### Label' followed by the answer."""
    parts = re.split(r"^### (.+)$", body, flags=re.M)
    res = {}
    for i in range(1, len(parts) - 1, 2):
        val = parts[i + 1].strip()
        val = re.sub(r"^```\w*\s*|\s*```$", "", val).strip()
        res[parts[i].strip()] = "" if val == "_No response_" else val
    return res


def fail(msg):
    out(ok="false", game="", message="Couldn't add this setup: " + msg + " Edit the issue, then remove and re-add the approved label.")
    raise SystemExit(0)


def clean(v, n, pat=r"[^\w :'&.,()!+#/-]"):
    return re.sub(r"\s+", " ", re.sub(pat, "", v or "")).strip()[:n]


f = fields(os.environ.get("ISSUE_BODY", ""))
game = f.get("Game", "").strip()
if game not in GAMES:
    fail("the game should be one of: " + ", ".join(GAMES) + ".")
try:
    values = json.loads(f.get("Settings", ""))
except ValueError:
    fail("the settings should be JSON, like {\"r_ssao\": \"1\"}.")
if not isinstance(values, dict) or not values or len(values) > 60:
    fail("the settings should list 1 to 60 settings.")
clean_values = {}
for k, v in values.items():
    v = str(v).strip()
    if not re.fullmatch(r"[A-Za-z0-9_ ./]{1,80}", str(k)):
        fail(f"the setting name `{str(k)[:40]}` has unexpected characters.")
    if not re.fullmatch(r"[A-Za-z0-9_. -]{1,40}", v):
        fail(f"the value for `{k}` has unexpected characters.")
    clean_values[str(k)] = v

m = re.fullmatch(r"gpu=([0-3]) cpu=([0-3])", f.get("PC levels", "").strip())
gpu_tier, cpu_tier = (int(m.group(1)), int(m.group(2))) if m else (None, None)
ram = f.get("RAM (GB)", "").strip()
ram = int(ram) if ram.isdigit() and int(ram) <= 4096 else None
scale = f.get("Pimax render scale", "").strip()
try:
    scale = float(scale) if scale else None
    if scale is not None and not 0.2 <= scale <= 3:
        scale = None
except ValueError:
    scale = None

with open(PATH, encoding="utf-8-sig") as fh:
    data = json.load(fh)
if any(s.get("game") == game and s.get("values") == clean_values for s in data["setups"]):
    out(ok="true", game=GAMES[game], message="Thanks! This setup is already in the shared list.")
    raise SystemExit(0)

data["setups"].append({
    "id": int(os.environ.get("ISSUE_NUMBER", "0") or 0),
    "game": game,
    "values": clean_values,
    "gpu": clean(f.get("Graphics card", ""), 80),
    "cpu": clean(f.get("Processor", ""), 80),
    "ramGB": ram,
    "gpuTier": gpu_tier,
    "cpuTier": cpu_tier,
    "headset": clean(f.get("Headset", ""), 60),
    "pimaxScale": scale,
    "result": clean(f.get("Result", ""), 120),
    "author": clean(f.get("Name to show", ""), 40, r"[^\w .'-]") or "anonymous",
    "notes": (f.get("Notes", "").strip()[:400] or None),
    "date": os.environ.get("ISSUE_DATE", "")[:10],
    "source": os.environ.get("ISSUE_URL"),
})
with open(PATH, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
out(ok="true", game=GAMES[game], message=f"Thanks! Your {GAMES[game]} setup is now in the shared list. Pimax Game Manager shows it under Performance > Community setups.")

"""Makes the two designs the new chapters' captures show, from a copy of the screenshots' own poster:
vectorize/Adoption Day.bezzle with the shelter's logo on it as the small JPEG, and animate/Adoption Day.bezzle
with its layers lifted off the sheet as the story's scene has them."""
import json, os, shutil, copy, uuid
LOGO = os.path.expanduser("~/Sites/bezzle-web/public/img/parts/shelter-logo.jpg")
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "..", "designs", "Adoption Day.bezzle")
def fresh(kind):
    out = os.path.join(HERE, "designs", kind, "Adoption Day.bezzle")
    shutil.rmtree(os.path.dirname(out), ignore_errors=True)
    os.makedirs(os.path.dirname(out))
    shutil.copytree(SRC, out)
    shutil.rmtree(os.path.join(out, "sharing"), ignore_errors=True)
    return out, json.load(open(os.path.join(out, "document.json")))
def save(out, doc):
    json.dump(doc, open(os.path.join(out, "document.json"), "w"))

out, doc = fresh("vectorize")
board = doc["nodes"][0]
pug = next(n for n in board["children"] if n["name"] == "Pug")
logo = copy.deepcopy(pug)
asset = "5C0FFEE0-7A11-4B0B-9C3D-51E17E2L0G00".replace("L", "1").replace("G", "6") + ".jpg"
logo.update(id=str(uuid.UUID("7d1f6a52-33c1-4b6e-9a0e-2b8f4c5d6e71")).upper(), name="Logo", frame=[[712, 984], [320, 320]])
logo["fill"]["image"] = {"asset": asset, "mode": "cover", "offset": [0, 0], "scale": 1, "size": [144, 144]}
logo["shadow"]["on"] = False
shutil.copy(LOGO, os.path.join(out, "images", asset))
board["children"].insert(board["children"].index(pug) + 1, logo)
save(out, doc)

out, doc = fresh("animate")
board = doc["nodes"][0]
# the logo as the Vectorize chapter leaves it: the group the app itself made of the JPEG (kept from a capture run of
# that chapter, out/vectorized.json), its white box hidden, lifted off the sheet beside the pug
kept = os.path.join(HERE, "out", "vectorized.json")
if os.path.exists(kept):
    made = next(n for n in json.load(open(kept))["nodes"][0]["children"] if n["name"] == "Logo")
    assert made.get("children"), "the kept design's logo is still a picture"
    box = [c for c in made["children"] if c.get("kind", c.get("type")) in ("rectangle", "rect")] or [made["children"][0]]
    box[0]["hidden"] = True
    pug = next(n for n in board["children"] if n["name"] == "Pug")
    board["children"].insert(board["children"].index(pug) + 1, made)
for n in board["children"]:
    z = {"Good": 1, "Boy": 1, "Pug": 140, "Logo": 141, "Date pill": 60, "Date": 61, "Where": 60}[n["name"]]
    n["transform3D"] = {"x": 0, "y": 0, "z": z}
save(out, doc)
print("made", os.listdir(os.path.join(HERE, "designs")), "with the logo" if os.path.exists(kept) else "without the logo: no out/vectorized.json yet")

#!/usr/bin/env python3
"""Puts Bezzle on the Mac App Store from AppStore/metadata.json, through the App Store Connect API.

Usage: Scripts/appstore/publish.py STEP...
  status        what App Store Connect has now
  listing       name, subtitle, description, what's new, keywords, links, categories, age rating, copyright
  price         the price (base territory and price from metadata.json; 0.0 is free)
  availability  every territory
  screenshots   AppStore/screenshots/<locale>/*.png, replacing what is there
  review        notes for App Review (and the contact, if $REVIEW_FIRST, _LAST, _PHONE, _EMAIL are set)
  build         attach the newest processed build to the version
  submit        send the version to App Review

The app record itself must exist first (App Store Connect does not let the API create apps).
Needs $ASC_KEY_PATH, $ASC_KEY_ID and $ASC_ISSUER; the client is built from asc.swift on first use.
"""
import hashlib, json, os, re, subprocess, sys, tempfile, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
META = json.load(open(os.path.join(ROOT, "AppStore", "metadata.json")))
CLIENT = os.path.join(tempfile.gettempdir(), "bezzle-asc")


def client():
    source = os.path.join(ROOT, "Scripts", "appstore", "asc.swift")
    if not os.path.exists(CLIENT) or os.path.getmtime(CLIENT) < os.path.getmtime(source):
        subprocess.run(["xcrun", "swiftc", "-O", source, "-o", CLIENT], check=True)
    return CLIENT


def api(method, path, body=None, ok=(200, 201, 204)):
    args = [client(), method, path]
    if body is not None:
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(body, f)
        f.close()
        args.append(f.name)
    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
    status_line, _, rest = out.partition("\n")
    status = int(status_line.split()[1])
    data = json.loads(rest) if rest.strip() else {}
    if status not in ok:
        details = "; ".join(e.get("detail", e.get("title", "")) for e in data.get("errors", []))
        raise SystemExit(f"{method} {path}: HTTP {status}: {details}")
    return data


def ref(kind, id):
    return {"data": {"type": kind, "id": id}}


def app():
    found = api("GET", f"/v1/apps?filter[bundleId]={META['app']['bundleId']}")["data"]
    if not found:
        raise SystemExit("No app record for this bundle ID yet: create it in App Store Connect first.")
    return found[0]


def editable_info(app_id):
    infos = api("GET", f"/v1/apps/{app_id}/appInfos")["data"]
    for info in infos:
        if info["attributes"].get("state") in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", None):
            return info
    return infos[0]


def version(app_id):
    versions = api("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=MAC_OS")["data"]
    for v in versions:
        if v["attributes"]["appStoreState"] in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"):
            return v
    raise SystemExit("No editable Mac version.")


def upsert_localizations(list_path, create_type, parent_key, parent_type, parent_id, fields_for):
    existing = {l["attributes"]["locale"]: l for l in api("GET", list_path)["data"]}
    for locale, values in META["localizations"].items():
        attributes = fields_for(values)
        if locale in existing:
            api("PATCH", f"/v1/{create_type}/{existing[locale]['id']}",
                {"data": {"type": create_type, "id": existing[locale]["id"], "attributes": attributes}})
        else:
            api("POST", f"/v1/{create_type}", {"data": {"type": create_type, "attributes": {"locale": locale, **attributes},
                                                        "relationships": {parent_key: ref(parent_type, parent_id)}}})
        print(f"  {create_type} {locale}")


def step_status():
    a = app()
    v = version(a["id"])
    print(f"{a['attributes']['name']} ({a['id']}), version {v['attributes']['versionString']}: {v['attributes']['appStoreState']}")
    builds = api("GET", f"/v1/builds?filter[app]={a['id']}&sort=-uploadedDate&limit=3")["data"]
    for b in builds:
        print(f"  build {b['attributes']['version']}: {b['attributes']['processingState']}")


def step_listing():
    a = app()
    info = editable_info(a["id"])
    meta = META["app"]
    api("PATCH", f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
        "primaryCategory": ref("appCategories", meta["primaryCategory"]),
        "secondaryCategory": ref("appCategories", meta["secondaryCategory"])}}})
    print("  categories")
    upsert_localizations(f"/v1/appInfos/{info['id']}/appInfoLocalizations", "appInfoLocalizations", "appInfo", "appInfos", info["id"],
                         lambda v: {"name": v["name"], "subtitle": v["subtitle"], "privacyPolicyUrl": v["privacyPolicyUrl"]})
    # Age rating: a question still unanswered gets "no" or "none". What is answered already, as the user
    # did by hand on 2026-11-01, is left alone. Overrides and regional ratings are not questions.
    rating = api("GET", f"/v1/appInfos/{info['id']}/ageRatingDeclaration")["data"]
    yes_or_no = {"advertising", "ageAssurance", "gambling", "healthOrWellnessTopics", "lootBox", "messagingAndChat",
                 "parentalControls", "socialMedia", "socialMediaAgeRestricted", "unrestrictedWebAccess", "userGeneratedContent"}
    not_questions = {"kidsAgeBand", "ageRatingOverride", "ageRatingOverrideV2", "koreaAgeRatingOverride",
                     "gracRatingClassificationNumber", "developerAgeRatingInfoUrl"}
    # Only questions nobody has answered yet: answers given in App Store Connect by hand stay as they are.
    answers = {key: (False if key in yes_or_no else "NONE")
               for key, value in rating["attributes"].items() if key not in not_questions and value is None}
    # Questions Apple adds come back unanswered (null), so their type is learnt from its reply.
    for _ in range(5 if answers else 0):
        reply = api("PATCH", f"/v1/ageRatingDeclarations/{rating['id']}",
                    {"data": {"type": "ageRatingDeclarations", "id": rating["id"], "attributes": answers}}, ok=(200, 409))
        wrong = re.findall(r"attribute '(\w+)'\. Expected a BOOLEAN", " ".join(e.get("detail", "") for e in reply.get("errors", [])))
        if not reply.get("errors"):
            break
        if not wrong:
            raise SystemExit("Age rating: " + "; ".join(e.get("detail", "") for e in reply["errors"]))
        for key in wrong:
            answers[key] = False
    print("  age rating")
    api("PATCH", f"/v1/apps/{a['id']}", {"data": {"type": "apps", "id": a["id"],
                                                 "attributes": {"contentRightsDeclaration": meta["contentRightsDeclaration"]}}})
    v = version(a["id"])
    api("PATCH", f"/v1/appStoreVersions/{v['id']}", {"data": {"type": "appStoreVersions", "id": v["id"],
                                                             "attributes": {"copyright": meta["copyright"], "releaseType": "AFTER_APPROVAL"}}})
    print("  copyright")
    upsert_localizations(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations", "appStoreVersionLocalizations",
                         "appStoreVersion", "appStoreVersions", v["id"],
                         # What's New exists only for updates, so a first version's metadata leaves it out.
                         lambda v: {k: v[k] for k in ("description", "keywords", "promotionalText", "supportUrl", "marketingUrl", "whatsNew")
                                    if k in v})


def step_price():
    a = app()
    price = META["app"]["price"]
    points = api("GET", f"/v1/apps/{a['id']}/appPricePoints?filter[territory]={price['baseTerritory']}&limit=200")["data"]
    point = next(p for p in points if float(p["attributes"]["customerPrice"]) == float(price["customerPrice"]))
    api("POST", "/v1/appPriceSchedules", {
        "data": {"type": "appPriceSchedules", "relationships": {
            "app": ref("apps", a["id"]), "baseTerritory": ref("territories", price["baseTerritory"]),
            "manualPrices": {"data": [{"type": "appPrices", "id": "${base}"}]}}},
        "included": [{"type": "appPrices", "id": "${base}", "attributes": {"startDate": None},
                      "relationships": {"appPricePoint": ref("appPricePoints", point["id"])}}]})
    print(f"  {price['customerPrice']} in {price['baseTerritory']}, equalised everywhere else")


def step_availability():
    a = app()
    territories = [t["id"] for t in api("GET", "/v1/territories?limit=200")["data"]]
    api("POST", "/v2/appAvailabilities", {
        "data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True}, "relationships": {
            "app": ref("apps", a["id"]),
            "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities", "id": f"${{{t}}}"} for t in territories]}}},
        "included": [{"type": "territoryAvailabilities", "id": f"${{{t}}}", "attributes": {"available": True},
                      "relationships": {"territory": ref("territories", t)}} for t in territories]})
    print(f"  {len(territories)} territories")


def step_screenshots():
    a = app()
    v = version(a["id"])
    for loc in api("GET", f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"]:
        locale = loc["attributes"]["locale"]
        folder = os.path.join(ROOT, "AppStore", "screenshots", locale)
        if not os.path.isdir(folder):
            continue
        sets = api("GET", f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]
        desktop = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == "APP_DESKTOP"), None)
        if desktop:
            for shot in api("GET", f"/v1/appScreenshotSets/{desktop['id']}/appScreenshots")["data"]:
                api("DELETE", f"/v1/appScreenshots/{shot['id']}")
        else:
            desktop = api("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets",
                          "attributes": {"screenshotDisplayType": "APP_DESKTOP"},
                          "relationships": {"appStoreVersionLocalization": ref("appStoreVersionLocalizations", loc["id"])}}})["data"]
        for name in sorted(os.listdir(folder)):
            if not name.endswith(".png"):
                continue
            data = open(os.path.join(folder, name), "rb").read()
            shot = api("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots",
                       "attributes": {"fileName": f"{locale}-{name}", "fileSize": len(data)},
                       "relationships": {"appScreenshotSet": ref("appScreenshotSets", desktop["id"])}}})["data"]
            for op in shot["attributes"]["uploadOperations"]:
                part = data[op["offset"]:op["offset"] + op["length"]]
                request = urllib.request.Request(op["url"], data=part, method=op["method"],
                                                 headers={h["name"]: h["value"] for h in op["requestHeaders"]})
                urllib.request.urlopen(request).read()
            api("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
                "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
            print(f"  {locale}/{name}")


def step_review():
    a = app()
    v = version(a["id"])
    # The contact is whatever App Store Connect has, unless given here.
    attributes = {"demoAccountRequired": False, "notes": META["review"]["notes"]}
    for key, env in [("contactFirstName", "REVIEW_FIRST"), ("contactLastName", "REVIEW_LAST"),
                     ("contactPhone", "REVIEW_PHONE"), ("contactEmail", "REVIEW_EMAIL")]:
        if os.environ.get(env):
            attributes[key] = os.environ[env]
    current = api("GET", f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail", ok=(200, 404)).get("data")
    if current:
        api("PATCH", f"/v1/appStoreReviewDetails/{current['id']}",
            {"data": {"type": "appStoreReviewDetails", "id": current["id"], "attributes": attributes}})
    else:
        api("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attributes,
            "relationships": {"appStoreVersion": ref("appStoreVersions", v["id"])}}})
    print("  review contact and notes")


def step_build():
    a = app()
    v = version(a["id"])
    for _ in range(60):
        builds = api("GET", f"/v1/builds?filter[app]={a['id']}&sort=-uploadedDate&limit=1")["data"]
        if builds and builds[0]["attributes"]["processingState"] == "VALID":
            api("PATCH", f"/v1/appStoreVersions/{v['id']}/relationships/build", {"data": {"type": "builds", "id": builds[0]["id"]}})
            print(f"  build {builds[0]['attributes']['version']} attached")
            return
        state = builds[0]["attributes"]["processingState"] if builds else "not uploaded yet"
        print(f"  waiting for the build: {state}")
        time.sleep(30)
    raise SystemExit("The build did not finish processing in 30 minutes.")


def step_submit():
    a = app()
    v = version(a["id"])
    # A submission left open by an earlier try is used again; there can only be one.
    open_ones = api("GET", f"/v1/reviewSubmissions?filter[app]={a['id']}&filter[platform]=MAC_OS&filter[state]=READY_FOR_REVIEW")["data"]
    submission = open_ones[0] if open_ones else api("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
                     "attributes": {"platform": "MAC_OS"}, "relationships": {"app": ref("apps", a["id"])}}})["data"]
    items = api("GET", f"/v1/reviewSubmissions/{submission['id']}/items")["data"]
    if not items:
        reply = api("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": ref("reviewSubmissions", submission["id"]),
            "appStoreVersion": ref("appStoreVersions", v["id"])}}}, ok=(201, 409))
        if reply.get("errors"):
            # Apple says what is missing in the errors' metadata.
            reasons = [x.get("detail", "") for e in reply["errors"] for group in (e.get("meta") or {}).values()
                       for entry in (group if isinstance(group, list) else [group]) if isinstance(entry, dict)
                       for found in entry.values() for x in (found if isinstance(found, list) else [found]) if isinstance(x, dict)]
            raise SystemExit("Not ready for review: " + ("; ".join(r for r in reasons if r) or reply["errors"][0].get("detail", "")))
    api("PATCH", f"/v1/reviewSubmissions/{submission['id']}",
        {"data": {"type": "reviewSubmissions", "id": submission["id"], "attributes": {"submitted": True}}})
    print("  submitted for review")


if __name__ == "__main__":
    steps = sys.argv[1:] or ["status"]
    for name in steps:
        print(name)
        globals()[f"step_{name}"]()

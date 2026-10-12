#!/usr/bin/env python3
"""Merge the strings Xcode extracted at build time into Strata/Resources/Localizable.xcstrings.

    xcodebuild -scheme Strata -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build build
    xcodebuild -scheme StrataMac -destination 'platform=macOS' -derivedDataPath build-mac build
    python3 Tools/sync_strings.py

Existing entries (translations, comments, plural variations) are kept; new keys are added; keys that
are no longer used are marked stale so they can be reviewed. English only: the key is the English text.
"""
import glob, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Strata/Resources/Localizable.xcstrings")
DATA = glob.glob(os.path.join(ROOT, "build/Build/Intermediates.noindex/Strata.build/*/Strata.build/Objects-normal/*/*.stringsdata"))
# The Mac target shares the sources and adds a few strings of its own (build it into ./build-mac).
DATA += glob.glob(os.path.join(ROOT, "build-mac/Build/Intermediates.noindex/Strata.build/*/StrataMac.build/Objects-normal/*/*.stringsdata"))

# Keys that need plural variations: key -> (one, other). `%lld` is the count.
PLURALS = {
    "%lld searches": ("%lld search", "%lld searches"),
    "%lld pages": ("%lld page", "%lld pages"),
    "%lld results": ("%lld result", "%lld results"),
    "%lld models": ("%lld model", "%lld models"),
    "Fetched %lld models.": ("Fetched %lld model.", "Fetched %lld models."),
}

# Placeholders and examples that must not be translated.
NO_TRANSLATE = {"%lld", "[%lld]", "262144", "https://host/v1", "model-id", "sk-…", "Name: value"}

def plural_entry(one, other):
    unit = lambda s: {"stringUnit": {"state": "translated", "value": s}}
    return {"localizations": {"en": {"variations": {"plural": {"one": unit(one), "other": unit(other)}}}}}

def main():
    if not DATA:
        sys.exit("no .stringsdata found; build the Strata scheme first")
    found = {}
    for path in DATA:
        table = json.load(open(path)).get("tables", {}).get("Localizable", [])
        for item in table:
            found.setdefault(item["key"], item.get("comment", ""))
    catalog = json.load(open(CATALOG))
    strings = catalog.setdefault("strings", {})
    for key, comment in sorted(found.items()):
        entry = strings.setdefault(key, {})
        if comment and "comment" not in entry:
            entry["comment"] = comment
        entry.pop("extractionState", None)
        if key in NO_TRANSLATE:
            entry["shouldTranslate"] = False
        if key in PLURALS and "localizations" not in entry:
            entry.update(plural_entry(*PLURALS[key]))
    for key, entry in strings.items():
        if key not in found:
            entry["extractionState"] = "stale"
    catalog["sourceLanguage"] = "en"
    catalog["version"] = "1.0"
    with open(CATALOG, "w") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    missing = [k for k in PLURALS if k not in found]
    print(f"{len(found)} keys; {sum(1 for e in strings.values() if e.get('extractionState') == 'stale')} stale")
    if missing:
        print("plural keys not found in sources:", ", ".join(missing))

main()

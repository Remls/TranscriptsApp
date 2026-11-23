"""Writes assets/languages.json from Unicode CLDR data, as packaged by Babel.

Run with Babel installed: python tool/languages_table.py
"""

import json
from pathlib import Path

from babel import Locale, localedata
from babel.core import get_global

SCRIPT_NAMES = {
    "Hans": "Simplified Chinese characters",
    "Hant": "Traditional Chinese characters",
    "Jpan": "Japanese (kanji + hiragana/katakana)",
    "Kore": "Hangul",
}


def main():
    likely = get_global("likely_subtags")
    english = Locale("en")
    codes = sorted({i.split("_")[0] for i in localedata.locale_identifiers()})
    table = []
    for code in codes:
        if not code.isalpha() or code == "root" or code not in likely:
            continue
        name = english.languages.get(code)
        script = likely[code].split("_")[1]
        locale = Locale.parse(code)
        if not name:
            continue
        table.append(
            {
                "code": code,
                "name": name,
                "native": locale.display_name or "",
                "script": SCRIPT_NAMES.get(script)
                or english.scripts.get(script, script),
                "rtl": locale.character_order == "right-to-left",
            }
        )
    out = Path(__file__).resolve().parent.parent / "assets" / "languages.json"
    out.write_text(
        json.dumps(table, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    print(f"{len(table)} languages written to {out}")


if __name__ == "__main__":
    main()

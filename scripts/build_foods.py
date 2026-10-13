#!/usr/bin/env python3
"""Builds Sated/Resources/Foods/foods.json from USDA FoodData Central CSV downloads.

Download the CSV versions of "SR Legacy" and "Survey (FNDDS)" from
https://fdc.nal.usda.gov/download-datasets, unzip them into data-src/, then:

    python3 scripts/build_foods.py data-src Sated/Resources/Foods/foods.json

Every folder under data-src with a food.csv is read, so newer FNDDS releases drop in as is.

- FNDDS foods are foods as people eat them ("Pizza, cheese, thin crust", "Burrito with beef
  and beans") with household portions ("1 slice", "1 burrito"). They rank first in search.
- SR Legacy adds ingredients and basic foods, plus USDA's fast-food and restaurant items.

Each food gets a default serving (its first household portion, or 100 g) and up to eight other
portions with their weights; the app rescales nutrients by weight when one is picked. Food
IDs are "usda.<fdc_id>". FoodData Central is public domain (CC0); Settings › About credits it.
"""
import csv
import json
import re
import sys
from pathlib import Path

# Energy, then the Atwater general and specific factors. FNDDS files use the older nutrient
# numbers (208 = energy), SR Legacy and Foundation the newer ids (1008).
ENERGY_KCAL = ("1008", "208", "2047", "2048")
MACROS = {
    "1003": "protein", "1005": "carbs", "1004": "fat", "1079": "fiber",
    "203": "protein", "205": "carbs", "204": "fat", "291": "fiber",
}

# SR Legacy categories that rarely answer an everyday search: shown, but after other matches.
SR_LOW = {"Baby Foods", "Spices and Herbs", "American Indian/Alaska Native Foods"}
# SR Legacy categories people search by brand ("mcdonalds big mac"): close to FNDDS.
SR_BRANDS = {"Fast Foods", "Restaurant Foods"}

MAX_PORTIONS = 8


def read(folder: Path, name: str):
    path = folder / name
    if not path.exists():
        return
    with open(path, newline="", encoding="utf-8") as handle:
        yield from csv.DictReader(handle)


def number(text: str) -> float | None:
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


FRACTIONS = {"0.25": "1/4", "0.33": "1/3", "0.5": "1/2", "0.67": "2/3", "0.75": "3/4"}


def tidy(label: str) -> str:
    label = re.sub(r"\s*\((?:include|includes)\b[^)]*\)", "", label, flags=re.I)
    label = re.sub(r",?\s*\bNFS\b", "", label)
    label = re.sub(r"\btablespoons?\b", "tbsp", label)
    label = re.sub(r"\bteaspoons?\b", "tsp", label)
    label = re.sub(r"\s+", " ", label).strip().rstrip(",")
    first, _, rest = label.partition(" ")
    if first in FRACTIONS:
        label = f"{FRACTIONS[first]} {rest}".strip()
    if label.lower() == "quantity not specified":
        return "1 typical serving"
    return label


def skip_portion(label: str) -> bool:
    # FNDDS recipe helpers ("Guideline amount per cup of hot cereal"), not things people eat.
    return label.lower().startswith("guideline amount")


def portion_label(row: dict, units: dict[str, str]) -> str:
    description = (row.get("portion_description") or "").strip()
    if description and description.lower() != "undetermined":
        return tidy(description)
    amount = number(row.get("amount") or "1") or 1
    unit = units.get(row.get("measure_unit_id") or "", "")
    if unit.lower() in ("undetermined", ""):
        unit = ""
    modifier = (row.get("modifier") or "").strip()
    # SR Legacy keeps the unit in the modifier ("cup, chopped") or as a code ("10205").
    if modifier.isdigit():
        modifier = ""
    words = " ".join(part for part in (unit, modifier) if part)
    return tidy(f"{amount:g} {words}" if words else f"{amount:g} serving")


def load(folder: Path, foods: list[dict]) -> int:
    rows = {r["fdc_id"]: r for r in read(folder, "food.csv")}
    if not rows:
        return 0
    data_type = next(iter(rows.values())).get("data_type", "")
    is_fndds = "fndds" in data_type or "survey" in data_type
    categories = {r["id"]: r["description"] for r in read(folder, "food_category.csv")}
    units = {r["id"]: r["name"] for r in read(folder, "measure_unit.csv")}

    per100: dict[str, dict[str, float]] = {}
    energy: dict[str, dict[str, float]] = {}
    for r in read(folder, "food_nutrient.csv"):
        fdc, nid = r["fdc_id"], r["nutrient_id"]
        amount = number(r.get("amount"))
        if fdc not in rows or amount is None:
            continue
        if nid in ENERGY_KCAL:
            energy.setdefault(fdc, {})[nid] = amount
        elif nid in MACROS:
            per100.setdefault(fdc, {})[MACROS[nid]] = amount

    portions: dict[str, list[tuple[int, str, float]]] = {}
    for r in read(folder, "food_portion.csv"):
        grams = number(r.get("gram_weight"))
        if not grams or grams <= 0:
            continue
        seq = int(number(r.get("seq_num")) or 99)
        label = portion_label(r, units)
        if not skip_portion(label):
            portions.setdefault(r["fdc_id"], []).append((seq, label, grams))

    added = 0
    for fdc, row in rows.items():
        found = energy.get(fdc, {})
        kcal = next((found[n] for n in ENERGY_KCAL if n in found), None)
        if kcal is None:
            continue
        macros = per100.get(fdc, {})
        # FNDDS marks generic foods "NFS" (not further specified): "Rice, fried, NFS".
        name = re.sub(r",\s*NFS\b", "", re.sub(r"\s+", " ", row["description"])).strip()
        lower = name.lower()

        if is_fndds:
            rank = 30 if ("baby food" in lower or "infant formula" in lower) else 0
        else:
            category = categories.get(row.get("food_category_id") or "", "")
            rank = 30 if category in SR_LOW else 4 if category in SR_BRANDS else 10
            if ", raw" in lower:
                rank += 3

        seen, measures = set(), []
        for _, label, grams in sorted(portions.get(fdc, [])):
            if label in seen:
                continue
            seen.add(label)
            measures.append((label, round(grams, 1)))
        # Default serving: FNDDS's "typical serving" is the average amount people eat, so the
        # named measure closest to it in weight ("1 banana", "1 regular burrito") is the default.
        # Without one, the first household measure; without any, 100 g.
        named = [m for m in measures if m[0] != "1 typical serving"]
        typical = next((m[1] for m in measures if m[0] == "1 typical serving"), None)
        if named and typical:
            # Prefer measures no bigger than a typical serving: a slice of pizza, not a whole one.
            smaller = [m for m in named if m[1] <= typical * 1.25] or named
            default = min(smaller, key=lambda m: abs(m[1] - typical) / typical)
        else:
            default = named[0] if named else measures[0] if measures else ("100 g", 100.0)
        # Pizza and pies: a typical serving is two slices, but people log by the slice.
        medium_piece = next((m for m in named if re.match(r"1 (piece|slice), medium", m[0])), None)
        if medium_piece:
            default = medium_piece
        others = [m for m in measures if m != default][:MAX_PORTIONS]
        factor = default[1] / 100

        food = {
            "id": f"usda.{fdc}",
            "name": name,
            "serving": default[0],
            "grams": default[1],
            "calories": round(kcal * factor),
            "protein": round(macros.get("protein", 0) * factor, 1),
            "carbs": round(macros.get("carbs", 0) * factor, 1),
            "fat": round(macros.get("fat", 0) * factor, 1),
            "fiber": round(macros.get("fiber", 0) * factor, 1),
        }
        if others:
            food["portions"] = [[label, grams] for label, grams in others]
        if rank:
            food["rank"] = rank
        foods.append(food)
        added += 1
    print(f"{folder.name}: {added} foods ({'FNDDS' if is_fndds else 'SR Legacy / other'})")
    return added


def main(source: str, destination: str) -> None:
    root = Path(source).expanduser()
    folders = sorted({p.parent for p in root.rglob("food.csv")})
    if not folders:
        sys.exit(f"No food.csv found under {root}")
    foods: list[dict] = []
    for folder in folders:
        load(folder, foods)
    foods.sort(key=lambda f: (f.get("rank", 0), f["name"].lower()))
    Path(destination).write_text(json.dumps(foods, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    size = Path(destination).stat().st_size / 1_000_000
    print(f"Wrote {len(foods)} foods to {destination} ({size:.1f} MB)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])

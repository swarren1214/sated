#!/usr/bin/env python3
"""Builds Sated/Resources/Foods/foods.json from a USDA FoodData Central CSV download.

Download "Foundation Foods" or "SR Legacy" (CSV) from
https://fdc.nal.usda.gov/download-datasets and unzip it, then:

    python3 scripts/build_foods.py ~/Downloads/FoodData_Central_sr_legacy_food_csv_2018-04 \
        Sated/Resources/Foods/foods.json

Each food gets one serving: its first household portion from food_portion.csv
("1 cup", "1 medium"), or 100 g when it has none. Nutrients are scaled to that serving.
FoodData Central data is public domain (CC0); credit it in the app (Settings › About).

The output replaces the hand-made starter list. Food IDs are "usda.<fdc_id>", so entries
logged from the starter list (IDs like "usda.banana") keep working: they still carry their
own nutrients and just won't match a bundled food for Recent.
"""
import csv
import json
import sys
from pathlib import Path

# FoodData Central nutrient ids.
ENERGY_KCAL = {"1008", "2047", "2048"}  # Energy; Atwater general and specific factors
PROTEIN = "1003"
CARBS = "1005"
FAT = "1004"
FIBER = "1079"


def read(folder: Path, name: str):
    with open(folder / name, newline="", encoding="utf-8") as handle:
        yield from csv.DictReader(handle)


def portion_label(row) -> str:
    amount = row.get("amount") or "1"
    try:
        amount = f"{float(amount):g}"
    except ValueError:
        pass
    unit = (row.get("modifier") or row.get("portion_description") or "").strip()
    return f"{amount} {unit}".strip() if unit else f"{amount} serving"


def main(source: str, destination: str) -> None:
    folder = Path(source).expanduser()
    foods = {row["fdc_id"]: row["description"] for row in read(folder, "food.csv")}

    per100: dict[str, dict[str, float]] = {}
    for row in read(folder, "food_nutrient.csv"):
        fdc, nid = row["fdc_id"], row["nutrient_id"]
        if fdc not in foods:
            continue
        key = "calories" if nid in ENERGY_KCAL else {PROTEIN: "protein", CARBS: "carbs", FAT: "fat", FIBER: "fiber"}.get(nid)
        if key is None or not row["amount"]:
            continue
        # Keep the first energy value found; later Atwater duplicates don't override it.
        per100.setdefault(fdc, {}).setdefault(key, float(row["amount"]))

    portions: dict[str, tuple[str, float]] = {}
    portion_file = folder / "food_portion.csv"
    if portion_file.exists():
        for row in read(folder, "food_portion.csv"):
            fdc = row["fdc_id"]
            if fdc in portions or not row.get("gram_weight"):
                continue
            portions[fdc] = (portion_label(row), float(row["gram_weight"]))

    out = []
    for fdc, values in per100.items():
        if "calories" not in values:
            continue
        label, grams = portions.get(fdc, ("100 g", 100.0))
        factor = grams / 100
        out.append({
            "id": f"usda.{fdc}",
            "name": foods[fdc],
            "serving": label,
            "grams": round(grams, 1),
            "calories": round(values.get("calories", 0) * factor),
            "protein": round(values.get("protein", 0) * factor, 1),
            "carbs": round(values.get("carbs", 0) * factor, 1),
            "fat": round(values.get("fat", 0) * factor, 1),
            "fiber": round(values.get("fiber", 0) * factor, 1),
        })

    out.sort(key=lambda food: food["name"])
    Path(destination).write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"Wrote {len(out)} foods to {destination}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])

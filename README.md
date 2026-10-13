# Sated

A native iPhone app for tracking calories, protein, carbs, fat and fiber, with day, week and
month summaries and an on-device coach you can type or talk to. SwiftUI with Liquid Glass,
SwiftData for the log, the user's own iCloud as the only backend, and Apple's on-device model
for the coach. No accounts and no servers.

Requires Xcode 26 and iOS 26. iPhone only.

## First run

1. Open `Sated.xcodeproj`.
2. Select the **Sated** target › **Signing & Capabilities** and confirm your **Team**
   (it's set to the same team as Hearken).
3. If `com.stephenwarren.sated` isn't available to your team, change the **Bundle Identifier**,
   then update the iCloud container in `Sated.entitlements` and `AppConfig.cloudKitContainerID`
   to match (`iCloud.<your bundle id>`).
4. Set `AppConfig.contactEmail` to a real support address. Open Food Facts asks every app to
   identify itself with one.
5. Run on an iPhone. The camera, Health and Apple Intelligence need a real device; the
   simulator covers everything else. Previews load a sample week (App/PreviewSupport.swift).

The entitlements include HealthKit, CloudKit and iCloud key-value storage. Automatic signing
registers them for your team the first time you build.

## Turning on iCloud sync

The log is saved on the device while `AppConfig.cloudSyncEnabled` is `false`. To sync through
the user's private iCloud database:

1. In **Signing & Capabilities**, confirm the iCloud container is checked under **CloudKit**.
   Push Notifications and Remote notifications are already set in the entitlements and Info.plist.
2. Set `AppConfig.cloudSyncEnabled = true` and run once on a device signed in to iCloud.
3. In the CloudKit Console, deploy the development schema to production before TestFlight.

`FoodEntry` already follows CloudKit's rules: every property has a default and nothing is unique.

## Food data, with no backend

- **Search** runs against foods bundled in `Sated/Resources/Foods/foods.json`, so it works
  offline with no API key or rate limit. The file in this build is a 64-food starter list with
  values rounded from USDA FoodData Central. Replace it with the full USDA list:

  ```sh
  # Download "SR Legacy" or "Foundation Foods" (CSV) from https://fdc.nal.usda.gov/download-datasets
  python3 scripts/build_foods.py ~/Downloads/FoodData_Central_sr_legacy_food_csv_2018-04 \
      Sated/Resources/Foods/foods.json
  ```

  FoodData Central is public domain (CC0); Settings › About credits it.
- **Barcodes** are looked up in Open Food Facts straight from the phone
  (`Services/Food/OpenFoodFacts.swift`). Reads are limited to 15 a minute per person, which
  one-at-a-time scanning never reaches. Sated never calls their search API, which is limited much
  more tightly. The data is ODbL; Settings › About credits it.
- **Nutrition labels** are read entirely on the iPhone: VisionKit recognizes the text and the
  on-device model copies the numbers into a structured label (`Services/Coach/LabelReader.swift`).

## On-device AI

All of it uses the Foundation Models framework, so nothing leaves the phone.

- **Coach** (`Services/Coach/CoachEngine.swift`) has three tools: today's or a past day's log,
  the last seven days, and a USDA food lookup. Its instructions require every number to come
  from a tool. Food suggestions come back as structured output and show a one-tap
  "Log to Dinner" card.
- **Say It** (`Features/Log/VoiceLogView.swift`) transcribes on device, asks the model only to
  split the sentence into foods and amounts, then matches each food in the bundled database.
  Nothing is logged until the person confirms (Settings › Coach › Confirm Voice Entries).
- **Summaries** on Today and Trends are written by code in `Models/Summaries.swift`, not by the
  model, so their numbers are always exact.

Coach, Say It and label scanning need Apple Intelligence (iPhone 15 Pro or newer). On other
iPhones the Coach tab and those buttons are hidden and everything else works.

## What's built (milestone 1)

- **Tab bar**: the system Liquid Glass `TabView` with Today, Trends and Coach, and Add Food as
  the separate round + button. That's the search tab, the only tab iOS draws in its own circle;
  `tabViewSearchActivation(.searchTabSelection)` opens it with the search field ready.
  Minimizes on scroll.
- **Today**: calories-left ring with eaten, goal and active energy from Health; protein, carbs,
  fat and fiber rings; a summary of what's left; the four meals; logging streak.
- **Meals**: entries for one meal, swipe to delete, tap to change servings or move meals.
- **Add Food**: meal picker, search, Scan, Say It, Quick Add, "Fits what's left today"
  suggestions and Recent. The plus on a row adds one serving at once; tapping opens the detail.
- **Food detail**: serving, servings stepper, meal, calories and macros against goals.
- **Scan**: barcode lookup with Details and Add, and Nutrition Label mode.
- **Say It**: listening waveform, transcript, then a confirm card with per-item servings.
- **Coach**: chat with starter prompts, ask out loud, suggested plates you can log.
- **Trends**: Day (macro split, timeline, against goals), Week (Swift Charts bars colored by
  target status, goal line, hit rates, daily averages) and Month (calendar heatmap, last-month
  comparison), each with a written summary.
- **Settings**: daily goals, Apple Health, Coach, appearance and accent, CSV export, credits.
- **Apple Health**: each entry saves dietary energy, protein, carbs, fat and fiber, tagged with
  the entry's ID so edits and deletes stay in step. Reads today's active energy.
- **Tests**: Swift Testing for the summary math, streaks, Open Food Facts parsing, search and
  voice amount conversion (⌘U).

## Project layout

```
Sated/
  App/            App entry, tab bar, configuration, preview data
  DesignSystem/   Accent and appearance options, macro colors, shared components
  Features/       Today, Log (Add Food, detail, scan, voice, quick add), Coach, Trends, Settings
  Models/         SwiftData FoodEntry, nutrients and goals, summary math
  Resources/      Bundled foods
  Services/       Food (database, Open Food Facts), Health, Coach (model, tools, parsers), Voice
SatedTests/       Swift Testing
scripts/          build_foods.py (USDA import)
```

## Next up

- Run the USDA import and check the result size; move search to SQLite FTS if it passes ~20,000 foods.
- Check scanned barcodes against USDA branded foods (which carry UPCs) before Open Food Facts.
- Let people name and save scanned-label foods as favorites.
- Turn on CloudKit sync; sync goals through iCloud key-value storage.
- Widgets for the calorie ring and macros, App Intents ("Log my usual breakfast"), and the
  Action button.
- Replace SFSpeechRecognizer with SpeechAnalyzer in `Services/Voice/Dictation.swift`.
- A real app icon (the current one is a placeholder: a sun rising out of a bowl).

Sated is for general wellness and isn't medical advice.

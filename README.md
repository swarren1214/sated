# Sated

A native iPhone app for tracking calories, protein, carbs, fat and fiber, with day, week and
month summaries and an on-device coach you can type or talk to. SwiftUI with Liquid Glass,
SwiftData for the log, the user's own iCloud for personal data, and Apple's on-device model
for the coach. A silent anonymous Supabase session authenticates optional shared API calls; no
food log or health data is stored there.

Requires Xcode 26 and iOS 26 or iPadOS 26. iPhone and iPad.

## First run

1. Open `Sated.xcodeproj`.
2. Select the **Sated** target › **Signing & Capabilities** and confirm your **Team**
   (it's set to the same team as Hearken).
3. If `com.stephenwarren.sated` isn't available to your team, change the **Bundle Identifier**,
   then update the iCloud container in `Sated.entitlements` and `AppConfig.cloudKitContainerID`
   to match (`iCloud.<your bundle id>`).
4. Set `AppConfig.contactEmail` to a real support address. Open Food Facts asks every app to
   identify itself with one.
5. Run on an iPhone. The camera, Health and the on-device model need a real device; the
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

- **Search** runs against about 13,000 foods bundled in `Sated/Resources/Foods/foods.json`
  (3.2 MB), so it works offline with no API key or rate limit. They come from two USDA
  FoodData Central datasets: **FNDDS** (foods as people eat them, like "Pizza, cheese, thin
  crust" or "Burrito, chicken, cheese", ranked first) and **SR Legacy** (ingredients and basic
  foods, plus USDA's fast-food and restaurant items). Every food has its household measures
  ("1 slice", "1 cup", "1 medium") as well as ounces and 100 g; the detail screen rescales
  nutrients by weight. To rebuild it, download the CSV versions of both from
  https://fdc.nal.usda.gov/download-datasets, unzip them into `data-src/` (ignored by git),
  then:

  ```sh
  python3 scripts/build_foods.py data-src Sated/Resources/Foods/foods.json
  ```

  The script keeps only names, the five nutrients Sated tracks and the portions, picks each
  food's default serving (the household measure closest to what people typically eat), and
  sets its search rank. Search itself (`Services/Food/FoodDatabase.swift`) favors the main word
  of a name ("banana" finds bananas before banana bread), knows a few everyday words USDA
  spells differently ("fries", "soda", "ketchup"), and keeps baby food out of the way.
  FoodData Central is public domain (CC0); Settings › About credits it.
- **Barcodes** are looked up in Open Food Facts straight from the phone
  (`Services/Food/OpenFoodFacts.swift`). Reads are limited to 15 a minute per person, which
  one-at-a-time scanning never reaches. Sated never calls their search API, which is limited much
  more tightly. The data is ODbL; Settings › About credits it.
- **Nutrition labels** are read entirely on the device, without the AI model in the normal case
  (`Services/Food/LabelParser.swift`, `Features/Log/LabelScan.swift`):
  1. **Find the panel.** Of everything the camera reads, only text near the "Nutrition Facts"
     heading and the panel's own words (Calories, Total Fat, Sodium…) counts, plus the values on
     those rows. Front-of-package claims and ingredients are left out. The panel is outlined live.
  2. **Read it with rules.** The format is regulated, so "Calories 230", "Total Fat 8g",
     "<1g", per-serving columns and Canada's bilingual labels are matched directly, with common
     camera slips fixed ("Og" → "0g"). Nothing is estimated.
  3. **Vote and check.** Each value has to be read the same way three times, and calories have
     to agree with 4/4/9 × protein/carbs/fat within 25%. Numbers that don't add up are read again,
     then flagged.
  4. **Review.** It stops by itself, takes a picture of the panel, and shows every value to check
     and edit before adding. If it's stuck, Read with AI (the on-device model, given only the
     panel's text, `Services/Coach/LabelReader.swift`) and Enter Manually appear.

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

Coach, Say It and label scanning need an iPhone that runs Apple's on-device model (iPhone 15 Pro or newer). The app never names the system feature; it says "your iPhone's built-in AI". On other
iPhones the Coach tab and those buttons are hidden and everything else works.

## Coach's voice (Kokoro, on device)

Talking to Coach runs entirely on the iPhone: speech-to-text, the on-device model, and the
spoken reply.

- **Hands free.** The microphone stays on while the voice screen is open
  (`Services/Voice/Conversation.swift`). Pause for a moment (Short, Medium or Long in
  Settings › Coach) and Coach answers out loud, then listens again. Start talking while it
  thinks or speaks and it stops to listen. After 45 seconds of quiet the microphone turns off
  until Resume.
- **Voice processing.** The microphone and Coach's voice share one audio engine with Apple's
  voice processing on: echo cancellation (so Coach doesn't hear itself and you can talk over
  it) and noise suppression. The mic button on the voice screen opens the system Mic Mode
  menu, where Voice Isolation keeps background voices out. Words that only repeat what Coach
  is saying are ignored, in case any of its voice leaks through.

- Spoken replies use **Kokoro**, the same neural voice as Hearken. `Packages/KokoroSwift` and
  `Packages/MisakiSwift` are Hearken's vendored copies (MIT and Apache 2.0), built as static
  libraries; MLX comes from `mlx-swift` 0.29.1. The voice styles ship in the app
  (`Sated/Resources/Kokoro/kokoro-voices.bin`, ~14 MB).
- The model itself (~330 MB) downloads once, when the person taps Download in Settings › Coach or
  on the voice screen. It's checked by SHA-256 and kept out of iCloud backups
  (`Services/Voice/KokoroVoice.swift`). After that, nothing leaves the phone.
- The model is shared with Hearken (and any later app) through the App Group
  `group.com.stephenwarren.voice`, so it's downloaded once per iPhone. Whichever app gets it
  first puts it in the group's folder; the others find it there. Removing it in one app removes
  it for all of them. Each app still loads it into its own memory when it speaks.
- Until it's downloaded, and in the Simulator (MLX needs a real GPU), Coach speaks with the best
  Apple voice installed (`Services/Voice/CoachSpeaker.swift`).
- The first build fetches mlx-swift, which takes a few minutes.

## iPad

- The tab bar becomes iPad's top tab bar, which opens into a sidebar; tab names show there.
- Today puts the calorie card, macros and summary on the left and the meals on the right.
  Trends, Coach, Add Food and the voice screens keep a comfortable reading width.
- Every orientation and multitasking size works; the layouts switch on horizontal size class,
  so a narrow Split View or Slide Over window gets the iPhone layout.
- With a keyboard: ⌘N opens Add Food, ⌘1 to ⌘3 switch tabs (also in the menu bar).
- Text that names the device says "iPad" there (`DeviceName` in `DesignSystem/Theme.swift`).
- Widgets work on the iPad Home Screen too, including an extra-large Today.

## Widgets

The **SatedWidgets** extension (`SatedWidgets/`) has two widgets:

- **Calories Left**: Home Screen small (calorie ring), and Lock Screen circular gauge,
  rectangular (kcal left, a bar, protein/carbs/fat) and inline.
- **Today**: medium (ring and all four macros against goals) and large (adds the meals and the
  last seven days against the goal line). The + opens Add Food.

The widgets don't read the database. The app writes a small `WidgetSnapshot` (`Shared/`, built
into both targets) to the `group.com.stephenwarren.sated` App Group whenever the log is saved,
a setting changes, the day turns over or the app goes to the background
(`Services/WidgetSync.swift`), and asks WidgetKit to redraw. At midnight the widgets start the
new day empty on their own. Taps open `sated://today`, `sated://add` or `sated://trends`.
Ring colors follow the accent picked in Settings; the important parts are marked accentable,
so tinted and clear Home Screens look right.

## Logging other days

Today has a calendar button next to Settings (a sideways swipe moves a day at a time). Everything
logged while another day is showing goes to that day, at the current time of day. Coach's
suggested plates always go to today.

## What's built (milestone 1)

- **Tab bar**: the system Liquid Glass `TabView` with Today, Trends and Coach, and Add Food as
  the separate round + button. That's the search tab, the only tab iOS draws in its own circle;
  `tabViewSearchActivation(.searchTabSelection)` opens it with the search field ready.
  Minimizes on scroll.
- **Today**: calories-left ring with eaten, goal and active energy from Health; protein, carbs,
  fat and fiber rings; a summary of what's left; the four meals; logging streak.
- **Meals**: entries for one meal, swipe to delete, tap to change servings or move meals.
- **Add Food**: meal picker, search, Scan, Say It, Quick Add, "Fits what's left today"
  suggestions and Recent. Tapping a food opens the detail.
- **Food detail**: serving picker (household measures, ounces, 100 g), servings stepper, meal, calories and macros against goals.
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
  Services/       Food (database, Open Food Facts), Health, Coach (model, tools, parsers),
                  Voice (dictation, Kokoro, spoken replies)
Packages/         KokoroSwift and MisakiSwift (vendored from Hearken)
SatedTests/       Swift Testing
scripts/          build_foods.py (USDA import)
```

## Next up

- Offline barcodes: USDA's branded foods (~400,000, with UPCs) as an optional download, like the voice.
- Let people name and save scanned-label foods as favorites.
- Turn on CloudKit sync; sync goals through iCloud key-value storage.
- App Intents ("Log my usual breakfast"), a Control Center "Log Food" control, and the
  Action button.
- Replace SFSpeechRecognizer with SpeechAnalyzer in `Services/Voice/Dictation.swift`.
- A real app icon (the current one is a placeholder: a sun rising out of a bowl).

Sated is for general wellness and isn't medical advice.

## Shared API identity

Sated silently creates and refreshes an anonymous Supabase session in the Keychain, then uses
its bearer token for the shared Lifestyle API. The app remains usable offline and does not upload
food logs, health data, or coach conversations.

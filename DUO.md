# Sated on iPhone Duo

Work from the "Hearth on iPhone Duo" canvas, done overnight without a compiler. Nothing is
committed: review with `git diff` and `git status`. Build it first; see "Compile risks" below.

## What changed

- `Sated/App/SatedApp.swift`: `.hearthDuoPose()` on the scene root (`AppRoot`), outside the tab
  view, so every screen can read `\.hearthDuoPose`.
- `Sated/Features/Today/TodayView.swift`
  - `TodayView` reads the pose and holds the Duo state (chosen meal, open Say It / label scan /
    Coach voice / board, paywall) above the pose layouts and above `DayLog`, so it survives
    folding, opening, closing and day changes.
  - Toolbar per pose: Outer has Scan a Label as the only rail action, with Choose Day, What
    Still Fits and Profile in the overflow (`.secondaryAction`, menu icons in the text color).
    Open wide adds Add Food and Log by Voice. Laptop adds the What Still Fits board button.
    Other poses keep the streak badge, Choose Day and the profile photo as before.
  - `DayLog.poseLayout` switches the day's layout by pose (below). The old iPad split now also
    turns off when folded (each page is only half the screen).
  - New private views: `SayItCard`, `DiaryMealRow`, `MealNutrientsPane` (even two-column grid
    via `HearthEvenColumns.flexible(2)`).
  - Day picker's Today button now has a symbol (`arrow.uturn.backward`).
- `Sated/Features/Duo/CoachDuo.swift` (new)
  - `CoachEngine.latestSuggestion`, `latestReply`, and `logSuggestion(_:in:)`: the one place a
    Coach plate gets logged (Coach tab, Book, Laptop and Tent all use it).
  - `CoachPagePane`: the Coach conversation as a page with Ask Coach at the bottom (Book).
  - `CoachCounterView`: "Coach at the counter" (Laptop), built on `HearthFoldOverlay`.
  - `WhatStillFitsBoard`: the Tent board, built on `HearthGlanceBoard`.
- `Sated/Features/Coach/CoachView.swift`: `MessageBubble` is no longer private (Book reuses it);
  logging goes through `coach.logSuggestion`; Clear has a symbol.
- `Sated/Features/Log/ScannerView.swift`: an `init` with `startingMode`, so Scan a Label opens
  straight into Nutrition Label mode. Existing calls are unchanged.
- `Sated/Features/Log/VoiceLogView.swift`: on a short screen (the outer display, big text) the
  transcript and the found foods scroll instead of clipping (`ViewThatFits`). Same layout as
  before when it fits.
- `Sated/Features/Log/LabelScan.swift`: Scan Again has a symbol.
- `Sated/Features/EatOut/RestaurantMenuView.swift`: Your Plate's Clear has a trash symbol.

## How each pose behaves

- **Closed (outer display), "Just say it".** Today shows the day's title, a big Say What You
  Ate card, then the meals. The card opens Say It, which keeps the transcript on screen above
  the foods it found; check, then Log. Scan a Label is the rail's one action. The entry goes in
  the same log, so opening the phone shows it in the diary.
- **Open tall (inner portrait), "Today".** Unchanged: standard bars, calorie ring and macros
  first, then the meals. An empty dinner says "Not logged yet". Logging Coach's dinner from any
  pose updates the ring and macros at once (SwiftData query).
- **Open wide (inner landscape), "Diary and nutrients".** `HearthFoldSplit`: the day's meals on
  the leading pane (tap one to choose it), the chosen meal's calories, share of the day and four
  macros on the trailing pane in a two-column grid, with its foods and Edit (opens the same
  MealView). Add Food (to the chosen meal) and Log by Voice are on the rail.
- **Book (folded, held), "Meals beside Coach".** Left page: the normal Today (stacked). Right
  page: the Coach conversation with Ask Coach (text, or the mic for the hands-free voice screen)
  at the bottom. Log to Dinner on a suggestion updates the left page right away. Coach runs on
  the iPhone as today.
- **Laptop (folded, set down), "Coach at the counter".** Upright half: Coach's latest
  suggestion in large type (or a "What should I eat for dinner?" starter). Flat half: what's
  left today (calories, protein, carbs, fat), a big mic (opens the hands-free Coach voice
  screen), and Log to Dinner. The rail has What Still Fits.
- **Tent, "What still fits".** Opened by the person (What Still Fits, in the outer display's
  overflow, or on the rail in Laptop). Two huge numbers: calories left and protein to go. The
  check on the rail logs Coach's latest unlogged suggestion. Screen stays awake; Close (X) ends it.
- Without the on-device model (Coach not offered), Book and Laptop fall back to the normal Today,
  and the Say It card and Log by Voice are hidden, as Say It is elsewhere.
- "Log to Dinner" uses the meal for the time of day (`Meal.suggested()`), the same as the Coach
  tab today; so in the afternoon it reads "Log to Snack".

## Testing in the iPhone Duo simulator

1. Run Sated on the iPhone Duo simulator (iOS 27.1). Log something so Today has data, and have a
   Coach conversation that suggests foods ("What should I eat for dinner?"). Coach needs the
   on-device model; without it, Book and Laptop show the normal Today.
2. **Closed:** Device > Close. Check Scan a Label on the trailing rail and the overflow menu
   (Choose Day, What Still Fits, Profile). Tap Say What You Ate, speak, and log. Open the
   device: the entry is in the diary.
3. **Open tall:** Device > Open, portrait. Today looks as before.
4. **Open wide:** rotate to landscape. Tap meals on the left; the right grid stays two columns
   as you resize. Add Food and Log by Voice on the rail.
5. **Book:** fold partly, held (fold vertical). Day left, Coach right, Ask Coach clear of the
   fold. Log to Dinner from a suggestion; the left page's ring changes at once.
6. **Laptop:** fold partly and set down (fold horizontal). Suggestion on the top half, left
   today / mic / Log to Dinner on the bottom half. Log to Dinner, then unfold: same numbers.
7. **Tent:** close, tap overflow > What Still Fits (or the rail button in Laptop). The check logs
   the suggestion; the numbers drop.
8. Start Say It on the outer display, then open the phone mid-sentence: the screen stays up.
9. Regression: iPhone 17 and iPad in all orientations and Split View; Today, Coach and Add Food
   should look exactly as before (pose is `.standard` there).

## Skipped, and why

- **Live Activity / Lock Screen for Coach's suggestion:** a new target; out of scope.
- **Trends month calendar** uses 7 columns (a week). A week can't be even; left as is. It lives
  on the Trends tab, which has no Duo-specific layout.
- **Coach tab composer** and the **Scanner / voice screens' top bars** are custom, but they're a
  chat composer and full-screen immersive camera and voice layouts, so they stay.
- **`DeviceName`** uses `userInterfaceIdiom`, but only for words ("iPhone"/"iPad"), not layout.
- **Add Food** search tab and **Trends** toolbars were already standard (profile button only).
- **MealView as a split on iPad** (Today → meal): Open wide now shows meal details beside the
  diary; I didn't restructure the iPad navigation into a NavigationSplitView.
- No new server calls and no sample data in production paths.

## Decisions for Steve

1. Outer display: the streak badge and profile photo are off the rail (only Scan a Label is
   there). Profile, Choose Day and What Still Fits are in the overflow. OK?
2. "Log to Dinner" follows the time of day (`Meal.suggested()`), like the Coach tab. Should the
   counter mode always log to Dinner instead?
3. Tent's check logs Coach's latest *unlogged* suggestion; it's disabled when there's none.
4. Book and Laptop's "what's left" uses today, even when Today is showing an earlier day
   (Coach's plates always go to today). The left page in Book shows whatever day is selected.
5. Open wide picks the current meal by default (`Meal.suggested()`) until one is tapped.
6. The day picker's Today button became an icon (`arrow.uturn.backward`). Revert if the text read
   better.
7. These are Duo-only layouts inside Today; the separate Coach tab is unchanged in every pose.

## Compile risks (not built tonight)

- `TodayView.swift:46-68`, `.toolbar { if pose == .outer { … } else { … } }` with
  `.sharedBackgroundVisibility(.hidden)` on an item inside the `else`: should be fine
  (ToolbarContentBuilder supports if/else), but check.
- `TodayView.swift:54`, `ToolbarItemGroup(placement: .secondaryAction)` with
  `Button(_:menuIcon:)` items.
- `TodayView.swift:265,272`, `switch pose { case .book where OnDeviceModel.isOffered: … }` in a
  `@ViewBuilder`.
- `CoachDuo.swift:299`, `CoachCounterView.controls` (a non-builder computed property with `let`s
  then `return VStack`).
- `ScannerView.swift:40`, the new `init` replaces the memberwise one; the only other caller
  (`AddFoodView`) passes `meal:` plus a trailing closure, which still matches.
- `TodayView.swift:331`, `.accessibilityAddTraits(cond ? .isSelected : [])` (type inference).
- `VoiceLogView.swift:53`, `ViewThatFits(in: .vertical)` around the panel: check the review panel still lays out the same on normal iPhones.

## Review (overnight)

A second agent read every changed and new .swift file without a compiler, and checked each symbol against the codebase.

**What was checked**
- Every symbol the new code uses exists with the same name, labels and access level. That covers `Meal.suggested()`, `FoodLog.add`, `CoachEngine.markLogged`/`messages`/`isThinking`/`availability`/`prewarm`/`send`, `CoachMessage.foods`/`logged`/`suggestedTotals`, `Nutrients.summary`, `Grams.text`, `FoodEntry.amountText`/`meal`/`nutrients`, `Card`, `SymbolTile`, `SectionHeader`, `HeaderTitle`, `OnDeviceBadge`, `HearthLockedCard`, `HearthProfilePresenter.shared.show()`, `Button(_:menuIcon:)`, `hearthPaywall(isPresented:feature:)`, `MealView(meal:day:)`, `CoachVoiceView()` and all of the HearthDuo API.
- The project defaults to MainActor isolation, so the `CoachEngine` extension and the views raise no actor errors.
- The flagged spots:
  - `TodayView.swift:46-68`: if/else in `.toolbar` is fine. `ToolbarContentBuilder` supports if/else (since iOS 16), and `.sharedBackgroundVisibility(.hidden)` returns ToolbarContent inside the branch.
  - `TodayView.swift:54`: `ToolbarItemGroup(placement: .secondaryAction)` with `Button(_:menuIcon:)` is fine. The item is a `Button<Label<Text, Image>>`.
  - `TodayView.swift:265,272`: `case .book where OnDeviceModel.isOffered:` is fine. ViewBuilder supports switch with where clauses, and `default` covers the rest.
  - `TodayView.swift:331`: `cond ? .isSelected : []` is fine. Both sides infer `AccessibilityTraits` (an OptionSet).
  - `CoachDuo.swift:299`: `controls` has no `@ViewBuilder`, so `let …; return VStack` is valid.
  - `ScannerView.swift:40`: the explicit init sets every stored property without a default (`meal`, `onAdded`); the others are @State/@Environment with defaults. Both callers compile: `AddFoodView:188` passes `meal:` plus a trailing closure, and `TodayView:109` passes `meal:` and `startingMode:`.
  - `VoiceLogView.swift:53`: `ViewThatFits(in: .vertical)` tries the original Spacer layout first. Spacers have no minimum height beyond 24, so a regular iPhone gets the same layout as before. The ScrollView is used only when that doesn't fit.
- `MessageBubble` is now internal, and no other type in the app, widgets, watch or Shared has that name. `logSuggestion` keeps the Coach tab's behavior the same (one serving of each food to `Meal.suggested()` today, then mark logged), and adds a guard against logging twice.
- No banned APIs are used. `swiftparse` reports 0 errors on all 8 files.

**Fixed**
- `TodayView.swift:107`: in Open wide, Log by Voice now files to the meal chosen in the diary, as Add Food on the rail does. In other poses it still uses the time of day.

**Remaining risks / questions**
- `TodayView.swift:54`: if the outer display's rail ever shows `.secondaryAction` items as rail buttons instead of overflow, the menu-icon images (always-original, label color) will render dark on the color header. Check this in the simulator.
- `CoachDuo.swift:328`: Log to Dinner uses `.glassProminent`, so its icon and text are both white on the app's color, which follows AGENT.md. `CoachDuo.swift:291`'s starter button is `.glass` with `.tint(.primary)`, which is also fine.
- The Laptop layout drops Today's color-header title in favor of "Coach / At the counter". The nav bar title is still the day name.
- The outer pose shows the Say It card and the meals but not the calorie ring. That matches "Just say it", but confirm you're happy without the ring there.

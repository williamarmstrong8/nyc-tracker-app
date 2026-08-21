# NYC Log — Project Context

A private, single-user native iOS app for logging restaurants and bars visited in NYC.

## Architecture

- Native SwiftUI, Xcode 26, iOS 26+ (deployment target `IPHONEOS_DEPLOYMENT_TARGET = 26.5`).
- Targets Apple-Intelligence-capable devices; simulator + non-AI devices supported via fallbacks.
- **Local-only for now**: SwiftData for rows, local files (Application Support) for photos + audio.
- No generative AI. The Speech framework transcribes voice notes on device; nothing rewrites,
  summarises, or tags on the user's behalf.
- A remote sync layer (Supabase) will be added in a later prompt. There is no networking today.
- A separate website will read *published* entries once sync exists. It's not part of this app.

## Data model (SwiftData `@Model`)

Defined in `nyc-tracker/Models/Models.swift`.

- `Place` (class): `id`, `name`, `category`, `neighborhood`, `lat`, `lng`, `externalPOIId?`,
  `visits [Visit]` (cascade). `category` is a computed accessor over `categoryRaw`.
- `Visit` (class): `id`, `visitedOn`, `title`, `tags [String]`, `note`, `rating?`, `address?`,
 `nameOverride?`, `locationSource`, `published`, `createdAt`, `hadVoiceNote`, `rawPlaceGuess?`,
 `kind (visited | wantToTry)`, `place (Place?)`, `photos [Photo]` (cascade).

 **An entry is: date, location, description, photos, tags, verdict.** There is no separate
 transcript / summary / pull quote any more — those three fields existed because an on-device
 model rewrote the user's words, and with the model gone they were the same sentence stored
 three times. `note` is the survivor and keeps the old column
 (`@Attribute(originalName: "enrichedDescription")`) so existing rows migrate in place. It is
 written directly by the user, typed or dictated, and never processed.
- `Photo` (class): `id`, `relativePath?` (on-disk file), `assetLocalIdentifier?` (PHAsset id),
  `order`, `sfSymbol?` (deprecated seed placeholder), `visit (Visit?)`.
- `VisitTag` (class): one tagged person — `userID`, `username?`, `displayName?`, `avatarURL?`,
  `order`, `visit (Visit?)`. Mirrors `visit_tags` upstream. The name and avatar are denormalised
  on purpose: resolving ids through `SocialGraph` at render time loses the label the moment a
  friendship ends. Reach it through `Visit.taggedPeopleOrdered` — SwiftData relationships are
  unordered sets.

Enums (`PlaceCategory`, `Rating`, `LocationSource`) are stored as raw strings on the model and
exposed via computed properties.

`Rating` is two cases — `liked` and `notLiked` — presented as two cards side by side
(`Views/Shared/RatingField.swift`), and tapping the selected one clears it. It replaces the old
four-point scale *and* the separate `ReturnIntent` question. `notLiked` keeps `"no"` as its raw
value because `visits.rating_label` still carries the CHECK constraint listing the four old labels,
and `Visit.rating` reads through `Rating.from(loose:)` so a row stored as `loved` still resolves.

`VenueTag` (`Models/VenueTag.swift`) is the tag vocabulary, and it is eight cases:
amazing ambience, amazing food, amazing drinks, fast-ish food, great coffee, good healthy,
delish dessert, date night. Raw values are kebab-case and are what land in `Visit.tags` and
`visits.tags`; labels are display-only, so rewording one never orphans the entries tagged with it.
`VenueTag.label(forRawValue:)` renders anything stored under the old ~50-case vocabulary rather
than dropping it, and `TagChipRow` goes through it so no surface prints a raw value.

## Design language — Apple Liquid Glass (iOS 26)

- Build against iOS 26 SDK; system components (nav bars, sheets, tab bars) adopt Liquid Glass automatically.
- Liquid Glass is applied **only** on the functional layer: floating bottom bar, Map/List toggle, buttons.
- Content layer (map, photo carousels, long body text) stays clean — no glass, no material.
- Use `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` for buttons and `.glassEffect()` for custom glass surfaces.
- Group nearby glass elements in a `GlassEffectContainer` (required for correct rendering + morph).
- Never stack glass on glass or add `.background/.blur/.opacity/.clipShape` on a glass view.
- Respect Reduce Transparency for accessibility (SwiftUI does this by default when using system materials).
- Aesthetic: minimal, calm, generous breathing room, system fonts, subtle depth. Light haptic on confirm/save.
- **The app follows the system appearance — it is not dark-only.** Nothing sets
  `.preferredColorScheme`, and no page paints itself `Color.black` / `Color.white`. Surfaces use
  `Color(uiColor: .systemBackground)` (pages, sheet `presentationBackground`, opaque
  `toolbarBackground`), `.secondarySystemGroupedBackground` (raised cards, chat bubbles), and
  `.primary` / `.secondary` for text. A literal white or black is only correct on top of a
  saturated fill that doesn't change with the appearance — white on the accent capsule, on a
  category-tinted map pin, on the red badge, on the blue outgoing bubble. `SearchHarness.swift`
  is the one exception, and it's a dev-only snapshot harness behind the `-searchHarness` launch
  argument.
- **Photos are always a 3:4 portrait center-crop.** Every rectangular photo surface (feed card,
  write-up hero, capture preview, category tile, chat place card, share sheet, picker strips) is a
  `Color.clear.aspectRatio(3 / 4, contentMode: .fit).overlay { PhotoView(contentMode: .fill) }`
  box (or a 3:4 fixed frame) plus a clip, so landscape and portrait uploads sit at the same size.
  The only square photo surfaces are the 3-column profile/friend activity grids and small row
  thumbnails.

## Screens & flow

1. **Home — Map** (launch screen). Full-screen `Map` reading `@Query private var visits: [Visit]`
   from SwiftData with a pin per place. Tapping a pin shows a glass callout; tapping the callout
   opens the read-only Write-up. Top-floating segmented **Map | List** glass toggle.
2. **Bottom nav** (floating Liquid Glass, grouped in a `GlassEffectContainer`): Map (left), big
   prominent circular **+** (center, `.glassProminent`, raised), Profile (right).
3. **Bottom nav plus button** opens three cards:
   - **Log a visit** → opens `PhotosPicker` directly from ContentView; when photos are picked the
     capture flow starts at the Details stage (no placeholder screen in front of the picker).
     **At least one photo is required** — backing out of the picker cancels the entry, and there
     is no way to reopen the picker or drop a photo once the flow has started.
   - **Want to try** → `WantToTryView` sheet with just Name/Address/Tags. Runs the same
     `LocationResolver` to pin the map, saves a `Visit` with `kind = .wantToTry` (no photos, no
     transcript).
   - **Find a place** → `PlaceSearchView`: `MKLocalSearchCompleter` as-you-type over Apple Maps,
     resolved to a `VenueCandidate` on tap (one `MKLocalSearch` per tap, not per keystroke). The
     result card offers **Log a visit** — opens the photo picker, then the capture flow with
     `CaptureCoordinator.preselectedVenue` set, which skips venue resolution *and* the venue
     picker entirely — or **Want to try**, which saves immediately via
     `VisitRepository.insertWantToTry` and pans the map to the new pin. The preselected path
     ignores photo GPS on purpose: the user named the venue, and dinner photos are often taken
     somewhere else. A permanent "Can't find it? Drop a pin" row sits under the results.

   **Places Apple Maps doesn't have** — trucks, stalls, pop-ups — go through `DropPinView`
   (`Views/Capture/`), reachable from the venue picker and from place search. The map moves under
   a fixed centre marker rather than the pin being draggable, so the target is never under the
   user's thumb; the address field is filled by reverse geocoding until the user types in it, and
   "Move the pin to this address" geocodes the other way. The `VenueCandidate` it produces has
   `externalPOIId == nil`, which is the signal throughout the app that a place came from a person
   rather than from Apple; server-side dedupe falls back to name + geohash, so two people pinning
   the same truck still land on one `places` row.

   The three destinations share one `.sheet(item:)` slot (`ContentView.EntrySheet`) for the same
   reason `MapHome.MapSheet` exists — two `.sheet(isPresented:)` on one view is where the second
   can silently win.
4. **Capture flow** (for a real visit):
   1. **Details** screen: photo strip, tag-people row, location search, description (typed or
      dictated via hold-to-record), **tags**, **verdict**, date. Everything except the location
      is collected here — nothing about the entry is produced after submit.
   2. **Submit** → **Finding place…** overlay while `LocationResolver` runs (name-first when a
      name is given, photo-GPS-first otherwise). That is all this stage does now.
   3. If MapKit returned no confident match, a **Venue picker** sheet appears with the top 3,
      plus three escape hatches: search manually (`ManualVenueEntryView`), **drop a pin**
      (`DropPinView`), or "keep my name". Otherwise, straight to write-up.
   4. **Write-up**: image carousel → title → tag chips → description → verdict. Edit round-trips
      into `EditWriteUpView`.
   5. **Confirm** persists `Place + Visit + Photos` via `VisitRepository` and returns to the map.

5. **Tags and verdict.** `VenueTagField` and `RatingField` (both `Views/Shared/`) are the two
   sections that appear on every entry surface: the capture Details screen, `WantToTryView`, and
   both edit screens. `VenueTagField` puts all eight tags on screen at once — the vocabulary was
   shrunk precisely so a menu isn't needed. `RatingField` is absent from `WantToTryView` and from
   the edit form whenever `kind == .wantToTry`: nobody has been yet, so there is nothing to judge.

6. **Filter button** on the Home toggle strip. `EntryFilter` (an `@Observable` in
   `Stores/EntryFilter.swift`) filters both Map and List by kind (visited / want-to-try),
   category (restaurant / bar / cafe / bakery / other), and any subset of `VenueTag` tags. The
   badge next to the filter icon shows how many filters are active.

7. **Tagging people.** A visit can name the friends who were there. `TagPeopleField` +
   `TagPeoplePicker` (both in `Views/Shared/`) appear on the capture Details screen and on both
   edit screens; `TaggedPeopleRow` renders the result ("with Maya and Dev") on the feed card and
   every write-up. **Friends only, and that is a server rule** — the insert policy on `visit_tags`
   refuses a tag naming anyone the author is not accepted friends with, so a user-search picker
   would mostly 403 on save. The tagged person can untag themselves (`VisitTagService.untagSelf`,
   permitted by the delete policy); no UI hangs off that yet.

8. **Profile tabs.** `ProfileTabPicker` puts an Activity | Tagged toggle above the photo grid on
   both the signed-in profile and a friend's. Activity is that person's own entries; Tagged is
   `tagged_visits(p_user)` — entries *other people* wrote naming them, so those cells carry the
   author's avatar and open the friend write-up sheet, which has no edit or delete path.

9. **Dates.** `VisitDateField` (`Views/Shared/`) sets `Visit.visitedOn` on the capture Details
   screen and on both edit screens. It is optional in the only sense that matters: it is seeded to
   now, so logging a place the day you went needs no input, and leaving it alone means the entry
   sorts by when it was uploaded. Only the *day* is editable —
   `DatePicker(displayedComponents: .date)` preserves the bound value's time-of-day, which is what
   stops three entries backfilled to the same Saturday from colliding on midnight. Every surface
   already ordered on `visitedOn` / `visited_at`; the local `@Query` declarations now carry
   `createdAt` as a secondary descriptor so a same-instant tie still resolves to upload order.
   Future dates are rejected by the picker's range — an entry ahead of now is a want-to-try.

10. **Read-only write-up** (opened from a map pin or list row) has an `ellipsis.circle` menu with:
    Edit (opens `EditPersistedVisitView` bound directly to the SwiftData row), Move to want-to-try /
    Mark as visited, and Delete (with confirmation dialog). Delete also cleans up on-disk photo
    files.

11. **Edit modals.** Both of them — `EditWriteUpView` (the in-flight capture draft) and
    `EditPersistedVisitView` (a saved row) — are toolbars around one shared
    `VisitEditForm` (`Views/WriteUp/`), so the two screens cannot drift apart the way they had.
    They use the same flat-modal chrome as the write-up sheets they open from
    (`.flatModalBackground()` / `.flatModalToolbarBackground()` / `.flatModalContentBackground()`)
    rather than `.systemBackground`, which iOS elevates a shade lighter for modals and which read
    as gray on top of a black write-up. Cancel means Cancel in both: the persisted editor calls
    `modelContext.rollback()`, and the draft editor restores a snapshot taken on appear.

## Folder structure

```
nyc-tracker/
  Models/            Models.swift (@Model Place/Visit/Photo/VisitTag, enums), VenueTag
  Stores/            LocalStore (ModelContainer), VisitRepository, EntryFilter
  Services/
    FileStorage       Local Application Support directory for photos + audio
    LocationProvider  One-shot device location fetch (CLLocationManager)
    LocationResolver  Photo GPS clustering, geocoding, MKLocalSearch venue candidates
    Recorder          RecorderProtocol + SpeechRecorder (real) + StubRecorder (previews)
  Views/
    Home/            HomeView, MapHome (@Query), ListHome (@Query), HomeModeToggle
    Nav/             BottomNavBar
    Capture/         CaptureCoordinator, CaptureFlowView (details/processing/venuePicker/writeUp),
                     DetailsView, WantToTryView, HoldToRecordButton
    WriteUp/         WriteUpView, ReadOnlyWriteUpView, FriendVisitWriteUpView, VisitEditForm,
                     EditWriteUpView, EditPersistedVisitView, PhotoCarousel
    Profile/         ProfileView
    Shared/          Haptics, PhotoView (SF Symbol / picker item / disk / PHAsset), TagChip,
                     VenueTagField, RatingField, VisitDateField, LabeledField, FlatModalBackground
```

## What's real, what still falls back

### Real, on-device (Apple-Intelligence device, real hardware)

- **Persistence** — SwiftData `@Model` types. `LocalStore.shared` builds one disk-backed
  `ModelContainer`. No seed data — starts empty. `VisitRepository` is the seam the future
  remote-sync layer will replace, and owns delete + on-disk cleanup.
- **Photo → location resolution** — `LocationResolver` reads `PHAsset.location` from the batch,
  clusters within ~120 m, and reverse-geocodes with `CLGeocoder`. Falls back to (a) geocoding the
  Name/Address hint, then (b) `LocationProvider` (CLLocationManager). Then runs `MKLocalSearch`
  (natural-language when a Name is present, `MKLocalPointsOfInterestRequest` otherwise) and keeps
  the top 3 candidates by proximity. A fuzzy name match auto-selects a confident pick; otherwise
  the venue picker sheet is shown. The chosen `MKMapItem.Identifier` is stored as `externalPOIId`.
- **Voice recording + transcription** — `SpeechRecorder` writes an M4A into
  Application Support/Audio, transcribes it with `SpeechAnalyzer` + `SpeechTranscriber`
  (installing model assets on demand via `AssetInventory`), and drops the text straight into the
  description field. The audio file is deleted as soon as transcription finishes.
- **No AI enrichment.** `Services/Enricher.swift` (`EnricherProtocol`, `LocalEnricher`,
  `TranscriptCleaner`, and before that `FoundationModelsEnricher`) is gone. Nothing rewrites the
  user's words, picks tags for them, or suggests a rating — dictation is transcription and nothing
  more. If a write-up assistant ever comes back it needs its own field, not a second copy of
  `note`: the last one cost three columns and two screens' worth of UI to unwind.

### Graceful fallbacks

- **Photos without GPS** (screenshots, downloads): fall through to Name/Address geocode → device
  location → manual coordinate.
- **No nearby venue found**: user's typed Name stays as the title, no `externalPOIId`.
- **SpeechAnalyzer unavailable** (simulator / older device / no models yet): `SpeechRecorder`
  falls back to `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`; if that's also
  unavailable, the description is left empty and the flow continues — it is an ordinary text
  field, so the user can just type.
- **Photo library denied**: `LocationResolver.coordinatesFromAssets` returns nil, and the flow
  continues with the next fallback. `PhotoView` still displays picker-item and file-URL sources.
- **Mic / speech denied**: the recording call fails silently and the flow continues with an empty
  description.

## Stubs / TODOs left for the next prompt (remote sync)

- **No networking, no Supabase, no auth.** Everything is on-device.
- `Stores/LocalStore.swift` — `VisitRepository` is the seam. To add Supabase later, wrap this
  repository (or add a second implementation) that mirrors inserts/updates to Supabase Postgres,
  uploads photos + audio to Supabase Storage, and drives the `published` flag.
- `Views/Profile/ProfileView.swift` — still a placeholder with a disabled "Sign in" button. Wire
  Supabase Auth here.
- `visits.transcript`, `visits.top_quote` and `visits.return_intent` are dead columns upstream.
  The app no longer reads them, and `VisitUpsert` writes explicit NULLs so a re-upload clears
  whatever an older build left there. Dropping the columns is a migration nobody needs yet.
- `visit_tags` has no notification: being tagged is only discoverable by opening your own profile.
  A push or an inbox row is the obvious next step and needs no schema change.
- Nothing lets a tagged person remove their own tag from the UI. `VisitTagService.untagSelf` and
  the delete policy that permits it both exist; only the button is missing.
- `Services/LocationResolver.swift` — uses `CLGeocoder` (deprecated in iOS 26 in favor of
  `MKGeocodingRequest`/`MKReverseGeocodingRequest`). Warnings only; still works. Modernize when
  convenient.

## Acceptance (current build)

- Builds and runs in the iOS 26 simulator (falls back to `StubEnricher` + `SFSpeechRecognizer`).
- On a real Apple-Intelligence device: pick photos → app resolves a venue → hold-to-record produces
  a real transcript → the on-device model produces title + description + tags + top quote → Confirm
  persists a real Place/Visit/Photos to SwiftData and drops a pin that survives relaunch.
- Seeded 5 sample entries appear on first launch only. Deleting them and relaunching does not bring
  them back (guarded by `nyc-tracker.hasSeededSampleData.v1`).
- Liquid Glass still appears on the bottom bar, toggle, and buttons — not on the map or body text.

## Info.plist / build settings (action required in Xcode)

**All permissions are requested at the right moments, but the usage strings need real copy.**
Currently the four keys exist in the pbxproj as empty strings; add the following via
**Target → Info → Custom iOS Target Properties** (or edit `INFOPLIST_KEY_*` in Build Settings):

- `NSPhotoLibraryUsageDescription` — "NYC Log reads photos you choose to attach them and to resolve where you were."
- `NSMicrophoneUsageDescription` — "NYC Log records short voice notes about places you visit."
- `NSSpeechRecognitionUsageDescription` — "NYC Log transcribes your voice notes on device."
- `NSLocationWhenInUseUsageDescription` — **needs to be added** (not currently in the pbxproj). Suggested copy: "NYC Log uses your location to center the map on where you are and to resolve venues from live photos."

Empty strings work in development but Apple rejects submissions without real copy — set them
before shipping. **Do not edit `project.pbxproj` directly (it can crash a running Xcode).**

## Gotchas

- The project has `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`, which blocks transitive
  imports. When touching a file, explicitly import every framework whose types it names directly
  (e.g. `import Combine` alongside `import SwiftUI` if you use `@Published`).
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` applies main-actor isolation project-wide. Don't
  double up with `@MainActor` on `ObservableObject`-style classes.
- Editing `nyc-tracker.xcodeproj/project.pbxproj` while Xcode is open risks crashing Xcode. Ask the
  user to make project-file changes in Xcode's UI instead.
- The project uses a `PBXFileSystemSynchronizedRootGroup` for `nyc-tracker/`, so any new file
  inside that folder is auto-added to the target. No pbxproj edit needed to register sources.
- `PhotosPickerItem.itemIdentifier` is only non-nil when the picker is initialized with a
  `photoLibrary:` (we use `.shared()`).
- `SpeechTranscriber.supportedLocale(equivalentTo:)` is `async` in iOS 26 — call it with `await`.
- `SpeechAnalyzer.cancelAndFinishNow()` is actor-isolated and not `throws`; call with `await` and
  no `try`.

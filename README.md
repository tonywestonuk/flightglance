# FlightGlance

A native iPhone app (SwiftUI) that shows your progress during a flight — including in
Airplane Mode — using the iPhone's GPS and a world atlas bundled inside the app.

- **Before flight:** choose departure and arrival airports from an offline list of ~4,000
  airports (search by code, city or name). Grant location access, then start tracking.
- **In flight:** a shaded 3D globe (or flat map) centred on you, with the great-circle reference
  route, your recorded GPS track, airport markers, and readings: GPS ground speed, GPS altitude,
  GPS course, distance flown, distance to go, and an estimated time of arrival. A status pill
  shows GPS quality, signal loss, permission problems, or simulated data.
- **Bigger map:** hide the readings panel (⌄ or swipe down) for a full-screen map with a
  compact, semi-transparent table along the bottom (3×2 in portrait, 6×1 in landscape).
- **Lock Screen:** a Live Activity shows the country or ocean you're over, the nearest town
  ("25 nm E of Sitapur"), distance to go and an arrival countdown, in the Lock Screen and the
  Dynamic Island. While locked the app runs in a low-power mode: the GPS takes a fix every
  5 minutes, and in between the position is estimated from the last fix's speed and course and
  the Lock Screen is updated every 30 seconds.
- **Edit or end:** tap the route chip (or **••• → Edit Flight**) to correct the airports while
  GPS keeps recording; **End Flight** clears the track.

Nothing in flight uses the network. The map is drawn locally from Natural Earth vectors; no map
tiles and no MapKit map display are used.

## Requirements

- Xcode 26 (built and tested with Xcode 26.6 / iOS 26.5 SDK). Deployment target iOS 17.0, iPhone.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`); the `.xcodeproj` is
  generated from `project.yml`.

## Build and run

```sh
xcodegen generate
open FlightGlance.xcodeproj           # pick your team under Signing & Capabilities, then Run
```

From the command line:

```sh
# Simulator
xcodebuild -project FlightGlance.xcodeproj -scheme FlightGlance \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Unit tests (Swift Testing, 71 tests)
xcodebuild -project FlightGlance.xcodeproj -scheme FlightGlance \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# A connected iPhone (replace the team ID and device name)
xcodebuild -project FlightGlance.xcodeproj -scheme FlightGlance \
  -destination 'platform=iOS,name=Your iPhone' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=YOURTEAMID build
xcrun devicectl device install app --device <device-id> \
  <DerivedData>/Build/Products/Debug-iphoneos/FlightGlance.app
```

### Trying it without flying (Debug builds only)

- Turn on **Developer → Simulate GPS along route** before starting. Simulated readings are
  labelled "Simulated" throughout and are never mixed with real GPS.
- Launch arguments (Xcode scheme or `simctl launch`) with sample routes `DEMO1`…`DEMO6`
  (LHR–JFK, SFO–NRT, SYD–LAX, DXB–LAX, SIN–LHR, JFK–SFO): `-FGDemo DEMO2` starts a simulated flight;
  add `-FGLive YES` to use real Core Location instead (e.g. with `xcrun simctl location … start`);
  `-FGDraft DEMO5` only pre-fills setup; `-FGLandscape YES` rotates; `-FGEdit YES` opens the edit
  screen; `-FGResetState` clears a saved flight.

Release builds contain no sample data and no simulator UI.

## How it works

```
FlightGlance/
  App/         FlightGlanceApp (root view switching), AppModel (resources, GPS, active flight)
  Geo/         GeoMath (great circles), MillerProjection + MapCamera (flat map),
               GlobeProjection + GeoCamera (3D globe and the camera shared by both styles)
  Atlas/       WorldAtlas (binary loader, cached paths), GlobeRenderer, AtlasRenderer (flat),
               MapAnnotations (markers, aircraft, decluttered city labels)
  Tracking/    TrackRecorder (breadcrumb filtering), ETAEstimator, GPSSignalState, FlightSession
  Services/    LocationService (duty-cycled Core Location, low-power background mode),
               AirportDatabase, PlaceFinder (offline "over France, 35 km SW of Lyon"),
               LiveActivityController, FlightStore (resume after relaunch), FlightSimulation
Shared/        FlightActivityAttributes (Live Activity data, used by app and extension)
FlightGlanceWidgets/  Lock Screen / Dynamic Island Live Activity views
  Views/       Setup, Dashboard, Map, Info, shared Theme
  Resources/   Data/WorldAtlas.bin, Cities.json, Airports.json; assets; privacy manifest
Tools/         build_atlas_data.py (regenerates the bundled data), make_app_icon.swift
```

**Offline map data.** `Tools/build_atlas_data.py` converts Natural Earth 1:110m and 1:50m land,
lakes and country borders into a compact binary (coordinates quantised to 16-bit, ~300 m), plus
~1,200 cities, 242 country label points, island/sea/ocean labels, simplified country and ocean
outlines plus ~7,300 towns for the Lock Screen's "where am I", and the airport list. Bundled
data totals about 1.1 MB.

**Labels.** Which country and city names appear depends only on the zoom level (in half-step
increments), never on where the map is pointing, so nothing flickers while panning.
`MapLabelPlanner` ranks places by Natural Earth's label zoom and keeps a name only if it
doesn't overlap a more important one, measuring separation on the ground at true scale, and
caches the result per zoom step. On the globe, names fade out towards the rim, where a name
that the sphere squashes into a more important one is skipped. The coarse layer is used
when zoomed out and the detailed layer when zoomed in.

**Globe.** An orthographic projection: each vertex is stored as a unit vector and projected with
two dot products against the camera's east/north axes. Geometry is grouped into buckets with
bounding spherical caps so anything behind the globe or off screen is skipped. Lines are cut
exactly at the horizon. Filled shapes that wrap over the horizon are closed along the rim, and
the rare shape that contains the point directly behind the globe is drawn with an even-odd
correction (see the comment at the top of `GlobeRenderer.swift`).

**Flat map.** Miller cylindrical projection (finite at the poles, so polar routes work). Paths are
projected once and drawn through an affine transform; the world repeats horizontally so date-line
crossings are seamless.

**Routes.** The dashed line is the great circle from the latest GPS position (the origin before the
first fix) to the destination, a reference only and not the airline's filed route. Progress is still
measured along the great circle from the origin. The solid line is the GPS track. Dotted stretches mark signal gaps.

**GPS.** This isn't a satnav, so the GPS is duty-cycled: every 15, 30 (default) or 60 seconds
it is switched on until it gets one fix within 100 m (or the best fix within 45 s), then switched
off. When the phone locks:
- with **Show on Lock Screen** on (default), the app enters a low-power background mode: one
  looser (~100 m) fix every 5 minutes, giving up after 30 s, and a Live Activity update. iOS
  suspends apps that stop location updates, so between fixes a coarse 3 km request keeps the
  session alive without needing the GPS receiver. No map is drawn; every 30 s the last fix is
  carried forward along its course at its ground speed (dead reckoning, at most 10 minutes,
  not below ~50 kt) and the Live Activity is updated with the estimated position, marked
  "Estimated from GPS hh:mm".
  iOS shows a location indicator. Live Activities last up to 8 hours; opening the app starts
  a fresh one.
- with it off, the GPS stops and iOS suspends the app; the unobserved stretch shows as a dotted
  line. Invalid values (Core Location's negative sentinels) become `nil` and show as "—" with a
reason. The status says signal lost only after a whole sampling cycle passes without a fix.
The breadcrumb filter rejects inaccurate fixes, jitter, and physically impossible jumps.

**Arrival estimate.** Remaining great-circle distance from the latest fix to the destination,
divided by the mean GPS ground speed over the last 5 minutes (falling back to speed along the
recorded track). It is anchored to the fix time, withdrawn after 15 minutes without a fix, and
not shown below about 50 knots or when the result isn't credible (over 24 h).

**Energy.** The map is two stacked layers. The expensive base layer (land, coasts, shading,
labels) is `Equatable` and only redraws when the camera moves; the light flight layer (route,
track, aircraft) redraws once per GPS fix. Follow mode moves the camera without animation, and
only once the aircraft has drifted ~2 pt from centre (every few seconds zoomed in, every few
minutes on the whole globe). In a 25 s simulator run with 1 Hz fixes the base layer redrew twice and the
flight layer 25 times. An earlier animated follow kept the globe rendering at full frame rate
(~30% CPU vs ~1.5% now).

## Accessibility and layout

Layouts adapt to the available size: map above readings in portrait (the panel scrolls if it
would exceed half the height), and a sidebar in landscape. They respect safe areas, scale with
Dynamic Type (tiles stack to one column at accessibility sizes), give VoiceOver labels and values
for every reading and the map, and never rely on colour alone for status.

## Data credits

- Natural Earth — public domain. "Made with Natural Earth."
- OurAirports — public domain.
- mwgg/Airports (airport time zones) — MIT License; full text in `ACKNOWLEDGEMENTS.md` and in
  the app's About screen.

## Known limitations

- GPS altitude is geometric height above sea level, not the pressure altitude pilots use, and
  phones often get a weaker GPS signal away from a window.
- The ETA ignores routing, holding, approach and wind changes, so it tends to be early.
- No flight-number lookup: you choose the airports yourself.
- iOS ends a Live Activity after 8 hours; on longer flights open the app to start a new one.
- Country / ocean lookup uses coarse 1:110m outlines, so within a few km of a coast it may name
  the sea rather than the country.
- Airports without scheduled service in OurAirports aren't in the list, and there's no way to
  enter raw coordinates.
- The globe uses a spherical earth model (≈0.5% distance error), which is fine at these scales.
- Map labels are English names from Natural Earth.

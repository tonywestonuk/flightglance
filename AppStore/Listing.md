# App Store Connect: FlightGlance 1.0

Everything to paste into App Store Connect, field by field. Limits are Apple's.

## App information

| Field | Value |
|---|---|
| Name (30) | FlightGlance |
| Subtitle (30) | Offline flight progress & map |
| Bundle ID | app.flightglance.FlightGlance |
| SKU | flightglance-ios |
| Primary language | English (U.K.) |
| Primary category | Travel |
| Secondary category | Navigation |
| Content rights | Yes, it contains third-party content, and I have the rights to use it (Natural Earth and OurAirports are public domain; mwgg/Airports is MIT, credited in the app) |
| Privacy Policy URL | https://github.com/tonywestonuk/flightglance/blob/main/PRIVACY.md |
| Support URL | https://github.com/tonywestonuk/flightglance/blob/main/SUPPORT.md |
| Marketing URL (optional) | https://github.com/tonywestonuk/flightglance |
| Copyright | 2026 Tony Weston |

## Promotional text (170)

See where you are on your flight, even in Airplane Mode. FlightGlance uses your iPhone's GPS and a built-in world map: no Wi-Fi, no data, no account.

## Keywords (100)

```
airplane mode,plane,gps,inflight,tracker,globe,arrival,eta,altitude,speed,travel,trip,window seat
```

(Words in the name and subtitle are already indexed, so they aren't repeated here.)

## Description (4000)

```
FlightGlance shows where you are on your flight, even in Airplane Mode.

Your iPhone's GPS keeps working without a signal, and FlightGlance carries its own world map, so there's nothing to download in the air. Choose your departure and arrival airports before you board, start tracking, and glance at your progress any time.

IN FLIGHT
• A 3D globe or flat map centred on you, with your GPS track and the shortest path to your destination
• Ground speed, GPS altitude and course
• Distance flown and distance to go
• An estimated arrival time, shown in your destination's local time
• The country or ocean you're over, and the nearest town

ON YOUR LOCK SCREEN
A Live Activity shows your progress along the route, where you are and how long until you land, on the Lock Screen and in the Dynamic Island, without unlocking your phone.

EASY ON YOUR BATTERY
The GPS switches on briefly for each position and off again in between. While your iPhone is locked it takes a reading every 5 minutes and estimates your position in between.

PRIVATE BY DESIGN
No account, no ads, no tracking. Your location and flight track never leave your iPhone, and they're deleted when you end the flight.

WORKS WORLDWIDE
Around 4,000 airports, searchable by code, city or name. Choose aviation (knots, feet, nautical miles), metric or imperial units.

GOOD TO KNOW
• FlightGlance uses your phone's GPS, not the aircraft's instruments. A window seat gives the best signal.
• GPS altitude can differ from the altitude the crew announces, and the arrival time is an estimate.
• iOS ends Lock Screen Live Activities after 8 hours; on longer flights, open the app to start a new one.
```

## What's New

Not needed for the first version.

## App Privacy

- Do you or your third-party partners collect data from this app? **No, we do not collect data from this app.**
  (Apple counts data as "collected" only when it leaves the device. FlightGlance never transmits anything.)
- Result shown on the App Store: **Data Not Collected**.

## Age rating

Answer **None / No** to every question. Result: **4+**.

## Pricing and availability

Your choice. Free, or a one-off price; all territories.

## Encryption (export compliance)

Already answered in the app (`ITSAppUsesNonExemptEncryption = NO`), so App Store Connect won't ask.

## Screenshots

Required: **6.9-inch iPhone** (1320 × 2868 portrait, iPhone 17 Pro Max simulator). Up to 10.
Suggested set:
1. Globe mid-Atlantic with readings ("Know where you are, even in Airplane Mode")
2. Full-screen map with the compact readings bar
3. Lock Screen Live Activity ("Your flight on the Lock Screen")
4. Flat map, landscape, polar or Pacific route
5. Airport search on the setup screen

## App Review information

- Sign-in required: **No**
- Contact: your name, phone and email (only Apple sees these)
- Notes:

```
FlightGlance shows a passenger's progress during a flight using only the iPhone's GPS and map data bundled in the app. It makes no network requests.

How to test on the ground:
1. Choose any two airports (for example LHR and JFK) and tap Start Tracking.
2. Allow location access ("While Using the App").
3. The map centres on your position and shows the route to the destination, with GPS speed, altitude and distance to go. The arrival estimate needs flight speeds (over about 50 knots), so on the ground it shows "—" with "Not moving fast enough to estimate", and course needs steady movement. That is expected.

Background location: the app declares the "location" background mode only for its Lock Screen Live Activity. When the user starts a flight and leaves "Show on Lock Screen" on (the default; it can be switched off on the setup screen), the app keeps location updates running while the phone is locked: it takes a GPS reading every 5 minutes and keeps the Live Activity (country/ocean, nearest town, progress, arrival time) up to date. iOS shows the location indicator throughout. When the user ends the flight, or switches the option off, background location stops. Permission requested is "When In Use" only.

No data leaves the device. Location and the recorded track are stored locally and deleted when the flight ends.
```

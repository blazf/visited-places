# Visited Places

A native macOS app (SwiftUI + MapKit) that shows the cities and countries you've been to on a world map. It finds them in flight, hotel and train booking emails in your Fastmail mailbox.

## Build & run

```sh
./scripts/build-app.sh          # → build/VisitedPlaces.app
open build/VisitedPlaces.app
swift test                      # extractor tests
```

Requires Xcode / Swift 6 and macOS 15+.

## Connect Fastmail

1. Go to Fastmail → Settings → Privacy & Security → API tokens and create a token with **Email** access set to **read-only**.
2. In the app, open Settings (⌘,), paste the token, then click Save and Test Connection. The token is stored in the macOS Keychain.
3. Click **Sync Mail** (⌘R).

## How it works

- **Sync** (`JMAPClient.swift`): uses Fastmail's JMAP API to search for emails whose subject or sender looks travel-related (booking, reservation, itinerary, airlines, Booking.com, Airbnb, …) and caches them as JSON in `~/Library/Application Support/VisitedPlaces/mail/`. Later syncs only download new emails.
- **Extraction** (`Extractor.swift`):
  1. schema.org JSON-LD markup (`FlightReservation`, `LodgingReservation`, `TrainReservation`, `BusReservation`) that most airlines and booking sites embed. Gives exact airports, addresses and dates.
  2. Otherwise, text rules: airport codes in routes like `(LJU)` or `LJU → FRA`, hotel addresses (via `NSDataDetector`), and the dates after "check-in" / "check-out". Promotional and cancellation emails are skipped.
- **Places**: airport codes resolve offline from `Resources/airports.tsv` (OurAirports, public domain; refresh with `scripts/fetch-airports.sh`). Addresses go through Apple's geocoder and the results are cached in `geocache.json`.
- **Editing**: select a pin to edit dates or type, read the source email, or delete a visit. Deleted visits are remembered and won't come back on rescan. Right-click a city in the sidebar to rename it or merge it into another city, e.g. an airport town like "Zgornji Brnik" into "Ljubljana". Use **+** to add places by hand.

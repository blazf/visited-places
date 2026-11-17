import XCTest
import PDFKit
import AppKit
@testable import VisitedPlaces

final class ExtractorTests: XCTestCase {
    let received = ISO8601DateFormatter().date(from: "2025-03-01T10:00:00Z")!

    func email(_ subject: String, text: String = "", html: String = "") -> CachedEmail {
        CachedEmail(id: "x", subject: subject, from: "a@b.c", receivedAt: received, textBody: text, htmlBody: html)
    }

    func testAirportsLoaded() {
        XCTAssertEqual(Airports.lookup("FRA")?.countryCode, "DE")
    }

    func testJSONLDFlight() {
        let html = """
        <html><head><script type="application/ld+json">
        {"@context":"http://schema.org","@type":"FlightReservation","reservationNumber":"ABC123",
         "reservationFor":{"@type":"Flight","flightNumber":"1453","airline":{"@type":"Airline","iataCode":"LH"},
          "departureAirport":{"@type":"Airport","iataCode":"LJU"},"departureTime":"2025-04-10T06:05:00+02:00",
          "arrivalAirport":{"@type":"Airport","iataCode":"FRA"},"arrivalTime":"2025-04-10T07:20:00+02:00"}}
        </script></head><body>Hi</body></html>
        """
        let c = Extractor.extract(from: email("Your booking", html: html))
        XCTAssertEqual(c.map(\.location), [.airport("LJU"), .airport("FRA")])
        XCTAssertEqual(c[1].detail, "LH1453 · LJU → FRA")
        XCTAssertNotNil(c[1].start)
    }

    func testJSONLDHotel() {
        let html = """
        <script type="application/ld+json">[{"@context":"https://schema.org","@type":"LodgingReservation",
        "checkinDate":"2025-05-02","checkoutDate":"2025-05-05",
        "reservationFor":{"@type":"LodgingBusiness","name":"Hotel Central",
        "address":{"@type":"PostalAddress","streetAddress":"Ilica 1","addressLocality":"Zagreb","addressCountry":"HR"}}}]</script>
        """
        let c = Extractor.extract(from: email("Booking confirmed", html: html))
        XCTAssertEqual(c.first?.location, .address("Ilica 1, Zagreb, HR"))
        XCTAssertEqual(c.first?.source, .hotel)
        XCTAssertNotNil(c.first?.end)
    }

    func testTextFlight() {
        let text = """
        Your e-ticket receipt. Booking reference: XY12ZQ
        Flight OS 712  Ljubljana (LJU) → Vienna (VIE)
        Departure: 14 April 2025 10:15   Terminal 1
        Flight OS 87  VIE - JFK  14 April 2025
        Total: 450 EUR incl. VAT
        """
        let c = Extractor.extract(from: email("Your flight itinerary", text: text))
        XCTAssertEqual(c.map(\.location), [.airport("LJU"), .airport("VIE"), .airport("JFK")])
        XCTAssertNotNil(c.first?.start)
    }

    func testTextHotel() {
        let text = """
        Thanks! Your booking is confirmed. Confirmation number: 4455.66.
        Apartment Sunny
        Via Roma 12, 00184 Rome, Italy
        Check-in: Friday, 16 May 2025 (from 14:00)
        Check-out: Monday, 19 May 2025 (until 11:00)
        """
        let c = Extractor.extract(from: email("Your booking at Apartment Sunny is confirmed", text: text))
        guard case .address(let a)? = c.first?.location else { return XCTFail("no address: \(c)") }
        XCTAssertTrue(a.contains("Rome"), a)
        let cal = Calendar(identifier: .gregorian)
        XCTAssertEqual(c.first?.start.map { cal.component(.day, from: $0) }, 16)
        XCTAssertEqual(c.first?.end.map { cal.component(.day, from: $0) }, 19)
    }

    func testPromoAndCancellationIgnored() {
        XCTAssertTrue(Extractor.extract(from: email("Flight deal: LJU → JFK from 299 EUR", text: "Book now LJU - JFK, booking reference later")).isEmpty)
        XCTAssertTrue(Extractor.extract(from: email("Booking cancelled", text: "Booking reference AB. Flight LJU - FRA")).isEmpty)
    }

    func testHTMLToText() {
        let t = Extractor.htmlToText("<p>A&amp;B</p><style>x{}</style><td>C</td>&#x2192;")
        let words = t.split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertEqual(words, ["A&B", "C", "→"])
    }
}

final class FalsePositiveTests: XCTestCase {
    func codes(_ t: String) -> [String] { Extractor.routeCodes(in: t) }

    func testAbbreviationsInBracketsIgnored() {
        XCTAssertEqual(codes("Please provide Advance Passenger Information (API) before departure."), [])
        XCTAssertEqual(codes("Fly more sustainably by using Sustainable Aviation Fuel (SAF) today"), [])
        XCTAssertEqual(codes("without completion of the Property Irregularity Report (PIR) is considered"), [])
        XCTAssertEqual(codes("You will pay the hotel in the hotel’s local currency (HUF) at the exchange rate"), [])
        XCTAssertEqual(codes("Collision Damage Waiver (CDW) is not insurance."), [])
        XCTAssertEqual(codes("customer_placement=BEX-EML-FLIGHT-expedia.purchase"), [])
        XCTAssertEqual(codes("ITR-EMD"), [])
    }

    func testVerticalAirportListIgnored() {
        let t = """
        Free online check in!
        Online check in is available if your journey starts from one of the following airports:
          Amsterdam  (AMS)
          Athens  (ATH)
          Banja Luka  (BNX)

          Belgrade  (BEG)
          Dusseldorf  (DUS)*
        Your flight: 10:30 Belgrade (BEG) - Tirana (TIA) 11:45
        """
        XCTAssertEqual(codes(t), ["BEG", "TIA"])
    }

    func testRelativeDateWordsIgnored() {
        let received = Date(timeIntervalSince1970: 1_600_000_000)
        let dates = Extractor.detectDates(in: "Check in now! Your flight leaves tomorrow, 15 September 2020.", around: received)
        XCTAssertEqual(dates.count, 1)
    }

    func testDestinationListIgnored() {
        XCTAssertEqual(codes("Las Vegas, Los Angeles, Miami, New York (LGA), Newark, Orange County (SNA), Orlando, Phoenix"), [])
    }

    func testRealFlightsKept() {
        XCTAssertEqual(codes("03:52 PM --> 05:28 PM Chicago, IL, US (ORD) Omaha, NE, US (OMA) Flight 2 of 2 UA549"), ["ORD", "OMA"])
        XCTAssertEqual(codes("*10:25 h* Billund Billund Airport (BLL)\n*11:50 h* Frankfurt Frankfurt (FRA) Terminal 1"), ["BLL", "FRA"])
        XCTAssertEqual(codes("Seats: ORD to OMA: 34F"), ["ORD", "OMA"])
        XCTAssertEqual(codes("München (MUC) 07:15"), ["MUC"])
        XCTAssertEqual(codes("Your flight LJU-FRA"), ["LJU", "FRA"])
    }

    func testForwardHeadersStripped() {
        let t = "> From: SWISS <noreply@swiss.com>\n> Subject: Your SWISS flight LJU-BLL on 25/06/2021\n> Date: 3 May 2021 at 22:10\n> Flight LX 1234"
        let out = Extractor.stripForwardHeaders(t)
        XCTAssertFalse(out.contains("Date:"))
        XCTAssertFalse(out.contains("Subject:"))
        XCTAssertTrue(out.contains("Flight LX 1234"))
    }

    func testAirportServedCity() {
        XCTAssertEqual(Airports.lookup("LJU")?.city, "Ljubljana")
        XCTAssertEqual(Airports.lookup("ZAG")?.city, "Zagreb")
    }

    func testSubjectNormalization() {
        XCTAssertEqual(AppModel.normalizedSubject("Re: Fwd: Booking details"), "booking details")
    }
}

/// Runs the extractor over the real local mail cache and prints what it finds.
/// Run with: VP_SCAN_CACHE=1 swift test --filter CacheReport
final class CacheReport: XCTestCase {
    func testReport() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VP_SCAN_CACHE"] == "1")
        var counts: [String: Int] = [:]
        var hotels = 0, emails = 0
        for id in Storage.cachedMailIds() {
            guard let e = Storage.loadEmail(id: id) else { continue }
            let found = Extractor.extract(from: e)
            if !found.isEmpty { emails += 1 }
            for c in found {
                switch c.location {
                case .airport(let code):
                    let a = Airports.lookup(code)
                    counts["\(code) \(a?.city ?? "?") \(a?.countryCode ?? "")", default: 0] += 1
                case .address(let a): hotels += 1; counts["ADDR \(a)  [hint: \(c.cityHint ?? "-")]", default: 0] += 1
                case .city(let a, let country): counts["CITY \(a), \(country)", default: 0] += 1
                }
            }
        }
        print("REPORT emails with bookings: \(emails), hotel addresses: \(hotels)")
        for (k, n) in counts.sorted(by: { $0.value > $1.value }) { print("REPORT \(n)\t\(k)") }
    }
}

final class ForwardedSwissEmailTest: XCTestCase {
    func testSwissTripInfo() {
        let text = """
        Sent from my iPhone

        Begin forwarded message:

        > From: "Swiss International Air Lines" <noreply@notifications.swiss.com>
        > Date: September 12, 2017 at 9:08:08 PM PDT
        > Subject: All the information on your trip on Wed. 20.09.2017
        > Booking reference: AB12CD
        > Flight information
        > Outbound flight
        > San Francisco (SFO) - Ljubljana (LJU), Wed. 20.09.2017
        > \tLX 39
        > 20:10 SFO\t
        > Terminal I, Latest check-in:
        > 18:55
        > 16:00 ZRH
        > \tJP 307
        > 20:20 ZRH\t
        > 21:20 LJU
        > Important Information / Immigration Formalities
        > \tAdvance Passenger Information (API)
        > Airlines are obliged to pass additional passenger information on to the immigration authorities
        > Enter API data\t
        > Hotel Deals
        > Book the hotel for your trip with SWISS.
        """
        let received = ISO8601DateFormatter().date(from: "2017-09-13T04:08:08Z")!
        let email = CachedEmail(id: "s", subject: "Fwd: All the information on your trip on Wed. 20.09.2017",
                                from: "me", receivedAt: received, textBody: text, htmlBody: "")
        let found = Extractor.extract(from: email)
        XCTAssertEqual(found.map(\.location), [.airport("SFO"), .airport("LJU")])
        XCTAssertFalse(found.contains { $0.location == .airport("API") })
        let day = found.first?.start.map { Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: $0).day }
        XCTAssertEqual(day, 20)
    }
}

final class DestinationHintTests: XCTestCase {
    func testHints() {
        XCTAssertEqual(Extractor.destinationHint(subject: "Your booking in New York City is coming up!", body: ""), "New York City")
        XCTAssertEqual(Extractor.destinationHint(subject: "Your booking in New York is coming up!", body: ""), "New York")
        XCTAssertEqual(Extractor.destinationHint(subject: "Booking confirmation", body: "Hello! Your trip to Lisbon is less than a week away"), "Lisbon")
        XCTAssertEqual(Extractor.destinationHint(subject: "Get ready for your Barcelona trip", body: ""), "Barcelona")
        XCTAssertEqual(Extractor.destinationHint(subject: "Ihre Reise nach Wien", body: ""), "Wien")
        XCTAssertNil(Extractor.destinationHint(subject: "Your booking is confirmed", body: "Thanks for booking with us."))
    }

    func testBookingComNewYorkEmail() {
        let email = CachedEmail(id: "ny", subject: "Your booking in New York is coming up!", from: "Booking.com <noreply@booking.com>",
                                receivedAt: ISO8601DateFormatter().date(from: "2017-06-20T10:00:00Z")!,
                                textBody: """
                                Confirmation number: 1234567890
                                Hello Alex! Your trip to New York is less than a week away
                                Your booking information
                                Fifty NYC-an Affinia hotel
                                155 E. 50th Street, Midtown East
                                +18662334642
                                Check-in Sunday 25 June 2017
                                Check-out Saturday 1 July 2017
                                """, htmlBody: "")
        let c = Extractor.extract(from: email)
        XCTAssertEqual(c.first?.cityHint, "New York", "\(c)")
    }
}


final class LabelledCityTests: XCTestCase {
    func testFormStyleHotelEmail() {
        let body = """
        Zivjo Alex,
        Tukaj je rezervacija za Madrid.
        ---------- Forwarded message ----------
        Subject: FW: Residential hotel Liabeny - Reservation Confirmation.
        Dear Mr/Ms Alex Example,
        Your reservation has been confirmed.
        Reservation code: 000000-12345
        HOTEL INFORMATION
        Street address: Calle Salud, 3
        City:           (Centro) MADRID
        Telephone :     +34 915 31 90 00
        DATES
        Check-in:  Apr 19, 2009
        Check-out: Apr 25, 2009
        """
        XCTAssertEqual(Extractor.labelledCity(in: body), "Madrid")
        let email = CachedEmail(id: "m", subject: "Fwd: FW: Residential hotel Liabeny - Reservation Confirmation.",
                                from: "b", receivedAt: ISO8601DateFormatter().date(from: "2009-03-30T12:00:00Z")!,
                                textBody: body, htmlBody: "")
        let c = Extractor.extract(from: email)
        XCTAssertEqual(c.first?.cityHint, "Madrid", "\(c)")
        if case .address(let a)? = c.first?.location { XCTAssertFalse(a.lowercased().hasSuffix(", city"), a) }
        XCTAssertEqual(Extractor.destinationHint(subject: "x", body: "Tukaj je rezervacija za Madrid."), "Madrid")
    }
}

/// VP_FIND="Newcastle,Cambridge" swift test --filter PlaceFinder — which cached emails mention
/// a place, and what the extractor makes of them.
final class PlaceFinder: XCTestCase {
    func testFind() throws {
        guard let names = ProcessInfo.processInfo.environment["VP_FIND"] else { throw XCTSkip("set VP_FIND") }
        let wanted = names.split(separator: ",").map { String($0) }
        var rows: [(Date, String)] = []
        for id in Storage.cachedMailIds() {
            guard let e = Storage.loadEmail(id: id) else { continue }
            let all = e.subject + " " + e.textBody + " " + e.htmlBody
            for w in wanted where all.range(of: "\\b\(w)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                let found = Extractor.extract(from: e).map { c -> String in
                    switch c.location { case .airport(let a): return a; case .address(let a): return "[\(a)]"; case .city(let a, _): return "{\(a)}" }
                }
                rows.append((e.receivedAt, "FIND \(w) | \(e.receivedAt.formatted(date: .numeric, time: .omitted)) | \(id) | \(e.subject.prefix(70)) | \(e.from.prefix(30)) | → \(found.joined(separator: ","))"))
            }
        }
        for r in rows.sorted(by: { $0.0 < $1.0 }) { print(r.1) }
    }
}

/// VP_AI="Sydney,Cambridge" swift test --filter AIFinder — runs the on-device model on cached
/// emails that mention those places and the extractor would send to it.
final class AIFinder: XCTestCase {
    func testAI() async throws {
        guard let names = ProcessInfo.processInfo.environment["VP_AI"] else { throw XCTSkip("set VP_AI") }
        let wanted = names.split(separator: ",").map(String.init)
        for id in Storage.cachedMailIds().sorted() {
            guard let e = Storage.loadEmail(id: id), AIExtractor.shouldAsk(e) else { continue }
            let all = e.subject + " " + e.textBody + " " + e.htmlBody
            guard let w = wanted.first(where: { all.range(of: "\\b\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil }) else { continue }
            guard let r = await AIExtractor.read(e) else { continue }
            let found = AIExtractor.candidates(from: r, email: e).map { c -> String in
                let d = c.start.map { $0.formatted(.iso8601.year().month().day()) } ?? "-"
                switch c.location {
                case .airport(let a): return "\(a)@\(d)"
                case .address(let a): return "[\(a)]@\(d)"
                case .city(let a, let k): return "\(a)/\(k)@\(d)"
                }
            }
            print("AI \(w) | \(e.receivedAt.formatted(date: .numeric, time: .omitted)) | \(e.subject.prefix(60)) | booking=\(r.isBooking) → \(found.joined(separator: ", "))")
        }
    }
}

final class PDFAttachmentTests: XCTestCase {
    /// A short email whose details are only in the attached ticket PDF.
    func testTicketInPDF() throws {
        let ticket = """
        E-TICKET RECEIPT  Booking reference: XY12ZQ
        Flight OS 712  Ljubljana (LJU) → Vienna (VIE)
        Departure: 14 April 2025 10:15
        """
        // Make a real PDF and read it back the way the app does.
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: ticket, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr), CFRange(),
                                             CGPath(rect: box.insetBy(dx: 40, dy: 40), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        let text = try XCTUnwrap(PDFDocument(data: data as Data)?.string)
        XCTAssertTrue(text.contains("LJU"))

        let received = ISO8601DateFormatter().date(from: "2025-03-01T10:00:00Z")!
        var email = CachedEmail(id: "x", subject: "Your flight itinerary", from: "a@b.c", receivedAt: received,
                                textBody: "Please find your ticket attached.", htmlBody: "")
        XCTAssertTrue(Extractor.extract(from: email.withAttachments).isEmpty)
        email.pdfText = text
        XCTAssertEqual(Extractor.extract(from: email.withAttachments).map(\.location), [.airport("LJU"), .airport("VIE")])
        XCTAssertTrue(AIExtractor.promptText(for: email.withAttachments, limit: 5000).contains("OS 712"))
    }
}

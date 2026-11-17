import Foundation

/// A place mentioned by a booking email, before it has been geocoded.
struct Candidate: Hashable {
    enum Location: Hashable {
        case airport(String)    // IATA code
        case address(String)    // free text to geocode
        case city(String, country: String)  // a named city (from the on-device model)
    }
    var location: Location
    var source: VisitSource
    var start: Date?
    var end: Date?
    var detail: String
    /// Destination named in the email ("Your booking in New York"). Hotel addresses often
    /// omit the city, so the geocoder uses this to pick the right "155 E. 50th Street".
    var cityHint: String? = nil
}

/// Pulls travel bookings out of an email in two passes:
///  1. schema.org JSON-LD markup (FlightReservation, LodgingReservation, ...) that airlines,
///     hotels and booking sites embed for Gmail/Apple Mail. Precise when present.
///  2. Text heuristics: airport codes on routes, hotel addresses and check-in/check-out dates.
enum Extractor {

    /// Structured data wins; then the on-device model's reading when there is one; then rules.
    static func extract(from email: CachedEmail, ai: AIResult? = nil) -> [Candidate] {
        let subject = email.subject.lowercased()
        if subject.range(of: #"cancel|storn|odpoved|annul|refund"#, options: .regularExpression) != nil {
            return []
        }
        let structured = extractJSONLD(html: email.htmlBody)
        let found: [Candidate]
        if !structured.isEmpty { found = structured }
        else if let ai { found = AIExtractor.candidates(from: ai, email: email) }
        else { found = extractHeuristics(email) }
        let hint = destinationHint(subject: email.subject, body: email.textBody.count > 200 ? email.textBody : htmlToText(email.htmlBody))
        return dedupe(found.map { c in
            var c = c
            if case .address = c.location { c.cityHint = hint }
            return c
        })
    }

    /// "Your booking in New York City is coming up", "Your trip to Paris", "Your Lisbon trip",
    /// "Reise nach Wien", "soggiorno a Roma"… Returns the place name as written.
    static func destinationHint(subject: String, body: String) -> String? {
        if let city = labelledCity(in: body) { return city }
        let name = #"(\p{Lu}[\p{L}'’.-]+(?:[ -](?:\p{Lu}[\p{L}'’.-]+|de|del|da|di|am|an|upon|on|sur)){0,3})"#
        let patterns = [
            #"(?:booking|reservation|stay|trip|holiday|vacation|visit|getaway|hotel|apartment|room) (?:in|to) "# + name,
            #"(?:travel|trip|journey|flight|going|heading|welcome) to "# + name,
            #"[Yy]our "# + name + #" (?:trip|stay|booking|reservation|getaway|adventure)"#,
            #"(?:Reise|Aufenthalt|Buchung) (?:nach|in) "# + name,
            #"(?:soggiorno|viaggio|prenotazione) a "# + name,
            #"(?:séjour|voyage|réservation) à "# + name,
            #"(?:potovanje|bivanje|rezervacij[aeo]|nastanitev|hotel) (?:v|za|na) "# + name,
        ]
        let stop: Set<String> = ["Your", "The", "Our", "This", "We", "You", "Booking", "Check", "Hotel", "Hotels", "Room",
                                 "Airbnb", "Expedia", "Dear", "Hi", "Hello", "Thanks", "Thank", "Confirmation", "See", "View",
                                 "Manage", "Day", "Today", "Tomorrow", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
                                 "Saturday", "Sunday", "Get", "Make", "Let", "Explore", "Discover", "Book", "More"]
        let head = String(body.prefix(4000))
        for text in [subject, head] {
            for p in patterns {
                guard let re = try? NSRegularExpression(pattern: p),
                      let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let r = Range(m.range(at: 1), in: text) else { continue }
                var place = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: " .-'’"))
                // Trailing all-caps or stop words are not part of the place ("New York City Is").
                var words = place.split(separator: " ").map(String.init)
                while let last = words.last, stop.contains(last) { words.removeLast() }
                guard let first = words.first, !stop.contains(first), first.count > 1 else { continue }
                place = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,-'’"))
                return place
            }
        }
        return nil
    }

    private static func dedupe(_ c: [Candidate]) -> [Candidate] {
        var seen = Set<Candidate.Location>()
        return c.filter { seen.insert($0.location).inserted }
    }

    // MARK: - JSON-LD

    static func extractJSONLD(html: String) -> [Candidate] {
        guard html.range(of: "ld+json", options: .caseInsensitive) != nil else { return [] }
        let pattern = #"<script[^>]*application/ld\+json[^>]*>(.*?)</script>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        var out: [Candidate] = []
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range(at: 1))
            for candidateJSON in [raw, decodeEntities(raw)] {
                if let data = candidateJSON.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    walk(obj, into: &out)
                    break
                }
            }
        }
        return out
    }

    private static func walk(_ obj: Any, into out: inout [Candidate]) {
        if let arr = obj as? [Any] { arr.forEach { walk($0, into: &out) }; return }
        guard let dict = obj as? [String: Any] else { return }
        if let graph = dict["@graph"] { walk(graph, into: &out) }

        let types = typeNames(dict)
        let reservationFor = dict["reservationFor"]
        let targets: [[String: Any]] = (reservationFor as? [[String: Any]]) ?? [(reservationFor as? [String: Any])].compactMap { $0 }

        if types.contains("FlightReservation") {
            for flight in targets {
                let number = [str((flight["airline"] as? [String: Any])?["iataCode"]), str(flight["flightNumber"])]
                    .compactMap { $0 }.joined()
                let dep = flight["departureAirport"] as? [String: Any]
                let arr = flight["arrivalAirport"] as? [String: Any]
                let depCode = str(dep?["iataCode"])
                let arrCode = str(arr?["iataCode"])
                let route = [depCode, arrCode].compactMap { $0 }.joined(separator: " → ")
                let detail = [number, route].filter { !$0.isEmpty }.joined(separator: " · ")
                let depTime = parseDate(flight["departureTime"])
                let arrTime = parseDate(flight["arrivalTime"]) ?? depTime
                if let depCode { out.append(.init(location: .airport(depCode), source: .flight, start: depTime, end: nil, detail: detail)) }
                if let arrCode { out.append(.init(location: .airport(arrCode), source: .flight, start: arrTime, end: nil, detail: detail)) }
            }
        } else if types.contains("LodgingReservation") {
            for lodging in targets {
                let name = str(lodging["name"]) ?? ""
                let query = addressString(lodging["address"]) ?? name
                guard !query.isEmpty else { continue }
                out.append(.init(
                    location: .address(query), source: .hotel,
                    start: parseDate(dict["checkinTime"]) ?? parseDate(dict["checkinDate"]),
                    end: parseDate(dict["checkoutTime"]) ?? parseDate(dict["checkoutDate"]),
                    detail: name))
            }
        } else if types.contains("TrainReservation") || types.contains("BusReservation") {
            let source: VisitSource = types.contains("TrainReservation") ? .train : .bus
            for trip in targets {
                let arrival = (trip["arrivalStation"] ?? trip["arrivalBusStop"]) as? [String: Any]
                let departure = (trip["departureStation"] ?? trip["departureBusStop"]) as? [String: Any]
                let detail = [str(departure?["name"]), str(arrival?["name"])].compactMap { $0 }.joined(separator: " → ")
                for (stop, time) in [(departure, trip["departureTime"]), (arrival, trip["arrivalTime"])] {
                    guard let stop, let q = addressString(stop["address"]) ?? str(stop["name"]) else { continue }
                    out.append(.init(location: .address(q), source: source, start: parseDate(time), end: nil, detail: detail))
                }
            }
        } else {
            // Containers such as {"@type": "EmailMessage", "about": ...} or nested arrays.
            for (key, value) in dict where key != "@context" && (value is [Any] || value is [String: Any]) {
                walk(value, into: &out)
            }
        }
    }

    private static func typeNames(_ d: [String: Any]) -> Set<String> {
        let raw = d["@type"]
        let names = (raw as? [String]) ?? [(raw as? String)].compactMap { $0 }
        return Set(names.map { $0.replacingOccurrences(of: "http://schema.org/", with: "")
            .replacingOccurrences(of: "https://schema.org/", with: "") })
    }

    private static func str(_ v: Any?) -> String? {
        if let s = v as? String { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        if let n = v as? NSNumber { return n.stringValue }
        if let d = v as? [String: Any] { return str(d["name"]) }
        return nil
    }

    private static func addressString(_ v: Any?) -> String? {
        if let s = str(v), !(v is [String: Any]) { return s }
        guard let a = v as? [String: Any] else { return nil }
        let parts = [str(a["streetAddress"]), str(a["postalCode"]), str(a["addressLocality"]),
                     str(a["addressRegion"]), str(a["addressCountry"])].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func parseDate(_ v: Any?) -> Date? {
        guard let s = str(v) else { return nil }
        let iso = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate]] {
            iso.formatOptions = opts
            if let d = iso.date(from: s) { return d }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    // MARK: - Heuristics

    private static let bookingProof = #"booking (reference|number|code)|confirmation (number|code)|reservation (number|code)|\bpnr\b|ticket number|e-?ticket|record locator|rezervacijsk|številka rezervacije|buchungs(nummer|code)|codice di prenotazione|numéro de réservation|localizador"#
    private static let flightWords = #"flight|boarding|departure|terminal|\bgate\b|let\b|letalsk|vzlet|abflug|flug|vuelo|volo|\bvol\b"#
    private static let stayWords = #"check-?in|check in|prijava|anreise|arrival date|arrivo|llegada|arrivée"#
    private static let promoWords = #"newsletter|% off|sale\b|deal|offer|coupon|voucher|gutschein|kupon|unsubscribe from|ponudba|akcija|angebot|survey|review your stay|how was your|win a|giveaway"#

    static func extractHeuristics(_ email: CachedEmail) -> [Candidate] {
        var text = email.textBody
        if text.count < 300, !email.htmlBody.isEmpty { text = htmlToText(email.htmlBody) }
        text = stripForwardHeaders(text)
            .replacingOccurrences(of: #"(https?://|www\.)\S+|\S*[?&]\S*=\S*"#, with: " ", options: .regularExpression)
        let lower = text.lowercased()
        let subject = email.subject.lowercased()

        guard subject.range(of: promoWords, options: .regularExpression) == nil else { return [] }
        guard lower.range(of: bookingProof, options: .regularExpression) != nil
                || subject.range(of: #"confirm|booking|reservation|itinerary|rezervacij|potrdil|buchung|bestätigung|e-?ticket"#, options: .regularExpression) != nil
        else { return [] }

        let dates = detectDates(in: text, around: email.receivedAt)
        var out: [Candidate] = []

        // Flights: airport codes in "(LJU)" or "LJU → FRA" / "LJU - FRA" form.
        if (subject + " " + lower).range(of: flightWords, options: .regularExpression) != nil {
            let codes = routeCodes(in: text)
            let start = dates.first?.date
            let detail = codes.joined(separator: " → ")
            for code in codes {
                out.append(.init(location: .airport(code), source: .flight, start: start, end: nil, detail: detail))
            }
        }

        // Hotels / apartments: first postal address + check-in / check-out dates.
        if out.isEmpty, (subject + " " + lower).range(of: stayWords, options: .regularExpression) != nil,
           let address = firstAddress(in: text) {
            let checkIn = date(after: #"check-?in|check in|prijava|anreise|arrivo|arrivée|llegada|arrival"#, in: text, dates: dates)
            let checkOut = date(after: #"check-?out|check out|odjava|abreise|partenza|départ|salida|departure"#, in: text, dates: dates)
            out.append(.init(location: .address(address), source: .hotel,
                             start: checkIn ?? dates.first?.date,
                             end: checkOut ?? (dates.count > 1 ? dates[1].date : nil),
                             detail: ""))
        }
        return out
    }

    private static let ignoredCodes: Set<String> = {
        var codes: Set<String> = [
            "THE", "AND", "FOR", "YOU", "ALL", "NEW", "VAT", "PNR", "REF", "TAX", "ETA", "ETD", "TBA", "TBD",
            "CET", "UTC", "GMT", "EST", "PST", "CST", "BST", "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN",
            "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC", "ADT", "CHD",
            "INF", "ADL", "BAG", "FEE", "OUT", "SEA", "VIP", "PDF", "APP", "WEB", "FAQ", "DIR", "NON", "QTY",
            // travel-industry abbreviations that collide with real airport codes
            "API", "SAF", "PIR", "CDW", "LDW", "SLP", "PAI", "ADM", "RES", "GPS", "ATM", "SSR", "EMD", "ITR",
        ]
        // Currency codes (HUF, CHF, ...) except ones that are mostly seen as major airports.
        codes.formUnion(Locale.commonISOCurrencyCodes.map { $0.uppercased() })
        codes.subtract(["MAD"])
        return codes
    }()

    private static let genericAirportWords: Set<String> = [
        "airport", "international", "intl", "regional", "municipal", "field", "airfield", "county", "city",
    ]

    static func routeCodes(in text: String) -> [String] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var found: [(Int, String)] = []

        // "LJU → FRA", "LJU-FRA", "ORD to OMA": two codes joined by a route separator.
        if let re = try? NSRegularExpression(pattern: #"(?<![\w-])([A-Z]{3})\s*(?:→|->|–|—|-|>|✈|to)\s*([A-Z]{3})(?![\w-])"#) {
            for m in re.matches(in: text, range: all) {
                let a = ns.substring(with: m.range(at: 1)), b = ns.substring(with: m.range(at: 2))
                guard a != b, !ignoredCodes.contains(a), !ignoredCodes.contains(b),
                      Airports.lookup(a) != nil, Airports.lookup(b) != nil else { continue }
                found.append((m.range(at: 1).location, a))
                found.append((m.range(at: 2).location, b))
            }
        }

        // "Frankfurt (FRA)": a code in brackets counts only next to its city/airport name or a time,
        // and not inside a comma-separated list of destinations. This rejects things like
        // "Advance Passenger Information (API)" or "local currency (HUF)".
        let listLines = verticalListRanges(in: text)
        if let re = try? NSRegularExpression(pattern: #"\(([A-Z]{3})\)"#) {
            for m in re.matches(in: text, range: all) {
                if listLines.contains(where: { NSLocationInRange(m.range.location, $0) }) { continue }
                let code = ns.substring(with: m.range(at: 1))
                guard !ignoredCodes.contains(code), let airport = Airports.lookup(code) else { continue }
                let beforeStart = max(0, m.range.location - 80)
                let before = ns.substring(with: NSRange(location: beforeStart, length: m.range.location - beforeStart))
                let afterStart = m.range.location + m.range.length
                let after = ns.substring(with: NSRange(location: afterStart, length: min(80, ns.length - afterStart)))

                let lineBefore = before.components(separatedBy: .newlines).last ?? before
                let inList = after.range(of: #"^\s*,"#, options: .regularExpression) != nil && lineBefore.contains(",")
                    && lineBefore.range(of: #"\d{1,2}[:.]\d{2}"#, options: .regularExpression) == nil
                if inList { continue }

                let names = fold(airport.city + " " + airport.name)
                    .components(separatedBy: CharacterSet.letters.inverted)
                    .filter { $0.count >= 4 && !genericAirportWords.contains($0) }
                let foldedBefore = fold(before)
                let nameNearby = names.contains { foldedBefore.contains($0) }
                let timeNearby = (before + " " + after).range(of: #"\b\d{1,2}[:.]\d{2}\b"#, options: .regularExpression) != nil
                if nameNearby || timeNearby { found.append((m.range(at: 1).location, code)) }
            }
        }

        var seen = Set<String>()
        return found.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0).inserted }
    }

    /// Ranges of lines that are part of a list of airports, e.g.
    ///     Amsterdam (AMS)
    ///     Athens (ATH)
    ///     Banja Luka (BNX)
    /// i.e. 3+ consecutive lines (blank lines allowed) holding only a name and a bracketed code.
    static func verticalListRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var lines: [(range: NSRange, isEntry: Bool, isBlank: Bool)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
            let isEntry = line.range(of: #"^[\p{L}][\p{L} .'’/-]{0,40}\(\s*[A-Z]{3}\s*\)\s*[*,;]?$"#, options: .regularExpression) != nil
            lines.append((range, isEntry, line.isEmpty))
        }
        var result: [NSRange] = []
        var run: [NSRange] = []
        func flush() { if run.count >= 3 { result += run }; run = [] }
        for l in lines {
            if l.isEntry { run.append(l.range) } else if !l.isBlank { flush() }
        }
        flush()
        return result
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Removes quote markers and the header lines of forwarded/replied messages, whose dates
    /// ("Date: 3 May 2021") would otherwise be mistaken for travel dates.
    static func stripForwardHeaders(_ text: String) -> String {
        let header = #"^\s*(date|sent|datum|poslano|gesendet|envoyé|enviado|inviato|subject|betreff|zadeva|objet|oggetto|from|von|od|to|an|za|cc|à|de|da)\s*:"#
        return text.components(separatedBy: .newlines).compactMap { line -> String? in
            let unquoted = line.replacingOccurrences(of: #"^(\s*>)+\s?"#, with: "", options: .regularExpression)
            let lower = unquoted.lowercased()
            if lower.range(of: header, options: .regularExpression) != nil { return nil }
            if lower.range(of: #"^\s*(on .* wrote:|am .* schrieb|dne .* je .* napisal|-+ ?(forwarded|original|weitergeleitete|posredovano).*-+|begin forwarded message)"#,
                           options: .regularExpression) != nil { return nil }
            return unquoted
        }.joined(separator: "\n")
    }

    struct FoundDate { let date: Date; let location: Int }

    /// Dates in the text that plausibly belong to the trip (shortly before receipt up to ~14 months after).
    static func detectDates(in text: String, around received: Date) -> [FoundDate] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let lower = received.addingTimeInterval(-3 * 86400)
        let upper = received.addingTimeInterval(430 * 86400)
        return detector.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .filter { m in (text as NSString).substring(with: m.range).rangeOfCharacter(from: .decimalDigits) != nil }
            .compactMap { m in m.date.map { FoundDate(date: $0, location: m.range.location) } }
            .filter { $0.date >= lower && $0.date <= upper }
    }

    private static func date(after keyword: String, in text: String, dates: [FoundDate]) -> Date? {
        guard let re = try? NSRegularExpression(pattern: keyword, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        let pos = m.range.location
        return dates.first { $0.location >= pos && $0.location - pos < 250 }?.date
    }

    static let cityLabels: Set<String> = ["city", "town", "ciudad", "città", "citta", "ville", "stadt", "ort", "kraj", "mesto", "localidad", "località", "localite", "localité"]

    /// Form-style hotel emails: "City:  (Centro) MADRID" → "Madrid".
    static func labelledCity(in text: String) -> String? {
        let labels = cityLabels.joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: #"(?im)^[ \t>*-]*(?:"# + labels + #")[ \t]*:[ \t]*(.+)$"#) else { return nil }
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            var v = String(text[r])
                .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\b\d{4,6}\b"#, with: " ", options: .regularExpression) // postcodes
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            v = v.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard (2...40).contains(v.count), v.range(of: #"^[\p{L}][\p{L} .'’-]*$"#, options: .regularExpression) != nil else { continue }
            if v == v.uppercased() { v = v.capitalized }
            return v
        }
        return nil
    }

    static let footer = #"©|\(c\)|all rights reserved|\binc\.|\bllc\b|\bltd\b|gmbh|\bb\.v\.|registered (office|address|in)|headquarter|privacy|unsubscribe|this email was sent|you are receiving|d\.o\.o\.|s\.r\.l\.|unlimited company|\bquay\b"#

    static func firstAddress(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue) else { return nil }
        let ns = text as NSString
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let c = m.addressComponents ?? [:]
            guard c[.city] != nil else { continue }
            // Skip the sender's company address in the footer.
            let lo = max(0, m.range.location - 150)
            let hi = min(ns.length, m.range.location + m.range.length + 150)
            let around = ns.substring(with: NSRange(location: lo, length: hi - lo)).lowercased()
            if around.range(of: footer, options: .regularExpression) != nil { continue }
            var city = c[.city]
            // "Street address: Calle Salud, 3 / City: MADRID" reads the label as the city.
            if let cv = city, cityLabels.contains(cv.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
                city = labelledCity(in: text)
            }
            let parts = [c[.street], c[.zip], city, c[.country]].compactMap { $0 }
            return parts.joined(separator: ", ")
        }
        return nil
    }

    // MARK: - HTML

    static func htmlToText(_ html: String) -> String {
        var s = html
        let rules: [(String, String)] = [
            (#"(?is)<(script|style|head)[^>]*>.*?</\1>"#, " "),
            (#"(?i)<br\s*/?>|</(p|div|tr|li|h[1-6]|table)>"#, "\n"),
            (#"(?i)</t[dh]>"#, "  "),
            (#"<[^>]+>"#, " "),
            (#"[ \t\u{00A0}]+"#, " "),
            (#"\n\s*\n+"#, "\n"),
        ]
        for (pattern, replacement) in rules {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return decodeEntities(s)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&rarr;": "→", "&ndash;": "–", "&mdash;": "—"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        guard let re = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) else { return out }
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let num = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10)
            result += num.flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? ""
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}

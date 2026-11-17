import Foundation
import FoundationModels

/// What the on-device model said about one email, saved so each email is read only once.
struct AIResult: Codable {
    var version: Int
    var isBooking: Bool
    var evidence: String
    var places: [AIPlace]
}

struct AIPlace: Codable {
    var kind: String
    var city: String
    var country: String
    var airport: String
    var start: String
    var end: String
}

@Generable
struct AITrip {
    @Guide(description: "true only if this email confirms a booking, ticket or stay for the recipient (not an ad, newsletter, survey, offer or general discussion)")
    var isBooking: Bool
    @Guide(description: "The booking reference, ticket number, or hotel name exactly as written in the email; empty if there is none")
    var evidence: String
    @Guide(description: "Places the traveller goes to or stays in. Empty if not a booking.")
    var places: [AITripPlace]
}

@Generable
struct AITripPlace {
    @Guide(description: "flight, hotel, train, bus, or other")
    var kind: String
    @Guide(description: "City name exactly as written in the email")
    var city: String
    @Guide(description: "Country name in English")
    var country: String
    @Guide(description: "3-letter IATA airport code for flights, else empty")
    var airport: String
    @Guide(description: "Arrival or check-in date as yyyy-MM-dd, or empty if unknown")
    var start: String
    @Guide(description: "Check-out or leaving date as yyyy-MM-dd, or empty")
    var end: String
}

/// Reads booking emails with Apple's on-device model (Apple Intelligence). Nothing leaves the Mac.
/// The model finds what rules miss (travel-agent itineraries, forwarded confirmations, post-stay
/// emails); its answers are then checked against the email text so invented places are dropped.
enum AIExtractor {
    /// Bump when the prompt or schema changes so emails get read again.
    static let version = 1

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static let dir: URL = {
        let url = Storage.root.appendingPathComponent("ai", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func url(for fileId: String) -> URL {
        dir.appendingPathComponent("\(fileId.replacingOccurrences(of: "/", with: "_")).json")
    }

    static func cached(fileId: String) -> AIResult? {
        guard let r = Storage.load(AIResult.self, from: url(for: fileId)), r.version == version else { return nil }
        return r
    }

    static func forget(fileId: String) {
        try? FileManager.default.removeItem(at: url(for: fileId))
    }

    static func save(_ result: AIResult, fileId: String) {
        Storage.save(result, to: url(for: fileId))
    }

    // MARK: which emails are worth the model's time

    private static let promoSubject = #"newsletter|% off|\bsale\b|\bdeals?\b|offer|coupon|voucher|gutschein|kupon|unsubscribe|ponudba|akcija|angebot|survey|how was your|win a|giveaway|webinar|call for papers?|\bcfp\b|destinations|consider the|inspir|ideas for|book now|travel from|\bsave\b|explore|discover|members only|exclusive"#
    private static let promoSender = #"newsletter|news\.|news@|marketing|promo|offers?@|deals?@|mailer|rewards|loyalty"#
    private static let travelWords = #"booking|reservation|reservierung|prenotazione|réservation|reserva|rezervacij|itinerary|e-?ticket|boarding|flight|check-?in|confirmation|confirmed|potrdil|vozovnic|letalsk|buchung|hotel|accommodation|nastanitev|your stay|your trip"#

    static func shouldAsk(_ email: CachedEmail) -> Bool {
        let subject = email.subject
        if subject.range(of: promoSubject, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if subject.range(of: #"cancel|storn|odpoved|annul|refund"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if email.from.range(of: promoSender, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        let body = email.textBody.isEmpty ? email.htmlBody : email.textBody
        return (subject + " " + body.prefix(20000)).range(of: travelWords, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: asking the model

    private static let instructions = """
    You read one email from a person's mailbox and extract their travel bookings: flights, hotels, apartments, trains, buses.
    List every city the traveller flies to or stays in, including the departure city of the first flight.
    Only use places that are written in the email. Never guess.
    Ignore ads, newsletters, offers, lists of destinations, company addresses in signatures, and places only mentioned in passing.
    Dates: the email's sent date is given; use it to work out the year for dates like 18OCT.
    """

    static func promptText(for email: CachedEmail, limit: Int) -> String {
        var text = email.textBody
        if text.count < 300, !email.htmlBody.isEmpty { text = Extractor.htmlToText(email.htmlBody) }
        text = text
            .replacingOccurrences(of: #"(https?://|www\.)\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
        let sent = email.receivedAt.formatted(.iso8601.year().month().day())
        // Keep the PDF part in view when the body itself is long.
        if let r = text.range(of: "--- PDF attachment ---") {
            let body = text[..<r.lowerBound], pdf = text[r.lowerBound...]
            text = String(body.prefix(max(limit - pdf.count, limit / 3))) + "\n" + String(pdf.prefix(limit))
        }
        return "Sent: \(sent)\nSubject: \(email.subject)\nFrom: \(email.from)\n\n\(text.prefix(limit))"
    }

    /// nil when the model couldn't run (unavailable, cancelled); a stored "not a booking"
    /// result when it refused or the email can't fit, so it isn't retried every scan.
    static func read(_ email: CachedEmail) async -> AIResult? {
        for limit in [5000, 2200] {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let r = try await session.respond(to: promptText(for: email, limit: limit), generating: AITrip.self)
                let trip = r.content
                return AIResult(version: version, isBooking: trip.isBooking, evidence: trip.evidence,
                                places: trip.places.map { AIPlace(kind: $0.kind, city: $0.city, country: $0.country,
                                                                  airport: $0.airport, start: $0.start, end: $0.end) })
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error { continue }
                return AIResult(version: version, isBooking: false, evidence: "", places: [])
            } catch {
                return nil
            }
        }
        return AIResult(version: version, isBooking: false, evidence: "", places: [])
    }

    // MARK: turning answers into candidates

    /// Keeps only what the email backs up: a booking reference or hotel name that appears in
    /// the text, and places whose name or airport code is actually written there.
    static func candidates(from result: AIResult, email: CachedEmail) -> [Candidate] {
        guard result.isBooking else { return [] }
        let text = promptText(for: email, limit: 60000)
        let folded = fold(text)
        let evidencePieces = result.evidence.split(whereSeparator: { ",;/|".contains($0) })
            .map { fold(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 }
        // Ads quote real text too, so the evidence must look like a booking reference:
        // a number or a PNR-style code (ZE4MKQ), and it must be in the email.
        let looksLikeReference = { (p: String) -> Bool in
            p.rangeOfCharacter(from: .decimalDigits) != nil
                || result.evidence.range(of: #"\b[A-Z0-9]{5,8}\b"#, options: .regularExpression) != nil
        }
        guard evidencePieces.contains(where: { folded.contains($0) && looksLikeReference($0) }) else { return [] }

        let flights = result.places.filter { $0.kind.lowercased() == "flight" }
        let route = flights.compactMap { $0.airport.count == 3 && text.contains($0.airport) ? $0.airport : nil }
        var out: [Candidate] = []
        for p in result.places {
            let city = p.city.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = p.airport.uppercased()
            let codeInText = code.count == 3 && text.range(of: "\\b\(code)\\b", options: .regularExpression) != nil
            let cityInText = city.count >= 2 && mentionedOutsideFooter(fold(city), in: folded)
            guard cityInText || codeInText else { continue }

            let source: VisitSource = switch p.kind.lowercased() {
            case "flight": .flight
            case "train": .train
            case "bus": .bus
            default: .hotel
            }
            let location: Candidate.Location
            if source == .flight, codeInText, Airports.lookup(code) != nil {
                location = .airport(code)
            } else if cityInText {
                location = .city(city, country: p.country)
            } else {
                continue
            }
            out.append(Candidate(location: location, source: source,
                                 start: date(p.start, around: email.receivedAt),
                                 end: date(p.end, around: email.receivedAt),
                                 detail: source == .flight ? route.joined(separator: " → ") : ""))
        }
        return out
    }

    /// A city that only shows up next to "© … Ltd" or "Registered office" is the sender's
    /// company address (Airbnb Ireland in Dublin), not a destination.
    private static func mentionedOutsideFooter(_ city: String, in text: String) -> Bool {
        var from = text.startIndex
        while let r = text.range(of: city, range: from..<text.endIndex) {
            let lo = text.index(r.lowerBound, offsetBy: -200, limitedBy: text.startIndex) ?? text.startIndex
            let hi = text.index(r.upperBound, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
            if text[lo..<hi].range(of: Extractor.footer, options: .regularExpression) == nil { return true }
            from = r.upperBound
        }
        return false
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Model dates are trusted only near the email's own date (trips are booked up to a year
    /// ahead; thank-you emails come after the stay).
    private static func date(_ s: String, around received: Date) -> Date? {
        guard let d = dayFormat.date(from: s.trimmingCharacters(in: .whitespaces)) else { return nil }
        let noon = d.addingTimeInterval(12 * 3600)
        guard noon > received.addingTimeInterval(-120 * 86400), noon < received.addingTimeInterval(430 * 86400) else { return nil }
        return noon
    }
}

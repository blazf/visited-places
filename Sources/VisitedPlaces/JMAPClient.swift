import Foundation
import PDFKit

/// Tiny read-only JMAP client for Fastmail (RFC 8620 / 8621).
/// Authenticates with a Fastmail API token (Settings → Privacy & Security → API tokens).
struct JMAPClient {
    let token: String
    var sessionURL = URL(string: "https://api.fastmail.com/jmap/session")!

    struct Session { let apiURL: URL; let accountId: String; let username: String; var downloadURL: String = "" }

    enum JMAPError: LocalizedError {
        case http(Int, String)
        case protocolError(String)
        var errorDescription: String? {
            switch self {
            case .http(401, _): "Fastmail rejected the API token (HTTP 401). Check it in Settings."
            case .http(let code, let body): "Fastmail returned HTTP \(code): \(body.prefix(200))"
            case .protocolError(let msg): "JMAP error: \(msg)"
            }
        }
    }

    // Subject words that typically appear in travel booking emails (EN, SL, DE, HR, IT, FR, ES).
    // Fastmail matches whole words, so list the word forms rather than stems.
    static let subjectTerms = [
        "booking", "reservation", "itinerary", "e-ticket", "eticket", "ticket", "boarding pass", "flight",
        "hotel", "check-in", "trip", "travel", "your stay", "accommodation",
        "rezervacija", "rezervacijo", "rezervacije", "potrditev", "vozovnica", "vozovnico", "letalska",
        "nastanitev", "potovanje",
        "buchung", "buchungsbestätigung", "reservierung", "flug", "reise", "reisebestätigung",
        "prenotazione", "réservation", "reserva", "vuelo", "volo",
        // trains and buses
        "train", "rail", "railway", "railcard", "bus", "coach", "seat reservation", "journey",
        "vlak", "vlaka", "avtobus", "avtobusna", "železnice",
        "zug", "bahn", "fahrkarte", "bahnticket", "sitzplatzreservierung", "fernbus",
        "treno", "biglietto", "autobus", "billet", "tren", "billete",
        "vonat", "vonatjegy", "jegy", "menetjegy",
    ]

    // Phrases that almost only occur in the body of real bookings.
    static let bodyPhrases = [
        "booking reference", "booking number", "booking code", "confirmation number", "confirmation code",
        "reservation number", "reservation code", "record locator", "PNR", "ticket number", "e-ticket",
        "boarding pass", "check-in date", "check-out date", "flight number",
        "številka rezervacije", "rezervacijska koda", "koda rezervacije",
        "Buchungsnummer", "Buchungscode", "Reservierungsnummer", "Buchungsreferenz",
        "codice prenotazione", "numéro de réservation", "localizador",
    ]

    // Senders that send bookings with neutral subjects.
    static let senderTerms = [
        "booking.com", "airbnb", "expedia", "hotels.com", "agoda", "trip.com", "kayak", "skyscanner",
        "lufthansa", "ryanair", "easyjet", "wizzair", "airfrance", "klm", "britishairways", "ba.com",
        "turkishairlines", "emirates", "qatarairways", "austrian", "swiss.com", "flysas", "norwegian",
        "united.com", "delta.com", "aa.com", "vueling", "iberia", "flytap", "croatiaairlines", "lot.com",
        "airserbia", "transavia", "eurowings", "trainline", "omio", "flixbus", "oebb", "bahn.de",
        "marriott", "hilton", "ihg", "accor", "hyatt", "radisson", "hostelworld",
        "adria", "aegeanair", "finnair", "aircanada", "jetblue", "southwest", "alaskaair", "brusselsairlines",
        "condor", "volotea", "airbaltic", "ita-airways", "alitalia", "aerlingus", "icelandair", "singaporeair",
        "cathaypacific", "ana.co.jp", "jal.com", "etihad", "flydubai", "pegasus", "sunexpress",
        "alamo", "hertz", "sixt", "avis", "europcar", "enterprise", "rentalcars", "nationalcar",
        "hrs.com", "hotel.de", "trivago", "vrbo", "kiwi.com", "edreams", "opodo", "lastminute", "momondo",
        "travelperk", "egencia", "concur", "navan", "tripit", "cwtsatotravel", "fcm", "amexgbt",
        "sncf", "italotreno", "trenitalia", "sbb.ch", "slo-zeleznice", "arriva", "amtrak", "eurostar",
        "bestwestern", "wyndham", "choicehotels", "fourseasons", "kempinski", "nh-hotels", "melia",
        "citizenm", "motel-one", "premierinn", "ibis", "novotel", "sheraton", "westin",
        // found in booking emails already downloaded
        "citadines", "ascott", "milesandmore", "goopti", "supershuttle", "b-rail", "sncb", "belgiantrain",
        "affinia", "pkghlrss", "traveleurope", "hrs.de", "flibco", "airdolomiti", "terme-krka", "chasetravel",
        "legoland", "hotel",
    ]

    func session() async throws -> Session {
        let json = try await request(url: sessionURL, body: nil)
        guard let api = json["apiUrl"] as? String, let apiURL = URL(string: api),
              let accounts = json["primaryAccounts"] as? [String: Any],
              let accountId = accounts["urn:ietf:params:jmap:mail"] as? String else {
            throw JMAPError.protocolError("Session has no mail account")
        }
        return Session(apiURL: apiURL, accountId: accountId, username: json["username"] as? String ?? "",
                       downloadURL: json["downloadUrl"] as? String ?? "")
    }

    /// Returns ids of emails that look travel-related, newest first.
    func queryBookingEmailIds(session: Session, progress: (Int, Int) -> Void) async throws -> [String] {
        let conditions: [[String: Any]] =
            Self.subjectTerms.map { ["subject": $0] }
            + Self.senderTerms.map { ["from": $0] }
            + Self.bodyPhrases.map { ["body": "\"\($0)\""] }
        let filter: [String: Any] = ["operator": "OR", "conditions": conditions]

        var ids: [String] = []
        var position = 0
        let pageSize = 500
        while true {
            let args: [String: Any] = [
                "accountId": session.accountId,
                "filter": filter,
                "sort": [["property": "receivedAt", "isAscending": false]],
                "collapseThreads": false,
                "position": position,
                "limit": pageSize,
                "calculateTotal": true,
            ]
            let result = try await call(session: session, method: "Email/query", args: args)
            let page = result["ids"] as? [String] ?? []
            let total = result["total"] as? Int ?? (ids.count + page.count)
            ids += page
            progress(ids.count, total)
            if page.count < pageSize || ids.count >= total { break }
            position += page.count
        }
        return ids
    }

    func fetchEmails(session: Session, ids: [String]) async throws -> [CachedEmail] {
        let args: [String: Any] = [
            "accountId": session.accountId,
            "ids": ids,
            "properties": ["id", "subject", "from", "receivedAt", "textBody", "htmlBody", "bodyValues"],
            "fetchTextBodyValues": true,
            "fetchHTMLBodyValues": true,
            "maxBodyValueBytes": 400_000,
        ]
        let result = try await call(session: session, method: "Email/get", args: args)
        let list = result["list"] as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        return list.compactMap { e in
            guard let id = e["id"] as? String else { return nil }
            let values = e["bodyValues"] as? [String: [String: Any]] ?? [:]
            func bodies(_ key: String, type: String) -> String {
                let parts = e[key] as? [[String: Any]] ?? []
                return parts.filter { ($0["type"] as? String) == type }
                    .compactMap { $0["partId"] as? String }
                    .compactMap { values[$0]?["value"] as? String }
                    .joined(separator: "\n")
            }
            let from = (e["from"] as? [[String: Any]])?.first
            let fromString = [from?["name"] as? String, (from?["email"] as? String).map { "<\($0)>" }]
                .compactMap { $0 }.joined(separator: " ")
            return CachedEmail(
                id: id,
                subject: e["subject"] as? String ?? "",
                from: fromString,
                receivedAt: (e["receivedAt"] as? String).flatMap { iso.date(from: $0) } ?? Date(),
                textBody: bodies("textBody", type: "text/plain"),
                htmlBody: bodies("htmlBody", type: "text/html")
            )
        }
    }

    /// Text of the PDF attachments of each email ("" when it has none). Rough on purpose:
    /// small PDFs only, at most three per email, plain text via PDFKit, no OCR.
    func fetchPDFTexts(session: Session, ids: [String]) async throws -> [String: String] {
        let args: [String: Any] = [
            "accountId": session.accountId,
            "ids": ids,
            "properties": ["id", "attachments"],
            "bodyProperties": ["blobId", "name", "type", "size"],
        ]
        let result = try await call(session: session, method: "Email/get", args: args)
        var out: [String: String] = [:]
        for e in result["list"] as? [[String: Any]] ?? [] {
            guard let id = e["id"] as? String else { continue }
            let pdfs = (e["attachments"] as? [[String: Any]] ?? []).filter { a in
                let type = (a["type"] as? String ?? "").lowercased()
                let name = (a["name"] as? String ?? "").lowercased()
                let size = a["size"] as? Int ?? 0
                return (type == "application/pdf" || name.hasSuffix(".pdf")) && size > 0 && size < 3_000_000
            }.prefix(3)
            var texts: [String] = []
            for a in pdfs {
                try Task.checkCancellation()
                guard let blobId = a["blobId"] as? String,
                      let data = try? await download(session: session, blobId: blobId, name: a["name"] as? String ?? "file.pdf"),
                      let text = PDFDocument(data: data)?.string else { continue }
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { texts.append(String(clean.prefix(20000))) }
            }
            out[id] = texts.joined(separator: "\n\n")
        }
        return out
    }

    private func download(session: Session, blobId: String, name: String) async throws -> Data {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let urlString = session.downloadURL
            .replacingOccurrences(of: "{accountId}", with: enc(session.accountId))
            .replacingOccurrences(of: "{blobId}", with: enc(blobId))
            .replacingOccurrences(of: "{name}", with: enc(name))
            .replacingOccurrences(of: "{type}", with: enc("application/pdf"))
        guard let url = URL(string: urlString) else { throw JMAPError.protocolError("Bad download URL") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw JMAPError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "")
        }
        return data
    }

    // MARK: plumbing

    private func call(session: Session, method: String, args: [String: Any]) async throws -> [String: Any] {
        let body: [String: Any] = [
            "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            "methodCalls": [[method, args, "c0"]],
        ]
        let json = try await request(url: session.apiURL, body: body)
        guard let responses = json["methodResponses"] as? [[Any]], let first = responses.first,
              first.count >= 2, let name = first[0] as? String, let result = first[1] as? [String: Any] else {
            throw JMAPError.protocolError("Malformed response to \(method)")
        }
        if name == "error" {
            throw JMAPError.protocolError("\(result["type"] ?? "unknown") \(result["description"] ?? "")")
        }
        return result
    }

    private func request(url: URL, body: [String: Any]?) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw JMAPError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JMAPError.protocolError("Response is not a JSON object")
        }
        return json
    }
}

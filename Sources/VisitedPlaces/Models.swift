import Foundation
import CoreLocation

/// Where a visit came from.
enum VisitSource: String, Codable, CaseIterable {
    case flight, hotel, train, bus, manual

    var label: String {
        switch self {
        case .flight: "Flight"
        case .hotel: "Hotel"
        case .train: "Train"
        case .bus: "Bus"
        case .manual: "Manual"
        }
    }

    var symbol: String {
        switch self {
        case .flight: "airplane"
        case .hotel: "bed.double.fill"
        case .train: "tram.fill"
        case .bus: "bus.fill"
        case .manual: "mappin"
        }
    }
}

/// One stay in one place, usually derived from one booking email.
struct Visit: Identifiable, Codable, Hashable {
    var id = UUID()
    var city: String
    var countryCode: String          // ISO 3166-1 alpha-2, e.g. "SI"
    var latitude: Double
    var longitude: Double
    var startDate: Date?
    var endDate: Date?
    var source: VisitSource
    var detail: String = ""          // e.g. "LJU → FRA" or hotel name
    var emailId: String?
    var emailSubject: String?

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var countryName: String { Countries.name(for: countryCode) }
    var placeKey: String { Self.placeKey(city: city, countryCode: countryCode) }

    /// Used to avoid adding the same booking twice, and to remember deletions.
    var dedupeKey: String {
        let day = startDate.map { ISO8601DateFormatter.dayOnly.string(from: $0) } ?? "-"
        return "\(placeKey)|\(day)|\(source.rawValue)"
    }

    static func placeKey(city: String, countryCode: String) -> String {
        "\(countryCode.uppercased())|\(city.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))"
    }
}

/// A city pin on the map: all visits to the same city grouped together.
struct Place: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let city: String
    let countryCode: String
    let coordinate: CLLocationCoordinate2D
    let visits: [Visit]

    var firstDate: Date? { visits.compactMap(\.startDate).min() }
    var lastDate: Date? { visits.compactMap { $0.endDate ?? $0.startDate }.max() }

    static func == (a: Place, b: Place) -> Bool { a.key == b.key && a.visits == b.visits }
    func hash(into h: inout Hasher) { h.combine(key) }
}

/// An email as stored in the local mail cache.
struct CachedEmail: Codable, Identifiable {
    let id: String
    let subject: String
    let from: String
    let receivedAt: Date
    let textBody: String
    let htmlBody: String
    /// Text of PDF attachments: nil = not looked at yet, "" = none.
    var pdfText: String? = nil

    /// The email as the extractors should read it: body plus any PDF attachment text.
    var withAttachments: CachedEmail {
        guard let pdf = pdfText, !pdf.isEmpty else { return self }
        let body = textBody.count < 300 && !htmlBody.isEmpty ? Extractor.htmlToText(htmlBody) : textBody
        return CachedEmail(id: id, subject: subject, from: from, receivedAt: receivedAt,
                           textBody: body + "\n\n--- PDF attachment ---\n" + pdf,
                           htmlBody: htmlBody, pdfText: pdfText)
    }
}

enum Countries {
    static func name(for code: String) -> String {
        Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? code
    }

    /// Converts "SI" into the 🇸🇮 flag emoji.
    static func flag(for code: String) -> String {
        code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }
            .map(String.init).joined()
    }

    /// Best-effort conversion of a country name or code to an ISO alpha-2 code.
    static func code(for nameOrCode: String) -> String? {
        let trimmed = nameOrCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 2, Locale.Region.isoRegions.contains(where: { $0.identifier == trimmed.uppercased() }) {
            return trimmed.uppercased()
        }
        let needle = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for locale in [Locale(identifier: "en_US"), Locale.current, Locale(identifier: "sl_SI"), Locale(identifier: "de_DE")] {
            for region in Locale.Region.isoRegions where region.identifier.count == 2 {
                if let n = locale.localizedString(forRegionCode: region.identifier),
                   n.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == needle {
                    return region.identifier
                }
            }
        }
        return nil
    }
}

extension ISO8601DateFormatter {
    static let dayOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}

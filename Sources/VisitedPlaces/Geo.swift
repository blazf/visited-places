import Foundation
import CoreLocation

struct Airport {
    let iata: String
    let latitude: Double
    let longitude: Double
    let countryCode: String
    let city: String
    let name: String
}

/// Offline IATA airport lookup (bundled OurAirports data, public domain).
enum Airports {
    static let all: [String: Airport] = {
        let candidates = [
            Bundle.main.url(forResource: "airports", withExtension: "tsv"),
            // `swift run` during development: Resources/ next to Package.swift
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../Resources/airports.tsv").standardized,
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("airports.tsv not found")
            return [:]
        }
        var map: [String: Airport] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6, let lat = Double(f[1]), let lon = Double(f[2]) else { continue }
            map[f[0]] = Airport(iata: f[0], latitude: lat, longitude: lon, countryCode: f[3], city: f[4], name: f[5])
        }
        return map
    }()

    static func lookup(_ code: String) -> Airport? { all[code.uppercased()] }
}

struct GeoResult: Codable, Hashable {
    let city: String
    let countryCode: String
    let latitude: Double
    let longitude: Double
}

/// Forward geocoding via Apple's geocoder, cached on disk and throttled
/// (Apple rate-limits CLGeocoder to roughly one request per second).
actor Geocoder {
    static let shared = Geocoder()

    private var cache: [String: GeoResult?]
    private var lastRequest = Date.distantPast
    private let geocoder = CLGeocoder()

    init() {
        cache = Storage.load([String: GeoResult?].self, from: Storage.geocacheFile) ?? [:]
    }

    func geocode(_ query: String) async -> GeoResult? {
        let key = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let hit = cache[key] { return hit }

        let wait = 1.2 - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        lastRequest = Date()

        var result: GeoResult?
        do {
            let placemarks = try await geocoder.geocodeAddressString(query)
            if let p = placemarks.first, let loc = p.location, let cc = p.isoCountryCode {
                result = GeoResult(
                    city: p.locality ?? p.subAdministrativeArea ?? p.administrativeArea ?? p.name ?? query,
                    countryCode: cc,
                    latitude: loc.coordinate.latitude,
                    longitude: loc.coordinate.longitude)
            }
        } catch let error as CLError where error.code == .network {
            return nil // throttled or offline: don't cache, try again next scan
        } catch {
            result = nil
        }
        cache[key] = result
        Storage.save(cache, to: Storage.geocacheFile)
        return result
    }
}

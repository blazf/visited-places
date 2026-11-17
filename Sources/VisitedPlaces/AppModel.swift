import Foundation
import SwiftUI
import CoreLocation

@MainActor
final class AppModel: ObservableObject {
    @Published var visits: [Visit]
    @Published var selectedPlaceKey: String?
    @Published var isBusy = false
    @Published var status = ""
    @Published var progress: Double?
    @Published var errorMessage: String?
    @Published var hasToken = Keychain.hasToken()
    @Published private(set) var cachedEmailCount = Storage.cachedMailIds().count
    @Published private(set) var lastSync: Date?

    private var state: AppState
    private var work: Task<Void, Never>?

    init() {
        visits = Storage.load([Visit].self, from: Storage.visitsFile) ?? []
        state = Storage.load(AppState.self, from: Storage.stateFile) ?? AppState()
        lastSync = state.lastSync
        if state.extractorVersion != Self.extractorVersion, !Storage.cachedMailIds().isEmpty {
            Task { @MainActor in self.rescanAll() }
        }
    }

    /// Bump when extraction rules change so existing data gets re-extracted on next launch.
    static let extractorVersion = 6

    // MARK: derived data

    var places: [Place] {
        Dictionary(grouping: visits, by: \.placeKey).map { key, visits in
            let sorted = visits.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            let first = sorted[0]
            return Place(key: key, city: first.city, countryCode: first.countryCode,
                         coordinate: first.coordinate, visits: sorted)
        }
    }

    var countries: [(code: String, places: [Place])] {
        Dictionary(grouping: places, by: \.countryCode)
            .map { (code: $0.key, places: $0.value.sorted { $0.city < $1.city }) }
            .sorted { Countries.name(for: $0.code) < Countries.name(for: $1.code) }
    }

    var selectedPlace: Place? { places.first { $0.key == selectedPlaceKey } }

    // MARK: settings

    func saveToken(_ token: String) {
        Keychain.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
        hasToken = Keychain.hasToken()
    }

    func testConnection() async -> String {
        guard let token = Keychain.readToken() else { return "No token saved." }
        do {
            let session = try await JMAPClient(token: token).session()
            return "Connected as \(session.username)."
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: sync + scan

    func syncAndScan() {
        guard !isBusy else { return }
        work = Task {
            isBusy = true
            defer { isBusy = false; progress = nil }
            do {
                try await syncMail()
                await scanEmails()
                await readWithAI()
            } catch is CancellationError {
                status = "Stopped."
            } catch {
                errorMessage = error.localizedDescription
                status = "Sync failed."
            }
        }
    }

    /// Re-extracts everything from the local mail cache with the current rules.
    /// Places added by hand and deletions you made are kept.
    func rescanAll() {
        guard !isBusy else { return }
        visits.removeAll { $0.source != .manual && $0.emailId != nil }
        selectedPlaceKey = nil
        persistVisits()
        state.processedEmailIds = []
        state.extractorVersion = Self.extractorVersion
        persistState()
        work = Task {
            isBusy = true
            defer { isBusy = false; progress = nil }
            await scanEmails()
            await readWithAI()
        }
    }

    func cancelWork() { work?.cancel() }

    /// Downloads travel-looking emails from Fastmail that aren't cached locally yet.
    private func syncMail() async throws {
        guard let token = Keychain.readToken() else {
            throw NSError(domain: "VisitedPlaces", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Add your Fastmail API token in Settings (⌘,) first."])
        }
        let client = JMAPClient(token: token)
        status = "Connecting to Fastmail…"
        let session = try await client.session()

        status = "Searching for booking emails…"
        let ids = try await client.queryBookingEmailIds(session: session) { [weak self] got, total in
            Task { @MainActor in self?.status = "Searching for booking emails… \(got)/\(total)" }
        }
        let cached = Storage.cachedMailIds()
        let missing = ids.filter { !cached.contains($0.replacingOccurrences(of: "/", with: "_")) }

        for (i, batch) in stride(from: 0, to: missing.count, by: 50).map({ Array(missing[$0..<min($0 + 50, missing.count)]) }).enumerated() {
            try Task.checkCancellation()
            status = "Downloading emails… \(min((i + 1) * 50, missing.count))/\(missing.count)"
            progress = Double(i * 50) / Double(max(missing.count, 1))
            let emails = try await client.fetchEmails(session: session, ids: batch)
            for email in emails { Storage.save(email, to: Storage.mailURL(for: email.id)) }
        }
        try await fetchPDFs(client: client, session: session)
        cachedEmailCount = Storage.cachedMailIds().count
        state.lastSync = Date()
        lastSync = state.lastSync
        persistState()
        status = "Synced \(ids.count) candidate emails (\(missing.count) new)."
    }

    /// Downloads small PDF attachments of cached emails that haven't been checked yet and stores
    /// their text. Emails that gained text are queued to be read again (rules and the model).
    private func fetchPDFs(client: JMAPClient, session: JMAPClient.Session) async throws {
        status = "Looking for PDF attachments…"
        let unchecked: [String] = await Task.detached(priority: .utility) {
            Storage.cachedMailIds().sorted().compactMap { fileId in
                guard let e = Storage.loadEmail(id: fileId), e.pdfText == nil else { return nil }
                return e.id
            }
        }.value
        guard !unchecked.isEmpty else { return }
        var found = 0
        for (i, batch) in stride(from: 0, to: unchecked.count, by: 25).map({ Array(unchecked[$0..<min($0 + 25, unchecked.count)]) }).enumerated() {
            try Task.checkCancellation()
            status = "Reading PDF attachments… \(min((i + 1) * 25, unchecked.count))/\(unchecked.count) · \(found) with text"
            progress = Double(i * 25) / Double(unchecked.count)
            let texts = try await client.fetchPDFTexts(session: session, ids: batch)
            for id in batch {
                guard var email = Storage.loadEmail(id: id), let text = texts[id] else { continue }
                email.pdfText = text
                Storage.save(email, to: Storage.mailURL(for: id))
                guard !text.isEmpty else { continue }
                found += 1
                // Read this email again now that it has more text.
                let fileId = id.replacingOccurrences(of: "/", with: "_")
                state.processedEmailIds.remove(fileId)
                AIExtractor.forget(fileId: fileId)
                visits.removeAll { $0.emailId == id && $0.source != .manual }
            }
            persistState()
        }
        persistVisits()
    }

    /// Runs the extractor over cached emails that haven't been scanned yet.
    private func scanEmails() async {
        let pending = Storage.cachedMailIds().subtracting(state.processedEmailIds).sorted()
        guard !pending.isEmpty else {
            status = "Up to date · \(visits.count) visits from \(cachedEmailCount) emails."
            return
        }
        var known = Set(visits.map(\.dedupeKey)).union(state.dismissedKeys)
        var added = 0

        for (i, fileId) in pending.enumerated() {
            if Task.isCancelled { break }
            progress = Double(i) / Double(pending.count)
            status = "Scanning emails… \(i + 1)/\(pending.count) · \(added) visits found"

            let parsed: (CachedEmail, [Candidate])? = await Task.detached(priority: .userInitiated) {
                guard let email = Storage.loadEmail(id: fileId)?.withAttachments else { return nil }
                return (email, Extractor.extract(from: email, ai: AIExtractor.cached(fileId: fileId)))
            }.value

            if let (email, candidates) = parsed {
                for candidate in candidates {
                    guard let visit = await resolve(candidate, email: email) else { continue }
                    if !isDuplicate(visit), known.insert(visit.dedupeKey).inserted {
                        visits.append(visit)
                        added += 1
                    }
                }
            }
            state.processedEmailIds.insert(fileId)
            if i % 25 == 0 { persistVisits(); persistState() }
        }
        persistVisits()
        persistState()
        status = "Found \(added) new visits · \(places.count) places in \(countries.count) countries."
    }

    /// Second pass: Apple's on-device model reads every likely booking email it hasn't read yet,
    /// and its reading replaces what the rules found in that email. Slow (a couple of seconds per
    /// email) but saved per email, so it resumes where it stopped.
    private func readWithAI() async {
        guard UserDefaults.standard.object(forKey: "useOnDeviceAI") as? Bool ?? true, AIExtractor.isAvailable else { return }
        status = "Finding emails for the on-device model…"
        let todo: [String] = await Task.detached(priority: .utility) {
            Storage.cachedMailIds().sorted().filter { id in
                guard AIExtractor.cached(fileId: id) == nil, let e = Storage.loadEmail(id: id)?.withAttachments else { return false }
                return AIExtractor.shouldAsk(e)
            }
        }.value
        guard !todo.isEmpty else { return }

        var changed = 0
        let started = Date()
        for (i, fileId) in todo.enumerated() {
            if Task.isCancelled { break }
            progress = Double(i) / Double(todo.count)
            let left = i > 5 ? Date().timeIntervalSince(started) / Double(i) * Double(todo.count - i) : nil
            status = "On-device AI reading emails… \(i + 1)/\(todo.count)"
                + (left.map { " · about \(Self.duration($0)) left" } ?? "")
            guard let email = Storage.loadEmail(id: fileId)?.withAttachments else { continue }
            guard let result = await AIExtractor.read(email) else {
                if Task.isCancelled { break } else { continue }
            }
            AIExtractor.save(result, fileId: fileId)

            // Replace this email's rule-based visits with the model's reading.
            let before = visits.count
            visits.removeAll { $0.emailId == email.id && $0.source != .manual }
            var known = Set(visits.map(\.dedupeKey)).union(state.dismissedKeys)
            for candidate in Extractor.extract(from: email, ai: result) {
                guard let visit = await resolve(candidate, email: email) else { continue }
                if !isDuplicate(visit), known.insert(visit.dedupeKey).inserted { visits.append(visit) }
            }
            if visits.count != before { changed += 1 }
            if i % 10 == 0 { persistVisits() }
        }
        persistVisits()
        status = "On-device AI updated \(changed) emails · \(places.count) places in \(countries.count) countries."
    }

    nonisolated static func duration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(m, 1)) min"
    }

    private func resolve(_ c: Candidate, email: CachedEmail?) async -> Visit? {
        switch c.location {
        case .airport(let code):
            guard let a = Airports.lookup(code) else { return nil }
            return Visit(city: a.city, countryCode: a.countryCode, latitude: a.latitude, longitude: a.longitude,
                         startDate: c.start, endDate: c.end, source: c.source,
                         detail: c.detail.isEmpty ? "\(a.iata) · \(a.name)" : c.detail,
                         emailId: email?.id, emailSubject: email?.subject)
        case .city(let name, let country):
            guard let g = await Geocoder.shared.geocode(country.isEmpty ? name : "\(name), \(country)") else { return nil }
            return Visit(city: g.city, countryCode: g.countryCode, latitude: g.latitude, longitude: g.longitude,
                         startDate: c.start, endDate: c.end, source: c.source, detail: c.detail,
                         emailId: email?.id, emailSubject: email?.subject)
        case .address(let query):
            guard let g = await geocode(query, near: c.cityHint) else { return nil }
            return Visit(city: g.city, countryCode: g.countryCode, latitude: g.latitude, longitude: g.longitude,
                         startDate: c.start, endDate: c.end, source: c.source, detail: c.detail,
                         emailId: email?.id, emailSubject: email?.subject)
        }
    }

    /// Geocodes a hotel address, steered by the destination the email names. Booking.com
    /// often gives just "155 E. 50th Street" and the geocoder then guesses a city (Miami).
    /// When the address lands far from the named destination, look the street up again
    /// inside that destination; if that fails too and the geocoder's city isn't in the
    /// address at all, it was a guess, so fall back to the destination itself.
    private func geocode(_ query: String, near hint: String?) async -> GeoResult? {
        let raw = await Geocoder.shared.geocode(query)
        guard let hint, !hint.isEmpty, let city = await Geocoder.shared.geocode(hint) else { return raw }
        func near(_ g: GeoResult) -> Bool {
            CLLocation(latitude: g.latitude, longitude: g.longitude)
                .distance(from: CLLocation(latitude: city.latitude, longitude: city.longitude)) < 150_000
        }
        if let raw, near(raw) { return raw }
        if !query.localizedCaseInsensitiveContains(hint),
           let scoped = await Geocoder.shared.geocode("\(query), \(hint)"), near(scoped) {
            return scoped
        }
        if let raw, query.localizedCaseInsensitiveContains(raw.city) { return raw }
        return city
    }

    /// Same place + same kind of booking within two days, or the same email thread
    /// (Re:/Fwd: copies of a confirmation) → treat as one visit.
    private func isDuplicate(_ v: Visit) -> Bool {
        let subject = Self.normalizedSubject(v.emailSubject)
        return visits.contains { other in
            guard other.placeKey == v.placeKey, other.source == v.source else { return false }
            let sameThread = subject != nil && subject == Self.normalizedSubject(other.emailSubject)
            switch (v.startDate, other.startDate) {
            case let (a?, b?):
                let gap = abs(a.timeIntervalSince(b))
                return gap < 2 * 86400 || (sameThread && gap < 45 * 86400)
            default:
                return sameThread || (v.startDate == nil && other.startDate == nil)
            }
        }
    }

    nonisolated static func normalizedSubject(_ subject: String?) -> String? {
        guard var s = subject?.lowercased() else { return nil }
        while let r = s.range(of: #"^\s*(re|fwd?|aw|wg|tr|odg|posr|sv|vs)\s*:\s*"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    // MARK: editing

    func addManual(query: String, start: Date?, end: Date?) async -> Bool {
        if query.count == 3, query == query.uppercased(), Airports.lookup(query) != nil {
            if let v = await resolve(.init(location: .airport(query), source: .manual, start: start, end: end, detail: ""), email: nil) {
                visits.append(v); persistVisits(); selectedPlaceKey = v.placeKey
                return true
            }
        }
        guard let v = await resolve(.init(location: .address(query), source: .manual, start: start, end: end, detail: ""), email: nil) else {
            return false
        }
        visits.append(v)
        persistVisits()
        selectedPlaceKey = v.placeKey
        return true
    }

    func binding(for id: Visit.ID) -> Binding<Visit>? {
        guard visits.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.visits.first { $0.id == id } ?? Visit(city: "", countryCode: "", latitude: 0, longitude: 0, source: .manual) },
            set: { new in
                if let i = self.visits.firstIndex(where: { $0.id == id }) {
                    self.visits[i] = new
                    self.persistVisits()
                }
            })
    }

    func delete(_ visit: Visit) {
        state.dismissedKeys.insert(visit.dedupeKey)
        visits.removeAll { $0.id == visit.id }
        persistVisits(); persistState()
    }

    func delete(_ place: Place) {
        for v in place.visits { state.dismissedKeys.insert(v.dedupeKey) }
        visits.removeAll { $0.placeKey == place.key }
        if selectedPlaceKey == place.key { selectedPlaceKey = nil }
        persistVisits(); persistState()
    }

    /// Renames a city (e.g. "Zgornji Brnik" → "Ljubljana"); merges into an existing pin if one matches.
    func rename(_ place: Place, to newCity: String) {
        let name = newCity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let target = places.first { $0.key == Visit.placeKey(city: name, countryCode: place.countryCode) }
        for i in visits.indices where visits[i].placeKey == place.key {
            visits[i].city = target?.city ?? name
            if let target {
                visits[i].latitude = target.coordinate.latitude
                visits[i].longitude = target.coordinate.longitude
            }
        }
        selectedPlaceKey = Visit.placeKey(city: name, countryCode: place.countryCode)
        persistVisits()
    }

    func clearExtracted() {
        visits.removeAll { $0.source != .manual }
        state.processedEmailIds = []
        state.dismissedKeys = []
        selectedPlaceKey = nil
        persistVisits(); persistState()
        status = "Cleared extracted visits. Use Rescan to extract again."
    }

    func email(for visit: Visit) -> CachedEmail? {
        visit.emailId.flatMap { Storage.loadEmail(id: $0.replacingOccurrences(of: "/", with: "_")) }
    }

    private func persistVisits() { Storage.save(visits, to: Storage.visitsFile) }
    private func persistState() { Storage.save(state, to: Storage.stateFile) }
}

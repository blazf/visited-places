import SwiftUI

// MARK: - Inspector for a selected pin

struct PlaceInspector: View {
    @EnvironmentObject var model: AppModel
    let place: Place

    var body: some View {
        Form {
            Section {
                LabeledContent("Country", value: "\(Countries.flag(for: place.countryCode)) \(Countries.name(for: place.countryCode))")
                LabeledContent("Coordinates", value: String(format: "%.3f, %.3f", place.coordinate.latitude, place.coordinate.longitude))
            } header: {
                Text(place.city).font(.title2.bold()).foregroundStyle(.primary)
            }
            ForEach(place.visits) { visit in
                if let binding = model.binding(for: visit.id) {
                    VisitEditor(visit: binding)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct VisitEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var visit: Visit
    @State private var showEmail = false

    var body: some View {
        Section {
            Picker("Type", selection: $visit.source) {
                ForEach(VisitSource.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            OptionalDatePicker(title: visit.source == .hotel ? "Check-in" : "Date", date: $visit.startDate)
            OptionalDatePicker(title: visit.source == .hotel ? "Check-out" : "Until", date: $visit.endDate)
            TextField("Note", text: $visit.detail)
            if let subject = visit.emailSubject {
                LabeledContent("Email") {
                    Button(subject) { showEmail = true }.buttonStyle(.link).lineLimit(2)
                }
            }
            Button("Delete Visit", role: .destructive) { model.delete(visit) }
        } header: {
            Label(visit.detail.isEmpty ? visit.source.label : "\(visit.source.label) · \(visit.detail)",
                  systemImage: visit.source.symbol)
                .lineLimit(1)
        }
        .sheet(isPresented: $showEmail) {
            EmailPreview(email: model.email(for: visit))
        }
    }
}

private struct OptionalDatePicker: View {
    let title: String
    @Binding var date: Date?

    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(
                get: { date != nil },
                set: { date = $0 ? (date ?? Date()) : nil }))
            if date != nil {
                DatePicker("", selection: Binding(get: { date ?? Date() }, set: { date = $0 }),
                           displayedComponents: .date)
                    .labelsHidden()
            }
        }
    }
}

struct EmailPreview: View {
    @Environment(\.dismiss) private var dismiss
    let email: CachedEmail?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let email {
                Text(email.subject).font(.headline)
                Text("\(email.from) · \(email.receivedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    Text(email.textBody.count > 200 ? email.textBody : Extractor.htmlToText(email.htmlBody))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("This email is no longer in the local cache.")
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(width: 640, height: 520)
    }
}

// MARK: - Add place

struct AddPlaceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var start: Date?
    @State private var end: Date?
    @State private var working = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a place").font(.title2.bold())
            TextField("City, country — or an airport code like LJU", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            OptionalDatePicker(title: "From", date: $start)
            OptionalDatePicker(title: "To", date: $end)
            if failed {
                Text("Couldn’t find that place. Try “City, Country”.").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: add) {
                    if working { ProgressView().controlSize(.small) } else { Text("Add") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func add() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        working = true
        failed = false
        Task {
            let ok = await model.addManual(query: q, start: start, end: end)
            working = false
            if ok { dismiss() } else { failed = true }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("useOnDeviceAI") private var useOnDeviceAI = true
    @State private var token = ""
    @State private var testResult = ""
    @State private var testing = false
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Fastmail") {
                SecureField("API token", text: $token, prompt: Text(model.hasToken ? "•••••• saved in Keychain" : "fmu1-…"))
                HStack {
                    Button("Save Token") { model.saveToken(token); token = ""; testResult = "Saved." }
                        .disabled(token.isEmpty)
                    Button("Test Connection") {
                        testing = true
                        Task { testResult = await model.testConnection(); testing = false }
                    }
                    .disabled(!model.hasToken || testing)
                    if testing { ProgressView().controlSize(.small) }
                }
                if !testResult.isEmpty { Text(testResult).font(.callout).foregroundStyle(.secondary) }
                Text("Create a token at Fastmail → Settings → Privacy & Security → API tokens. Give it **Email** access, set to **read-only**. The token is stored in your macOS Keychain.")
                    .font(.callout).foregroundStyle(.secondary)
                Link("Open Fastmail API token settings", destination: URL(string: "https://app.fastmail.com/settings/security/tokens")!)
            }

            Section("Reading emails") {
                Toggle("Use Apple's on-device model", isOn: $useOnDeviceAI)
                    .disabled(!AIExtractor.isAvailable)
                Text(AIExtractor.isAvailable
                     ? "After the quick rule-based scan, the on-device model reads each likely booking email (a few seconds each, once) and replaces what the rules found. Nothing leaves your Mac."
                     : "Turn on Apple Intelligence in System Settings to let the on-device model read your booking emails.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Local data") {
                LabeledContent("Cached emails", value: "\(model.cachedEmailCount)")
                LabeledContent("Last sync", value: model.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Storage.root]) }
                    Button("Rescan All Emails") { model.rescanAll() }.disabled(model.isBusy)
                    Button("Clear Found Places…", role: .destructive) { confirmClear = true }.disabled(model.isBusy)
                }
                Text("Emails are cached in ~/Library/Application Support/VisitedPlaces. Places you add by hand are kept when you clear found places.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .confirmationDialog("Remove all places found in emails?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { model.clearExtracted() }
        } message: {
            Text("Places you added by hand stay. Rescan to find the others again; places you deleted may come back.")
        }
    }
}

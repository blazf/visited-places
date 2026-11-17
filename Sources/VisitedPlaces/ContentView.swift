import SwiftUI
import MapKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var camera: MapCameraPosition = .automatic
    @State private var showAdd = false
    @State private var search = ""
    @State private var satellite = false
    @AppStorage("sidebarMode") private var sidebarMode: SidebarMode = .places

    var body: some View {
        NavigationSplitView {
            Group {
                if sidebarMode == .timeline {
                    TimelineList(search: $search)
                } else {
                    Sidebar(search: $search)
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("View", selection: $sidebarMode) {
                    Text("Places").tag(SidebarMode.places)
                    Text("Timeline").tag(SidebarMode.timeline)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        } detail: {
            mapView
                .overlay(alignment: .bottom) { statusBar }
                .inspector(isPresented: Binding(
                    get: { model.selectedPlaceKey != nil },
                    set: { if !$0 { model.selectedPlaceKey = nil } })) {
                    if let place = model.selectedPlace {
                        PlaceInspector(place: place)
                            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                    }
                }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { showAdd = true } label: { Label("Add Place", systemImage: "plus") }
                    .help("Add a place by hand")
                Toggle(isOn: $satellite) { Label("Satellite", systemImage: "globe.europe.africa.fill") }
                    .help("Satellite map")
                Button { withAnimation { camera = .automatic } } label: {
                    Label("Show All", systemImage: "arrow.up.left.and.arrow.down.right")
                }.help("Zoom to all pins")
                if model.isBusy {
                    Button { model.cancelWork() } label: { Label("Stop", systemImage: "stop.circle") }
                } else {
                    Button { model.syncAndScan() } label: {
                        Label("Sync Mail", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Download booking emails from Fastmail and find trips (⌘R)")
                }
            }
        }
        .sheet(isPresented: $showAdd) { AddPlaceSheet() }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if !model.hasToken { SettingsLink { Text("Open Settings") } }
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
        .onChange(of: model.selectedPlaceKey) { _, key in
            guard let place = model.places.first(where: { $0.key == key }) else { return }
            withAnimation(.easeInOut(duration: 0.8)) {
                camera = .region(MKCoordinateRegion(center: place.coordinate,
                                                    span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)))
            }
        }
    }

    private var mapView: some View {
        Map(position: $camera, selection: $model.selectedPlaceKey) {
            ForEach(model.places) { place in
                Marker(place.city, systemImage: symbol(for: place), coordinate: place.coordinate)
                    .tint(color(for: place))
                    .tag(place.key)
            }
        }
        .mapStyle(satellite ? .hybrid(elevation: .realistic) : .standard(elevation: .flat, emphasis: .muted))
        .mapControls {
            MapZoomStepper()
            MapCompass()
            MapScaleView()
        }
        .overlay {
            if model.visits.isEmpty && !model.isBusy {
                EmptyState(showAdd: $showAdd)
            }
        }
    }

    private func symbol(for place: Place) -> String {
        let sources = Set(place.visits.map(\.source))
        if sources.contains(.hotel) { return VisitSource.hotel.symbol }
        return place.visits.first?.source.symbol ?? "mappin"
    }

    private func color(for place: Place) -> Color {
        switch place.visits.count {
        case 1: .orange
        case 2...3: .red
        default: .purple
        }
    }

    @ViewBuilder private var statusBar: some View {
        if model.isBusy || !model.status.isEmpty {
            HStack(spacing: 10) {
                if model.isBusy {
                    if let p = model.progress { ProgressView(value: p).frame(width: 120) }
                    else { ProgressView().controlSize(.small) }
                }
                Text(model.status).font(.callout).lineLimit(1)
                if !model.isBusy {
                    Button { model.status = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 16)
        }
    }
}

private struct EmptyState: View {
    @EnvironmentObject var model: AppModel
    @Binding var showAdd: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe.europe.africa").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No places yet").font(.title2.bold())
            Text(model.hasToken
                 ? "Sync your Fastmail mailbox to find flight and hotel bookings."
                 : "Add a Fastmail API token in Settings, then sync to find flight and hotel bookings.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 320)
            HStack {
                if model.hasToken {
                    Button("Sync Mail") { model.syncAndScan() }.buttonStyle(.borderedProminent)
                } else {
                    SettingsLink { Text("Open Settings") }.buttonStyle(.borderedProminent)
                }
                Button("Add Place by Hand") { showAdd = true }
            }
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var search: String
    @State private var renaming: Place?
    @State private var newName = ""

    var body: some View {
        let groups = filteredCountries
        List(selection: $model.selectedPlaceKey) {
            Section {
                HStack(spacing: 0) {
                    Stat(value: model.countries.count, label: "Countries")
                    Stat(value: model.places.count, label: "Cities")
                    Stat(value: model.visits.count, label: "Visits")
                }
                .padding(.vertical, 4)
                .selectionDisabled()
            }
            ForEach(groups, id: \.code) { group in
                Section {
                    ForEach(group.places) { place in
                        PlaceRow(place: place)
                            .tag(place.key)
                            .contextMenu {
                                Button("Rename / Merge City…") { newName = place.city; renaming = place }
                                Button("Delete", role: .destructive) { model.delete(place) }
                            }
                    }
                } header: {
                    Text("\(Countries.flag(for: group.code))  \(Countries.name(for: group.code))")
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Filter cities or countries")
        .alert("Rename city", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("City", text: $newName)
            Button("Rename") { if let p = renaming { model.rename(p, to: newName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use an existing city name to merge pins, e.g. an airport town into the city it serves.")
        }
    }

    private var filteredCountries: [(code: String, places: [Place])] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.countries }
        return model.countries.compactMap { group in
            if Countries.name(for: group.code).localizedCaseInsensitiveContains(q) { return group }
            let places = group.places.filter { $0.city.localizedCaseInsensitiveContains(q) }
            return places.isEmpty ? nil : (code: group.code, places: places)
        }
    }
}

private struct Stat: View {
    let value: Int
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PlaceRow: View {
    let place: Place
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.city).fontWeight(.medium)
                Text(dateSummary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 3) {
                ForEach(Array(Set(place.visits.map(\.source))).sorted { $0.rawValue < $1.rawValue }, id: \.self) {
                    Image(systemName: $0.symbol)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if place.visits.count > 1 {
                Text("\(place.visits.count)").font(.caption.bold()).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private var dateSummary: String {
        guard let first = place.firstDate else { return "No dates" }
        let f = Date.FormatStyle().month(.abbreviated).year()
        guard let last = place.lastDate, last.formatted(f) != first.formatted(f) else { return first.formatted(f) }
        return "\(first.formatted(f)) – \(last.formatted(f))"
    }
}

import SwiftUI

enum SidebarMode: String { case places, timeline }

/// Every visit in date order (newest first), grouped by year: made for reviewing
/// what the extractor found, with the source email one click away.
struct TimelineList: View {
    @EnvironmentObject var model: AppModel
    @Binding var search: String
    @State private var selection: Visit.ID?
    @State private var previewEmail: CachedEmail?
    @State private var sourceFilter: VisitSource?

    var body: some View {
        let groups = yearGroups
        List(selection: $selection) {
            ForEach(groups, id: \.year) { group in
                Section {
                    ForEach(group.visits) { visit in
                        TimelineRow(visit: visit)
                            .tag(visit.id)
                            .contextMenu {
                                if visit.emailId != nil {
                                    Button("Show Email") { previewEmail = model.email(for: visit) }
                                }
                                Button("Delete Visit", role: .destructive) { model.delete(visit) }
                            }
                    }
                } header: {
                    HStack {
                        Text(group.year)
                        Spacer()
                        Text(summary(group.visits)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Filter city, country or email")
        .safeAreaInset(edge: .bottom) {
            Picker("Type", selection: $sourceFilter) {
                Text("All types").tag(VisitSource?.none)
                ForEach(VisitSource.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag(VisitSource?.some($0)) }
            }
            .labelsHidden()
            .padding(8)
        }
        .onChange(of: selection) { _, id in
            if let v = model.visits.first(where: { $0.id == id }) { model.selectedPlaceKey = v.placeKey }
        }
        .onKeyPress(.space) {
            guard let v = model.visits.first(where: { $0.id == selection }), v.emailId != nil else { return .ignored }
            previewEmail = model.email(for: v)
            return .handled
        }
        .sheet(item: $previewEmail) { EmailPreview(email: $0) }
    }

    private var yearGroups: [(year: String, visits: [Visit])] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let filtered = model.visits.filter { v in
            (sourceFilter == nil || v.source == sourceFilter) &&
            (q.isEmpty || v.city.localizedCaseInsensitiveContains(q)
                || v.countryName.localizedCaseInsensitiveContains(q)
                || (v.emailSubject ?? "").localizedCaseInsensitiveContains(q)
                || v.detail.localizedCaseInsensitiveContains(q))
        }
        let byYear = Dictionary(grouping: filtered) { v in
            v.startDate.map { String(Calendar.current.component(.year, from: $0)) } ?? "No date"
        }
        return byYear
            .map { (year: $0.key, visits: $0.value.sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }) }
            .sorted { a, b in
                if a.year == "No date" { return false }
                if b.year == "No date" { return true }
                return a.year > b.year
            }
    }

    private func summary(_ visits: [Visit]) -> String {
        let countries = Set(visits.map(\.countryCode)).count
        let cities = Set(visits.map(\.placeKey)).count
        return "\(cities) cities · \(countries) countries"
    }
}

private struct TimelineRow: View {
    let visit: Visit

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(dateText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Image(systemName: visit.source.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Countries.flag(for: visit.countryCode)) \(visit.city)").fontWeight(.medium)
                if !visit.detail.isEmpty {
                    Text(visit.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let subject = visit.emailSubject {
                    Text(subject).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .help(visit.emailSubject.map { "From email: \($0)\nRight-click → Show Email, or select and press Space" } ?? "")
    }

    private var dateText: String {
        guard let start = visit.startDate else { return "—" }
        let day = start.formatted(.dateTime.day().month(.abbreviated))
        guard let end = visit.endDate, !Calendar.current.isDate(end, inSameDayAs: start) else { return day }
        return "\(day)–\(end.formatted(.dateTime.day()))"
    }
}

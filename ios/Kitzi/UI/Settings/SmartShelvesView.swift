import SwiftUI

/// Settings › Home Shelves › Smart Shelves: saved filters shown as Home rows.
struct SmartShelvesView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library

    var body: some View {
        @Bindable var s = settings
        List {
            Section {
                ForEach($s.smartShelves) { $shelf in
                    NavigationLink { SmartShelfEditor(shelf: $shelf) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shelf.name)
                            Text("\(library.books(shelf).count) books · \(shelf.summary)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .onDelete { s.smartShelves.remove(atOffsets: $0) }
                .onMove { s.smartShelves.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("Each one is a row on Home, after the other shelves. Swipe to remove one; Edit to reorder.")
            }
            Section("Add") {
                ForEach(SmartShelf.presets.filter { p in !settings.smartShelves.contains { $0.name == p.name } }, id: \.name) { p in
                    Button { add(p) } label: {
                        Label(p.name, systemImage: "plus.circle")
                    }
                }
                Button { add(SmartShelf(name: "My Shelf")) } label: { Label("Custom…", systemImage: "slider.horizontal.3") }
            }
        }
        .navigationTitle("Smart Shelves")
        .toolbar { if !settings.smartShelves.isEmpty { EditButton() } }
        .animation(.kitzi, value: settings.smartShelves)
    }

    private func add(_ p: SmartShelf) {
        var shelf = p
        shelf.id = UUID().uuidString
        settings.smartShelves.append(shelf)
        Haptics.tap()
    }
}

/// One smart shelf's rules, with how many books they find, live.
struct SmartShelfEditor: View {
    @Binding var shelf: SmartShelf
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let genres = Array(Set(library.books.flatMap(\.genres))).sorted()
        Form {
            Section {
                TextField("Name", text: $shelf.name)
            } footer: {
                Text("\(library.books(shelf).count) books right now")
            }
            Section("Books") {
                Picker("Status", selection: $shelf.status) {
                    Text("Any").tag("any")
                    Text("Not Started").tag("notStarted")
                    Text("In Progress").tag("inProgress")
                    Text("Finished").tag("finished")
                }
                optional("Shorter Than", value: $shelf.maxHours, default: 6) { h in
                    Stepper("\(Int(h.wrappedValue)) hours", value: h, in: 1...60)
                }
                optional("Audible Rating", value: $shelf.minRating, default: 4.5) { r in
                    Stepper(String(format: "%.1f★ or more", r.wrappedValue), value: r, in: 3...5, step: 0.1)
                }
                optional("Added Recently", value: Binding(get: { shelf.addedDays.map(Double.init) }, set: { shelf.addedDays = $0.map { Int($0) } }), default: 30) { d in
                    Stepper("In the last \(Int(d.wrappedValue)) days", value: d, in: 1...365, step: 1)
                }
                if !genres.isEmpty {
                    Picker("Genre", selection: $shelf.genre) {
                        Text("Any").tag(String?.none)
                        ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
                Toggle("Only Series I've Started", isOn: $shelf.mySeries)
                Toggle("Only Downloaded", isOn: $shelf.downloaded)
            }
            Section {
                Picker("Order", selection: $shelf.sort) {
                    Text("Newest First").tag("added")
                    Text("Shortest First").tag("shortest")
                    Text("Best Rated First").tag("rating")
                    Text("By Title").tag("title")
                }
            } footer: {
                Text("Ratings come from Audible, for books it has been asked about (All Books › Highest Rated fills in the rest).")
            }
        }
        .navigationTitle(shelf.name.isEmpty ? "Smart Shelf" : shelf.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A rule that's off (nil) or on with a value.
    @ViewBuilder private func optional<C: View>(_ title: String, value: Binding<Double?>, default def: Double,
                                                @ViewBuilder content: (Binding<Double>) -> C) -> some View {
        Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? def : nil }))
        if value.wrappedValue != nil {
            content(Binding(get: { value.wrappedValue ?? def }, set: { value.wrappedValue = $0 }))
        }
    }
}

import SwiftUI

/// Up next: drag to reorder, swipe left to remove, right to move to the top, tap to play now.
struct QueueView: View {
    @Environment(PlayQueue.self) private var queue
    @Environment(Player.self) private var player
    @State private var confirmClear = false
    @State private var removing: Book?

    var body: some View {
        Group {
            if queue.books.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "list.bullet",
                                       description: Text("Use Play next or Add to queue on a book to line it up after the current one."))
            } else {
                List {
                    ForEach(queue.books) { b in
                        Button {
                            Task {
                                queue.remove(b.id)
                                await player.play(b)
                            }
                        } label: {
                            BookRow(book: b)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { removing = b } label: { Label("Remove", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            if queue.books.first?.id != b.id {
                                Button { withAnimation { queue.addNext(b.id) } } label: {
                                    Label("Up Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                                .tint(.accentColor)
                            }
                        }
                    }
                    // The list shows only books in this library: move by their ids, not by
                    // raw positions in the queue (which may hold others).
                    .onMove { queue.move(visible: queue.books.map(\.id), from: $0, to: $1) }
                    .onDelete { idx in
                        if let i = idx.first { removing = queue.books[i] }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Queue")
        .toolbar {
            if !queue.books.isEmpty {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Remove from the queue?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { b in
            Button("Remove", role: .destructive) { withAnimation { queue.remove(b.id) } }
        } message: { b in
            Text(b.title)
        }
        .confirmationDialog("Clear the queue?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear queue", role: .destructive) { queue.clear() }
        }
    }
}

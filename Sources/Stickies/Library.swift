import SwiftUI

/// The library: every note — on the desktop or stashed — searchable.
/// Click a row to bring the note to the desktop; trash deletes for real.
struct LibraryView: View {
    @EnvironmentObject var store: NotesStore
    @State private var query = ""
    let isOpen: (UUID) -> Bool
    let openNote: (UUID) -> Void
    let deleteNote: (UUID) -> Void

    private var filtered: [Note] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.notes }
        return store.notes.filter { note in
            note.lines.contains { $0.plainText.lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search notes", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            List {
                let desktop = filtered.filter { !$0.stashed }
                let stashed = filtered.filter { $0.stashed }
                if !desktop.isEmpty {
                    Section("On Desktop") {
                        ForEach(desktop) { row(for: $0) }
                    }
                }
                if !stashed.isEmpty {
                    Section("Stashed") {
                        ForEach(stashed) { row(for: $0) }
                    }
                }
                if filtered.isEmpty {
                    Text(query.isEmpty ? "No notes yet" : "No matches")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 280, minHeight: 300)
    }

    private func row(for note: Note) -> some View {
        LibraryRow(note: note, isOpen: isOpen(note.id),
                   open: { openNote(note.id) },
                   delete: { deleteNote(note.id) })
    }
}

private struct LibraryRow: View {
    let note: Note
    let isOpen: Bool
    let open: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    @State private var confirmDelete = false

    private var title: String {
        let t = note.displayTitle
        return t.isEmpty ? "Untitled" : t
    }

    /// The second non-empty line, as a preview under the title.
    private var snippet: String {
        note.lines.map(\.plainText)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .dropFirst().first ?? ""
    }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Color(hex: note.tintHex))
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(1)
                if !snippet.isEmpty {
                    Text(snippet)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if hovering {
                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete note")
            }

            if isOpen {
                Image(systemName: "macwindow")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("On the desktop")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .onHover { hovering = $0 }
        .confirmationDialog("Delete “\(title)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text("This permanently deletes the note.")
        }
    }
}

import AppKit
import BBModel
import BBStore
import SwiftUI

/// The Library window (A §6.1, PD §8.1): a grid of books with cover thumbnails and modified dates.
/// Open, Rename…, Duplicate, Move to Trash and Show in Finder from the context menu and toolbar.
public struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var selection: BookID?
    @State private var actions = BookActionRequests()
    /// The grid's width, to work out how many columns the arrow keys step over.
    @State private var gridWidth: CGFloat = 0

    private static let cellMinimum: CGFloat = 160
    private static let cellSpacing: CGFloat = 22
    private static let gridPadding: CGFloat = 24

    public init() {}

    private var selectedEntry: LibraryEntry? { selection.flatMap { app.entry(for: $0) } }

    public var body: some View {
        @Bindable var app = app
        Group {
            if app.libraryEntries.isEmpty {
                CrayonEmptyState("No Books Yet", systemImage: "books.vertical", color: Crayon.tomato,
                                 message: "Your books will appear here.") {
                    Button("New Book…") { app.newBookRequest = .blank }
                        .buttonStyle(.crayon)
                    HStack(spacing: 10) {
                        Button("New Book from Story…") { app.newBookRequest = .fromStory }
                            .buttonStyle(.crayon(Crayon.sky))
                        Button("Open Sample Book") { openSample() }
                            .buttonStyle(.crayon(Crayon.grass))
                    }
                }
            } else {
                grid
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .restored = app.queueSnapshot.pause { QueueResumeBanner(pause: app.queueSnapshot.pause) }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { app.newBookRequest = .blank } label: { Label("New Book…", systemImage: "plus") }
                    .help("Create a new book")
                Button { app.newBookRequest = .fromStory } label: {
                    Label("New Book from Story…", systemImage: "text.book.closed")
                }
                .help("Create a new book and import its story text")
                Button { openSample() } label: { Label("Open Sample Book", systemImage: "book.pages") }
                    .help("Open a ready-made example book (no API key needed)")
                Button { if let selection { openWindow(value: selection) } } label: {
                    Label("Open", systemImage: "arrow.up.forward.square")
                }
                .help("Open the selected book")
                .disabled(selection == nil)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([app.libraryRoot])
                } label: {
                    Label("Show Library in Finder", systemImage: "folder")
                }
                .help("Show the library folder in the Finder")
            }
        }
        .sheet(item: $app.newBookRequest) { kind in
            NewBookWizard(fromStory: kind == .fromStory) { id in openWindow(value: id) }
        }
        .bookActions($actions)
        .alert("Couldn't open the sample book", isPresented: $app.sampleBookError.isPresent()) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.sampleBookError ?? "")
        }
        .task {
            await app.start()
            await app.reopenBooks { openWindow(value: $0) }
        }
        .onChange(of: app.libraryEntries) { _, entries in
            if let id = selection, !entries.contains(where: { $0.id == id }) { selection = nil }
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LibraryHeader(count: app.libraryEntries.count)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cellMinimum, maximum: 220), spacing: Self.cellSpacing,
                                                 alignment: .top)], spacing: 26) {
                    // Keyed by URL: two packages can carry the same book ID (a Finder copy).
                    ForEach(app.libraryEntries, id: \.url) { entry in
                        LibraryCell(entry: entry, isSelected: selection == entry.id)
                            .onTapGesture(count: 2) { openWindow(value: entry.id) }
                            .simultaneousGesture(TapGesture().onEnded { selection = entry.id })
                            .contextMenu {
                                menu(for: entry)
                                    // Right-click selects the cell it opened the menu on.
                                    .onAppear { selection = entry.id }
                            }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction(named: "Open") { openWindow(value: entry.id) }
                    }
                }
            }
            .padding(24)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = nil }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            openWindow(value: selection)
            return .handled
        }
        .onDeleteCommand { actions.trashing = selectedEntry }
        .onMoveCommand { move($0) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
    }

    private var columnCount: Int {
        let available = gridWidth - Self.gridPadding * 2
        return max(1, Int(((available + Self.cellSpacing) / (Self.cellMinimum + Self.cellSpacing)).rounded(.down)))
    }

    /// Arrow keys move the selection through the grid (left and right by one, up and down by a row).
    private func move(_ direction: MoveCommandDirection) {
        let entries = app.libraryEntries
        guard !entries.isEmpty else { return }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -columnCount
        case .down: step = columnCount
        @unknown default: return
        }
        guard let current = entries.firstIndex(where: { $0.id == selection }) else {
            selection = entries[step < 0 ? entries.count - 1 : 0].id
            return
        }
        let target = current + step
        if entries.indices.contains(target) { selection = entries[target].id }
    }

    @ViewBuilder
    private func menu(for entry: LibraryEntry) -> some View {
        Button("Open") { openWindow(value: entry.id) }
        Divider()
        Button("Rename…") { actions.renaming = entry }
        Button("Duplicate") { duplicate(entry) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        Divider()
        Button("Move to Trash…", role: .destructive) { actions.trashing = entry }
    }

    private func openSample() {
        Task { await app.openSampleBook { openWindow(value: $0) } }
    }

    private func duplicate(_ entry: LibraryEntry) {
        Task {
            do {
                selection = try await app.duplicate(entry).id
            } catch {
                actions.error = .init(title: "Couldn't duplicate the book",
                                      message: "“\(entry.title)” wasn't duplicated. \(StoreErrorText.message(for: error))")
            }
        }
    }
}

/// The friendly heading above the grid: a big rounded title over a short crayon stripe.
private struct LibraryHeader: View {
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Your Books")
                .font(Crayon.font(.largeTitle, weight: .heavy))
                .foregroundStyle(Crayon.ink)
                .accessibilityAddTraits(.isHeader)
            CrayonSticker(count == 1 ? "1 book" : "\(count) books", color: Crayon.grape)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                ForEach(Array(Crayon.rainbow.enumerated()), id: \.offset) { _, color in
                    Capsule().fill(color).frame(width: 22, height: 5)
                }
            }
            .offset(y: 10)
            .accessibilityHidden(true)
        }
        .padding(.bottom, 10)
    }
}

/// One book in the grid: its thumbnail (or a placeholder), title and modified date.
struct LibraryCell: View {
    let entry: LibraryEntry
    let isSelected: Bool
    @Environment(AppModel.self) private var app
    @State private var image: NSImage?

    private struct ThumbnailKey: Hashable {
        var url: URL?
        var modifiedAt: Date
    }

    /// The same book always gets the same colour and the same lean.
    private var key: String { entry.id.rawValue.uuidString }
    private var tilt: Double { entry.id.rawValue.uuid.0.isMultiple(of: 2) ? -1.5 : 1.5 }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous))
                        .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 3)
                } else {
                    PlaceholderCover(color: Crayon.color(forKey: key))
                }
            }
            .frame(height: 180)
            VStack(spacing: 3) {
                Text(entry.title)
                    .font(Crayon.font(.callout, weight: .bold))
                    .foregroundStyle(Crayon.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(entry.modifiedAt, format: .dateTime.day().month().year().hour().minute())
                    .font(Crayon.font(.caption, weight: .medium))
                    .foregroundStyle(Crayon.inkSoft)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .crayonCard(selected: isSelected)
        .crayonHover(tilt: tilt)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: ThumbnailKey(url: entry.thumbnailURL, modifiedAt: entry.modifiedAt)) {
            guard let source = entry.thumbnailURL else {
                image = nil
                return
            }
            let rendition = await app.thumbnails.rendition(of: source, bookID: entry.id, maxPixelSize: 400)
            // Read the bytes (not `NSImage(contentsOf:)`) so a rewritten file isn't served from a cache,
            // off the main actor (#3g).
            let data = await Task.detached { rendition.flatMap { try? Data(contentsOf: $0) } }.value
            image = data.flatMap { NSImage(data: $0) }
        }
    }
}

/// A book with no thumbnail yet: a coloured cover with a darker spine stripe, a book symbol and
/// a little title plate, like a picture book on a toy shelf.
private struct PlaceholderCover: View {
    let color: Color

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4,
                                           bottomTrailingRadius: Crayon.cornerRadius,
                                           topTrailingRadius: Crayon.cornerRadius, style: .continuous)
        ZStack(alignment: .leading) {
            shape.fill(color)
            // The spine, plus a lighter crease beside it.
            HStack(spacing: 0) {
                Rectangle().fill(.black.opacity(0.18)).frame(width: 14)
                Rectangle().fill(.white.opacity(0.25)).frame(width: 2)
                Spacer(minLength: 0)
            }
            .clipShape(shape)
            VStack(spacing: 8) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 2)
                // A cover "title plate".
                Capsule().fill(.white.opacity(0.85)).frame(width: 56, height: 8)
                Capsule().fill(.white.opacity(0.55)).frame(width: 36, height: 6)
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 3)
        .accessibilityHidden(true)
    }
}

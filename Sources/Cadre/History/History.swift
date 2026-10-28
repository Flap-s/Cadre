import AppKit
import SwiftUI

struct HistoryEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case image, video }
    var id = UUID()
    let fileName: String
    let kind: Kind
    let date: Date
}

/// Every capture is kept in ~/Library/Application Support/Cadre/History for the retention period.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []
    let directory: URL
    private let indexURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Cadre/History", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
        }
    }

    func url(for entry: HistoryEntry) -> URL { directory.appendingPathComponent(entry.fileName) }

    func add(url: URL, kind: HistoryEntry.Kind, date: Date) {
        entries.insert(HistoryEntry(fileName: url.lastPathComponent, kind: kind, date: date), at: 0)
        persist()
    }

    func remove(_ entry: HistoryEntry) {
        try? FileManager.default.removeItem(at: url(for: entry))
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() {
        entries.forEach { try? FileManager.default.removeItem(at: url(for: $0)) }
        entries.removeAll()
        persist()
    }

    func prune() {
        let days = Prefs.historyRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        entries.filter { $0.date < cutoff }.forEach { try? FileManager.default.removeItem(at: url(for: $0)) }
        entries.removeAll { $0.date < cutoff }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: indexURL) }
    }
}

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: HistoryWindowController?

    static func show() {
        if let shared {
            shared.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let controller = HistoryWindowController()
        shared = controller
        AppPresence.windowOpened()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Capture History"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: HistoryView(store: .shared))
        window.setContentSize(CGSize(width: 860, height: 600))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
        AppPresence.windowClosed()
    }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All", screenshots = "Screenshots", recordings = "Recordings"
    var id: String { rawValue }
}

private struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @State private var filter: HistoryFilter = .all
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        switch filter {
        case .all: return store.entries
        case .screenshots: return store.entries.filter { $0.kind == .image }
        case .recordings: return store.entries.filter { $0.kind == .video }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                Spacer()
                Button("Open Folder") { NSWorkspace.shared.open(store.directory) }
                Button("Clear History…", role: .destructive) { confirmClear = true }
            }
            .padding(12)
            Divider()
            if filtered.isEmpty {
                Spacer()
                Text("No captures yet").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                        ForEach(filtered) { entry in
                            HistoryCell(entry: entry, url: store.url(for: entry))
                        }
                    }
                    .padding(14)
                }
            }
        }
        .confirmationDialog("Delete all captures from history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { store.clear() }
        }
    }
}

private struct HistoryCell: View {
    let entry: HistoryEntry
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6)).padding(4)
                }
                if entry.kind == .video {
                    Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(.white).shadow(radius: 3)
                }
            }
            .frame(height: 130)
            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { open() }
            if entry.kind == .image {
                Button("Annotate") { open() }
                Button("Pin") {
                    if let item = CaptureItem(imageAt: url), let image = item.image {
                        PinManager.shared.pin(image: image, scale: item.scale)
                    }
                }
            }
            Button("Copy") {
                if entry.kind == .image, let item = CaptureItem(imageAt: url) { item.copyToPasteboard() } else { Clipboard.copy(fileURL: url) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Delete", role: .destructive) { HistoryStore.shared.remove(entry) }
        }
        .task {
            if entry.kind == .image {
                thumbnail = CGImage.thumbnail(of: url, maxPixelSize: 400).map { NSImage(cgImage: $0, size: .zero) }
            } else {
                thumbnail = CaptureItem.videoThumbnail(url)
            }
        }
    }

    private func open() {
        if entry.kind == .image {
            if let item = CaptureItem(imageAt: url) { AnnotationEditorController.open(item) }
        } else {
            VideoEditorWindowController.open(CaptureItem(videoAt: url, temporary: false))
        }
    }
}

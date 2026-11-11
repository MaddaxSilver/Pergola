import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A file kept in the tray. Stored as a bookmark, so it still resolves if the file is moved or renamed.
struct TrayItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var bookmark: Data
    var name: String

    var url: URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

/// The files tray: drop files on the notch to park them, drag them back out wherever you need them.
/// Files are never copied or moved; the tray only remembers where they are.
@Observable @MainActor
final class FileTray {
    private(set) var items: [TrayItem] = []

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pergola", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tray.json")
    }

    init() { load() }

    func add(_ urls: [URL]) {
        let existing = Set(items.compactMap { $0.url?.standardizedFileURL })
        for url in urls where url.isFileURL && !existing.contains(url.standardizedFileURL) {
            guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
            items.append(TrayItem(bookmark: data, name: url.lastPathComponent))
        }
        save()
    }

    func remove(_ item: TrayItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([TrayItem].self, from: data) else { return }
        // Drop entries whose file no longer exists.
        items = decoded.filter { $0.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: storeURL, options: .atomic) }
    }
}

struct TrayView: View {
    @Environment(AppModel.self) private var model

    private var tray: FileTray { model.tray }
    private var targeted: Bool { model.ui.dropTargeted }

    var body: some View {
        // Other apps' tasks (Claude and friends) sit above the tray on the same page.
        let tasks = model.ui.hasActivities
        VStack(spacing: 8) {
            if tasks {
                ActivityStack(limit: NotchUI.maxTaskRows)
                    .padding(.horizontal, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            trayBody(compact: tasks)
        }
    }

    private func trayBody(compact: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.white.opacity(targeted ? 0.6 : (tray.items.isEmpty ? 0.22 : 0)))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(targeted ? 0.08 : 0)))

            if tray.items.isEmpty {
                // Beside tasks the drop zone is a slim strip: icon and words on one line.
                let layout = compact ? AnyLayout(HStackLayout(spacing: 7)) : AnyLayout(VStackLayout(spacing: 6))
                layout {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: compact ? 13 : 22))
                    Text("Drop files here")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(.white.opacity(targeted ? 0.9 : 0.5))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    // Beside tasks there's no room for the header; Clear moves to the end of the row.
                    if !compact { HStack {
                        Text("\(tray.items.count) \(tray.items.count == 1 ? "file" : "files")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Button("Clear") { withAnimation { tray.clear() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    } }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tray.items) { item in
                                TrayTile(item: item)
                                    .transition(.scale.combined(with: .opacity))
                            }
                            if compact {
                                Button { withAnimation { tray.clear() } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.white.opacity(0.45))
                                        .frame(width: 28, height: 40)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Clear the tray")
                                .frame(maxHeight: .infinity, alignment: .top)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: targeted)
    }
}

struct TrayTile: View {
    @Environment(AppModel.self) private var model
    var item: TrayItem
    @State private var hovering = false

    var body: some View {
        let url = item.url
        VStack(spacing: 3) {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                .resizable()
                .frame(width: 40, height: 40)
            Text(item.name)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: 62, height: 24, alignment: .top)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hovering ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { withAnimation { model.tray.remove(item) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .gray)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
            }
        }
        .onHover { hovering = $0 }
        .onDrag {
            guard let url else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .onTapGesture(count: 2) { if let url { NSWorkspace.shared.open(url) } }
        .contextMenu {
            Button("Open") { if let url { NSWorkspace.shared.open(url) } }
            Button("Show in Finder") { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            Divider()
            Button("Remove from Tray") { model.tray.remove(item) }
        }
        .help(url?.path ?? item.name)
    }
}

import SwiftUI
import AppKit

struct SearchSidebar: View {
    @Binding var query: String
    var onSelect: (Database.SearchHit) -> Void

    @State private var results: [Database.SearchHit] = []
    @State private var searching = false
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search what you saw…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch(immediate: true) }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            Divider()

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                emptyState
            } else if searching && results.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                noMatchesState
            } else {
                List(results, selection: .constant(nil as String?)) { hit in
                    SearchResultRow(hit: hit)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(hit) }
                        .padding(.vertical, 2)
                }
                .listStyle(.sidebar)
            }
        }
        .onChange(of: query) {
            runSearch(immediate: false)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Search every captured frame and meeting transcript.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Examples: an email subject you saw on screen, a phrase someone said in a meeting, a person's name.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No frames match.")
                .foregroundStyle(.secondary)
            Text("OCR runs in the background — very recent frames may not be indexed yet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func runSearch(immediate: Bool) {
        debounceTask?.cancel()
        let q = query
        debounceTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 220_000_000)
                if Task.isCancelled { return }
            }
            await MainActor.run { searching = true }
            let hits = await Task.detached(priority: .userInitiated) {
                Database.shared.searchAll(query: q, limit: 200)
            }.value
            if Task.isCancelled { return }
            await MainActor.run {
                results = hits
                searching = false
            }
        }
    }
}

struct SearchResultRow: View {
    let hit: Database.SearchHit

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leadingVisual
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: hit.kind == .frame ? "photo.fill" : "waveform")
                        .font(.caption2)
                        .foregroundStyle(hit.kind == .frame ? Color.secondary : Color.accentColor)
                    Text(formatted(hit.capturedAt))
                        .font(.caption.monospacedDigit().weight(.medium))
                }
                if let bundle = hit.appBundleID, let name = appName(bundle) {
                    Text(hit.kind == .transcript ? "Meeting · \(name)" : name)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(hit.snippet)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private var leadingVisual: some View {
        switch hit.kind {
        case .frame:
            if let path = hit.imagePath {
                ThumbnailView(relativePath: path)
            } else {
                Color.gray.opacity(0.2)
            }
        case .transcript:
            ZStack {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.6), Color.accentColor.opacity(0.25)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }

    private func formatted(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }

    private func appName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}

struct ThumbnailView: View {
    let relativePath: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: relativePath) {
            let url = Database.shared.framesDirectory.appendingPathComponent(relativePath)
            let img = await Task.detached(priority: .background) { NSImage(contentsOf: url) }.value
            await MainActor.run { self.image = img }
        }
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
//
// The start window: what to boot (an images folder, or a kernel and an
// optional NAND image), how, and the Chumbys started before.

import AppKit
import ChumbyKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Recents: ObservableObject {
    static let shared = Recents()
    private let key = "RecentLaunches"
    @Published private(set) var items: [LaunchOptions] = []

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([LaunchOptions].self, from: d) {
            items = v
        }
    }

    func add(_ o: LaunchOptions) {
        var o = o
        o.scale = nil
        items.removeAll { $0 == o }
        items.insert(o, at: 0)
        items = Array(items.prefix(10))
        save()
    }

    func remove(_ o: LaunchOptions) {
        items.removeAll { $0 == o }
        save()
    }

    func clear() { items = []; save() }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// What the start window is setting up.
@MainActor
final class LaunchDraft: ObservableObject {
    @Published var fast = false
    @Published var write = false
    @Published var state: String?
    @Published var extra = ""
    @Published var dropping = false
    @Published var qemu: String? = UserDefaults.standard.string(forKey: QemuLocator.defaultsKey)

    func options(images: String? = nil, kernel: String? = nil, nand: String? = nil) -> LaunchOptions {
        var o = LaunchOptions()
        o.images = images
        o.kernel = kernel
        o.nand = nand
        o.fast = fast
        o.write = write
        o.state = state
        o.extra = Self.split(extra)
        return o
    }

    /// Words, with "quoted strings" kept whole.
    static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil, any = false
        for c in s {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c; any = true
            } else if c == " " || c == "\t" || c == "\n" {
                if any || !cur.isEmpty { out.append(cur) }
                cur = ""; any = false
            } else {
                cur.append(c)
            }
        }
        if any || !cur.isEmpty { out.append(cur) }
        return out
    }
}

struct WelcomeView: View {
    @ObservedObject var recents = Recents.shared
    @ObservedObject var draft: LaunchDraft
    var error: String?
    var launch: (LaunchOptions) -> Void

    var body: some View {
        HStack(spacing: 0) {
            start
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            recentList
                .frame(width: 260)
        }
        .frame(minWidth: 620, minHeight: 560)
    }

    private var start: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Image(systemName: "display")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text("Chumby").font(.largeTitle.weight(.semibold))
                Text("A Chumby Classic, emulated. It never has a network.")
                    .foregroundStyle(.secondary)
            }
            if let error {
                ScrollView {
                    Text(error)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .padding(10)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24)
            }
            HStack(spacing: 12) {
                Button { openImages() } label: {
                    Label("Open Images Folder…", systemImage: "folder")
                }
                .keyboardShortcut("o")
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Button { openKernel() } label: {
                    Label("Open Kernel…", systemImage: "cpu")
                }
                .controlSize(.large)
            }
            Text("A folder with zImage and nand.img, or a kernel by itself. Drop either here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                Toggle("Boot fast (‑icount: for tests, sound comes in bursts)", isOn: $draft.fast)
                Toggle("Write to the NAND image", isOn: $draft.write)
                    .disabled(draft.state != nil)
                LabeledContent("State Folder") {
                    HStack {
                        Text(draft.state.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(draft.state == nil ? .secondary : .primary)
                        if draft.state != nil {
                            Button { draft.state = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                        }
                        Button("Choose…") { chooseState() }
                    }
                }
                .help("Keeps flash writes and the saved state in a folder; the next start resumes from it")
                TextField("QEMU Arguments", text: $draft.extra, prompt: Text("-append console=ttymxc0,115200"))
                LabeledContent("QEMU") {
                    HStack {
                        Text(qemuLabel).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(draft.qemu == nil ? .secondary : .primary)
                        Button("Choose…") { chooseQemu() }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 520)
            .scrollDisabled(true)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .background(draft.dropping ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $draft.dropping) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { opened(url) }
            }
            return true
        }
    }

    private var qemuLabel: String {
        if let q = draft.qemu { return (q as NSString).abbreviatingWithTildeInPath }
        if let q = QemuLocator.find(given: nil) { return "Found: " + (q as NSString).abbreviatingWithTildeInPath }
        return "Not found"
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(.headline)
                .padding([.horizontal, .top], 14)
                .padding(.bottom, 6)
            if recents.items.isEmpty {
                Spacer()
                Text("Chumbys you start show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(recents.items, id: \.self) { o in
                        Button { launch(o) } label: { RecentRow(options: o) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Start") { launch(o) }
                                Button("Show in Finder") {
                                    let p = o.images ?? o.kernel ?? ""
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                                }
                                Divider()
                                Button("Remove from Recents") { recents.remove(o) }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(.background.secondary)
    }

    func opened(_ url: URL) {
        var dir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &dir)
        if dir.boolValue {
            launch(draft.options(images: url.path))
        } else {
            launch(draft.options(kernel: url.path))
        }
    }

    private func openImages() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = "Choose a folder with zImage and nand.img"
        p.prompt = "Start"
        if p.runModal() == .OK, let url = p.url { launch(draft.options(images: url.path)) }
    }

    private func openKernel() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.message = "Choose a kernel (zImage)"
        p.prompt = "Next"
        guard p.runModal() == .OK, let kernel = p.url else { return }
        let n = NSOpenPanel()
        n.canChooseFiles = true
        n.message = "Choose a NAND image to go with it, or Cancel to boot the kernel by itself"
        n.prompt = "Start"
        n.directoryURL = kernel.deletingLastPathComponent()
        let nand = n.runModal() == .OK ? n.url?.path : nil
        launch(draft.options(kernel: kernel.path, nand: nand))
    }

    private func chooseState() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.message = "Choose a folder for this Chumby's flash writes and saved state"
        if p.runModal() == .OK, let url = p.url { draft.state = url.path }
    }

    private func chooseQemu() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.message = "Choose a qemu-system-arm built with the chumby-classic machine"
        p.treatsFilePackagesAsDirectories = true
        if p.runModal() == .OK, let url = p.url {
            draft.qemu = url.path
            UserDefaults.standard.set(url.path, forKey: QemuLocator.defaultsKey)
        }
    }
}

struct RecentRow: View {
    let options: LaunchOptions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: options.images != nil ? "folder" : "cpu")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(options.displayName).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts: [String] = []
        let where_ = options.images ?? (options.kernel.map { ($0 as NSString).deletingLastPathComponent }) ?? ""
        parts.append((where_ as NSString).abbreviatingWithTildeInPath)
        if options.nand != nil { parts.append("NAND") }
        if options.state != nil { parts.append("state") }
        if options.fast { parts.append("fast") }
        if !options.extra.isEmpty { parts.append(options.extra.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }
}

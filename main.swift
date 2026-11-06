import AppKit

// Watches the macOS screenshot folder. Each new screenshot is copied to the
// clipboard, and each new screenshot or screen recording gets a floating
// preview (Preview.swift). Files are saved as usual: macOS's own thumbnail is
// turned off, so they land in the folder the moment a capture ends.

setvbuf(stdout, nil, _IOLBF, 0)

let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp"]
let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
    print("\(stamp) \(message)")
}

// Same folder the Screenshot app uses (⌘⇧5 → Options → Save to), falling back to the Desktop.
func screenshotFolder() -> URL {
    let saved = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
    let path = saved.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory() + "/Desktop"
    return URL(fileURLWithPath: path, isDirectory: true)
}

// Hands out TIFF only when an app asks for it, so a 5K screenshot doesn't put
// ~60 MB of uncompressed pixels on the clipboard every time.
final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    let image: NSImage
    init(image: NSImage) { self.image = image }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
    }
}

@MainActor
final class Watcher {
    let folder: URL
    private var known: Set<String> = []
    private var source: DispatchSourceFileSystemObject?
    private var tiffProvider: TIFFProvider?
    private let preview = PreviewController()

    init(folder: URL) { self.folder = folder }

    func start() throws {
        known = try visibleNames()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { self.folderChanged() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        log("Watching \(folder.path)")
    }

    private func visibleNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") })
    }

    private func folderChanged() {
        guard let current = try? visibleNames() else { return }
        let added = current.subtracting(known)
        known = current

        let newest = added
            .map { folder.appendingPathComponent($0) }
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) || videoExtensions.contains($0.pathExtension.lowercased()) }
            .max { modified($0) < modified($1) }
        guard let newest else { return }

        let isVideo = videoExtensions.contains(newest.pathExtension.lowercased())
        if !isVideo { copy(newest, attemptsLeft: 10) }
        preview.show(newest, isVideo: isVideo)
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // A file can show up a moment before it is fully written, so retry briefly.
    private func copy(_ url: URL, attemptsLeft: Int) {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.copy(url, attemptsLeft: attemptsLeft - 1) }
            } else {
                log("Couldn't read \(url.lastPathComponent)")
            }
            return
        }

        let item = NSPasteboardItem()
        if url.pathExtension.lowercased() == "png" { item.setData(data, forType: .png) }
        let provider = TIFFProvider(image: image)
        item.setDataProvider(provider, forTypes: [.tiff])
        tiffProvider = provider

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        log("Copied \(url.lastPathComponent)")
    }
}

// An accessory app: it can show the preview window but stays out of the Dock and ⌘-Tab.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let watcher = Watcher(folder: screenshotFolder())
do {
    try watcher.start()
} catch {
    log("Can't watch \(watcher.folder.path): \(error.localizedDescription)")
    exit(1)
}
// NSApp's run loop drives the preview and answers the clipboard's TIFF requests.
app.run()

import Foundation

/// Uygulamanın dosya klasörleri. Belgeler klasörü Dosyalar uygulamasında da görünür.
enum FileStore {
    private static var fm: FileManager { FileManager.default }

    static var documents: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var downloads: URL {
        ensure(documents.appendingPathComponent("Indirilenler", isDirectory: true))
    }

    static var subtitled: URL {
        ensure(documents.appendingPathComponent("Altyazili", isDirectory: true))
    }

    static var work: URL {
        ensure(fm.temporaryDirectory.appendingPathComponent("yakala-work", isDirectory: true))
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
        var cleaned = name.components(separatedBy: invalid).joined(separator: " ")
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { return "video" }
        return String(cleaned.prefix(80))
    }

    static func uniqueURL(in directory: URL, baseName: String, ext: String) -> URL {
        let base = sanitize(baseName)
        let suffix = ext.isEmpty ? "" : "." + ext
        var candidate = directory.appendingPathComponent(base + suffix)
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(index))" + suffix)
            index += 1
        }
        return candidate
    }

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    static func modificationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav"]

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    static func isPlayable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return videoExtensions.contains(ext) || audioExtensions.contains(ext)
    }

    static func list(_ directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .sorted { modificationDate($0) > modificationDate($1) }
    }

    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Uygulama kapsayıcısı her yeniden imzalamada değişebildiği için yolları ana klasöre göre saklarız
    static func relativeToHome(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home) {
            return String(path.dropFirst(home.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return path
    }

    static func fromHomeRelative(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
    }
}

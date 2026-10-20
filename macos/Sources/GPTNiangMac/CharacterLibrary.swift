import AppKit
import ImageIO
import UniformTypeIdentifiers

struct CharacterRecord: Codable, Identifiable, Equatable {
    static let builtin = CharacterRecord(id: "gpt-dragon", name: "默认龙娘")
    let id: String
    let name: String
    var isBuiltin: Bool { id == Self.builtin.id }
}

/// Imported files are owned PNG copies. Removing an entry retains its image for
/// undo, including after restarting; catalog writes never modify source files.
final class CharacterLibrary {
    private struct Catalog: Codable {
        var version = 1
        var characters: [CharacterRecord] = []
        var removed: [CharacterRecord] = []
    }
    enum LibraryError: LocalizedError {
        case invalidImage, tooLarge, invalidCatalog, missingImage, invisibleImage
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "图片无法读取，请选择 PNG、JPG、BMP 或 GIF 图片。"
            case .tooLarge: return "图片不能超过 20 MB、4096 × 4096 或 1600 万像素。"
            case .invalidCatalog: return "角色图库记录无法读取，已保留原文件，请检查资料目录。"
            case .missingImage: return "角色图片已丢失或损坏，请重新导入。"
            case .invisibleImage: return "图片没有可见像素，请换一张有内容的图片。"
            }
        }
    }
    let directory: URL
    private let catalogURL: URL
    private var catalog = Catalog()
    private var loadFailed = false
    private(set) var loadError: Error?
    var characters: [CharacterRecord] { [CharacterRecord.builtin] + catalog.characters }
    var canUndo: Bool { !catalog.removed.isEmpty }

    init(dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent("characters", isDirectory: true)
        catalogURL = directory.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: catalogURL.path) else { return }
        do {
            let data = try Data(contentsOf: catalogURL)
            guard data.count <= 1_000_000 else { throw LibraryError.invalidCatalog }
            let decoded = try JSONDecoder().decode(Catalog.self, from: data)
            let all = decoded.characters + decoded.removed
            guard decoded.version == 1,
                  all.allSatisfy({ Self.validID($0.id) && !$0.name.isEmpty && $0.name.count <= 120 }),
                  Set(all.map(\.id)).count == all.count else { throw LibraryError.invalidCatalog }
            catalog = decoded
        } catch {
            loadFailed = true; loadError = LibraryError.invalidCatalog
        }
    }

    private static func validID(_ id: String) -> Bool {
        id.hasPrefix("custom-") && UUID(uuidString: String(id.dropFirst(7))) != nil
    }

    func imageURL(for record: CharacterRecord) -> URL? {
        guard Self.validID(record.id) else { return nil }
        return directory.appendingPathComponent(record.id + ".png")
    }

    func image(for record: CharacterRecord, maxSize: Int = 2048) -> NSImage? {
        guard let url = imageURL(for: record),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    @discardableResult
    func importImage(at url: URL) throws -> CharacterRecord {
        guard !loadFailed else { throw LibraryError.invalidCatalog }
        guard ["png", "jpg", "jpeg", "bmp", "gif"].contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw LibraryError.invalidImage }
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes <= 20 * 1024 * 1024, width <= 4096, height <= 4096,
              width * height <= 16_000_000 else { throw LibraryError.tooLarge }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { throw LibraryError.invalidImage }
        guard Self.hasVisiblePixels(image) else { throw LibraryError.invisibleImage }
        let name = url.deletingPathExtension().lastPathComponent
            .components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let record = CharacterRecord(id: "custom-" + UUID().uuidString.lowercased(),
                                     name: name.isEmpty ? "我的角色" : String(name.prefix(120)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = imageURL(for: record)!
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw LibraryError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LibraryError.invalidImage }
        try (png as Data).write(to: file, options: .atomic)
        var next = catalog; next.characters.append(record)
        do { try save(next) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
        return record
    }

    private static func hasVisiblePixels(_ image: CGImage) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        return bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32,
                bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return stride(from: 3, to: buffer.count, by: 4).contains { buffer[$0] > 10 }
        }
    }

    func remove(_ id: String) throws {
        guard let index = catalog.characters.firstIndex(where: { $0.id == id }) else { return }
        var next = catalog
        next.removed.append(next.characters.remove(at: index))
        try save(next)
    }

    @discardableResult
    func undoRemoval() throws -> CharacterRecord? {
        guard let record = catalog.removed.last else { return nil }
        guard image(for: record, maxSize: 160) != nil else { throw LibraryError.missingImage }
        var next = catalog; next.removed.removeLast(); next.characters.append(record)
        try save(next)
        return record
    }

    private func save(_ next: Catalog) throws {
        guard !loadFailed else { throw LibraryError.invalidCatalog }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(next).write(to: catalogURL, options: .atomic)
        catalog = next
    }
}

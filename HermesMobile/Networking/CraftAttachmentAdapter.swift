import Foundation
import UniformTypeIdentifiers

struct CraftStoredAttachment: Codable, Equatable, Sendable {
    let id: String
    var type: String
    var name: String
    var mimeType: String
    var size: Int
    var originalSize: Int?
    var storedPath: String
    var thumbnailPath: String?
    var thumbnailBase64: String?
    var markdownPath: String?
    var wasResized: Bool?
    var resizedBase64: String?

    var messageAttachment: MessageAttachment {
        MessageAttachment(
            name: name,
            path: storedPath,
            mime: mimeType,
            size: size,
            isImage: type == "image" || mimeType.lowercased().hasPrefix("image/")
        )
    }

    var rpcValue: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "type": .string(type),
            "name": .string(name),
            "mimeType": .string(mimeType),
            "size": .number(Double(size)),
            "storedPath": .string(storedPath),
        ]
        if let originalSize { object["originalSize"] = .number(Double(originalSize)) }
        if let thumbnailPath { object["thumbnailPath"] = .string(thumbnailPath) }
        if let thumbnailBase64 { object["thumbnailBase64"] = .string(thumbnailBase64) }
        if let markdownPath { object["markdownPath"] = .string(markdownPath) }
        if let wasResized { object["wasResized"] = .bool(wasResized) }
        if let resizedBase64 { object["resizedBase64"] = .string(resizedBase64) }
        return .object(object)
    }
}

struct CraftOutgoingAttachment: Equatable, Sendable {
    let id: UUID
    let name: String
    let mimeType: String
    let data: Data
    let thumbnailData: Data?

    init(
        name: String,
        mimeType: String,
        data: Data,
        id: UUID = UUID(),
        thumbnailData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
        self.thumbnailData = thumbnailData
    }

    init(sharedImport: SharedAttachmentImport, id: UUID = UUID()) {
        let inferredType = sharedImport.typeIdentifier.flatMap(UTType.init)
        let mimeType = inferredType?.preferredMIMEType ?? "application/octet-stream"
        let isImage = Self.attachmentType(name: sharedImport.filename, mimeType: mimeType) == "image"
        self.init(
            name: sharedImport.filename,
            mimeType: mimeType,
            data: sharedImport.data,
            id: id,
            thumbnailData: isImage
                ? ImagePreviewDownsampler.previewData(
                    from: sharedImport.data,
                    maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
                )
                : nil
        )
    }

    var pendingAttachment: PendingAttachment {
        let isImage = type == "image"
        return PendingAttachment(
            id: id,
            name: name,
            path: "",
            mime: mimeType,
            size: data.count,
            isImage: isImage,
            thumbnailData: thumbnailData
        )
    }

    var type: String {
        Self.attachmentType(name: name, mimeType: mimeType)
    }

    private static func attachmentType(name: String, mimeType: String) -> String {
        let mime = mimeType.lowercased()
        let extensionName = URL(fileURLWithPath: name).pathExtension.lowercased()
        if mime.hasPrefix("image/") { return "image" }
        if mime.hasPrefix("audio/") { return "audio" }
        if mime == "application/pdf" || extensionName == "pdf" { return "pdf" }
        if ["doc", "docx", "ppt", "pptx", "xls", "xlsx"].contains(extensionName) { return "office" }
        if mime.hasPrefix("text/") || ["txt", "md", "json", "yaml", "yml", "xml", "csv", "swift", "js", "ts", "py"].contains(extensionName) {
            return "text"
        }
        return "unknown"
    }

    var rpcObject: [String: JSONValue] {
        var object: [String: JSONValue] = [
            "type": .string(type),
            "path": .string(name),
            "name": .string(name),
            "mimeType": .string(mimeType),
            "size": .number(Double(data.count)),
        ]
        if type == "text", let text = String(data: data, encoding: .utf8) {
            object["text"] = .string(text)
        } else {
            object["base64"] = .string(data.base64EncodedString())
        }
        return object
    }

    var rpcValue: JSONValue {
        .object(rpcObject)
    }
}

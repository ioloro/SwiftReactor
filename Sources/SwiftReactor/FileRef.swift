import Foundation

/// Reference to a file you've uploaded to a Reactor session. Returned by
/// ``Reactor/uploadFile(data:name:mimeType:)`` and passed back into model
/// commands that consume files (Helios `set_image`, LingBot `set_image`,
/// SANA-Streaming `set_video` in file mode).
///
/// Mirrors the shape of the Python SDK's `FileRef`. When embedded in a
/// command payload the wire JSON is the full struct
/// (`{upload_id, name, mime_type, size}`) — the server uses every field
/// for accounting and decoding hints.
///
/// Presigned upload URLs expire 15 minutes after creation, so reuse a
/// `FileRef` quickly after constructing it. If a command rejects with
/// `command_error` referencing a stale upload, re-upload and try again.
public struct FileRef: Codable, Sendable, Hashable {
    /// Presigned upload identifier returned by the coordinator. The
    /// server uses this to locate the bytes you just PUT to the
    /// presigned URL.
    public let uploadId: String
    /// Original filename — surfaced in `command_error` reasons and
    /// preserved for any model that cares (e.g. file-extension sniffing).
    public let name: String
    /// MIME type (`image/jpeg`, `image/png`, `video/mp4`, …). The model
    /// uses this to pick a decoder; mismatches surface as
    /// `command_error`.
    public let mimeType: String
    /// Byte count of the uploaded payload. Server-side accounting.
    public let size: Int

    public init(uploadId: String, name: String, mimeType: String, size: Int) {
        self.uploadId = uploadId
        self.name = name
        self.mimeType = mimeType
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id"
        case name
        case mimeType = "mime_type"
        case size
    }
}

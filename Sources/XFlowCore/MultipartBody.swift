import Foundation

/// Minimal RFC 7578 encoder. Foundation has no multipart builder and URLSession
/// will not make one, so this is the smallest thing that satisfies the OpenAI
/// transcription endpoint.
public struct MultipartBody {
    public let boundary: String
    private var parts = Data()

    public init(boundary: String = "xflow-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    public mutating func addFile(name: String, filename: String, contentType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        parts.append(data)
        append("\r\n")
    }

    /// The body with its closing boundary. Reading this does not mutate the
    /// builder, so it is safe to read more than once.
    public var finished: Data {
        var data = parts
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    private mutating func append(_ string: String) {
        parts.append(Data(string.utf8))
    }
}

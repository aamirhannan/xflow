import Foundation
import XFlowCore

func checkMultipartBody() {
    Checks.equal(MultipartBody(boundary: "ABC123").contentType,
                 "multipart/form-data; boundary=ABC123",
                 "content type includes the boundary")

    var fieldBody = MultipartBody(boundary: "B")
    fieldBody.addField(name: "model", value: "gpt-4o-transcribe")
    Checks.equal(String(data: fieldBody.finished, encoding: .utf8),
                 "--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-4o-transcribe\r\n--B--\r\n",
                 "fields are encoded with CRLF")

    var fileBody = MultipartBody(boundary: "B")
    fileBody.addFile(name: "file", filename: "clip.m4a", contentType: "audio/m4a", data: Data([0x01, 0x02]))
    let text = String(data: fileBody.finished, encoding: .isoLatin1)!
    Checks.check(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"clip.m4a\""),
                 "file part carries the filename")
    Checks.check(text.contains("Content-Type: audio/m4a"), "file part carries the content type")
    Checks.check(text.hasSuffix("\r\n--B--\r\n"), "body ends with the closing boundary")

    // Every byte value must round-trip — an m4a is not valid UTF-8.
    let payload = Data((0...255).map { UInt8($0) })
    var binaryBody = MultipartBody(boundary: "B")
    binaryBody.addFile(name: "file", filename: "clip.m4a", contentType: "audio/m4a", data: payload)
    Checks.check(binaryBody.finished.range(of: payload) != nil, "binary payload survives intact")

    var ordered = MultipartBody(boundary: "B")
    ordered.addField(name: "first", value: "1")
    ordered.addField(name: "second", value: "2")
    let orderedText = String(data: ordered.finished, encoding: .utf8)!
    Checks.check(orderedText.range(of: "name=\"first\"")!.lowerBound
                    < orderedText.range(of: "name=\"second\"")!.lowerBound,
                 "parts appear in the order they were added")
}

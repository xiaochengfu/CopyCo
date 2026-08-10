import CryptoKit
import Foundation

struct ClipboardFingerprintRepresentation {
    let uti: String
    let data: Data
    let itemIndex: Int
}

enum ClipboardFingerprint {
    static func make(from representations: [ClipboardFingerprintRepresentation]) -> String {
        var data = Data()
        for representation in representations {
            var itemIndex = UInt64(representation.itemIndex).bigEndian
            withUnsafeBytes(of: &itemIndex) { data.append(contentsOf: $0) }
            appendLengthPrefixed(Data(representation.uti.utf8), to: &data)
            appendLengthPrefixed(representation.data, to: &data)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }
}

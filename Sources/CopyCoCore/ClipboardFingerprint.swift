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
        return digest(data)
    }

    /// Identifies text independently of any richer representations that may
    /// accompany it. Every represented pasteboard item must provide text, so
    /// a partially textual multi-item payload cannot collapse into one entry.
    static func textIdentity(from representations: [ClipboardFingerprintRepresentation]) -> String? {
        let itemIndices = Set(representations.map(\.itemIndex)).sorted()
        guard !itemIndices.isEmpty else { return nil }

        var data = Data("CopyCo.text-identity.v1".utf8)
        for itemIndex in itemIndices {
            let itemRepresentations = representations.filter { $0.itemIndex == itemIndex }
            guard let text = itemRepresentations.first(where: { $0.uti == "public.utf8-plain-text" })
                ?? itemRepresentations.first(where: { $0.uti == "public.plain-text" }) else {
                return nil
            }
            var encodedItemIndex = UInt64(itemIndex).bigEndian
            withUnsafeBytes(of: &encodedItemIndex) { data.append(contentsOf: $0) }
            appendLengthPrefixed(text.data, to: &data)
        }
        return digest(data)
    }

    private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation

/// A single-writer optimization. The file stamp detects normal replacement,
/// corruption and permission changes instead of trusting memory alone.
public struct SnapshotFileCache {
    private struct Stamp: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date
        let permissions: UInt16
    }
    private var savedData: Data?
    private var savedStamp: Stamp?

    public init() {}

    @discardableResult
    public mutating func write(_ data: Data, to url: URL) throws -> Bool {
        let current = try Self.stamp(url)
        if let current, current == savedStamp, data == savedData { return false }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        savedData = data
        savedStamp = try Self.stamp(url)
        return true
    }

    private static func stamp(_ url: URL) throws -> Stamp? {
        let values: [FileAttributeKey: Any]
        do {
            values = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                    && error.code == NSFileReadNoSuchFileError {
            return nil
        }
        guard values[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard let device = values[.systemNumber] as? NSNumber,
              let inode = values[.systemFileNumber] as? NSNumber,
              let size = values[.size] as? NSNumber,
              let modified = values[.modificationDate] as? Date,
              let permissions = values[.posixPermissions] as? NSNumber else { return nil }
        return Stamp(device: device.uint64Value, inode: inode.uint64Value,
                     size: size.uint64Value, modified: modified,
                     permissions: permissions.uint16Value)
    }
}

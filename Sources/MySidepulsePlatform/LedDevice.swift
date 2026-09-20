import Foundation
import MySidepulseCore

/// Mount identity, not path: a replugged device gets the same path back with
/// a blank LEDS.LED, and a writer that trusted the path would leave it dark.
public struct DeviceKey: Hashable {
    public let dev: Int32
    public let ino: UInt64
}

public struct LedDevice: Equatable {
    public let key: DeviceKey
    public let mountPath: String
    public let name: String
    public var ledCount: Int { LedProgram.ledCount(volumeName: name) }
    public var ledsFilePath: String { mountPath + "/LEDS.LED" }

    public static func probe(mountPath: String, name: String) -> LedDevice? {
        guard FileManager.default.fileExists(atPath: mountPath + "/LEDS.LED") else { return nil }
        var st = stat()
        guard stat(mountPath, &st) == 0 else { return nil }
        return LedDevice(key: DeviceKey(dev: st.st_dev, ino: st.st_ino),
                         mountPath: mountPath, name: name)
    }
}

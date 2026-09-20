import Foundation

/// Only what the LED rules need to know about the battery.
public struct PowerState: Equatable {
    public var percent: Int
    public var plugged: Bool
    public var charging: Bool
    public var charged: Bool
    public var present: Bool
    public init(percent: Int = 0, plugged: Bool = false, charging: Bool = false,
                charged: Bool = false, present: Bool = true) {
        self.percent = percent; self.plugged = plugged; self.charging = charging
        self.charged = charged; self.present = present
    }
}

public enum BatteryRules {
    /// All four must hold. Plugging in clears it immediately — a low battery
    /// filling back up is not an emergency.
    public static func isCritical(_ power: PowerState?) -> Bool {
        guard let p = power, p.present else { return false }
        if p.plugged || p.charging || p.charged { return false }
        return p.percent <= K.batteryCriticalPercent
    }

    /// Thresholds inclusive: each belongs to the band beneath it, so the bar
    /// turns red exactly when the critical alarm would start breathing.
    public static func color(forPercent percent: Int) -> String {
        if percent <= K.batteryCriticalPercent { return K.batteryLowRed }
        if percent <= K.batteryMidPercent { return K.batteryMidAmber }
        return K.batteryHighGreen
    }

    public struct Fill: Equatable {
        public let full: Int
        public let partial: Double
        public let count: Int
    }

    public static func fill(percent: Int, ledCount: Int) -> Fill {
        let count = max(1, min(8, ledCount))
        let clamped = max(0, min(100, percent))
        let raw = Double(count) * Double(clamped) / 100.0
        let full = min(count, Int(raw.rounded(.down)))
        let partial = full >= count ? 0.0 : raw - Double(full)
        return Fill(full: full, partial: partial, count: count)
    }

    public static func fillColor(index: Int, fill: Fill, color: String) -> String {
        if index < fill.full { return color }
        if index == fill.full, fill.partial > 0 { return scaleHex(color, by: fill.partial) }
        return K.batteryOff
    }

    public static func scaleHex(_ hex: String, by fraction: Double) -> String {
        guard hex.count == 7, hex.hasPrefix("#"),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return hex }
        let f = max(0.0, min(1.0, fraction))
        let r = UInt32(Double((value >> 16) & 0xFF) * f)
        let g = UInt32(Double((value >> 8) & 0xFF) * f)
        let b = UInt32(Double(value & 0xFF) * f)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

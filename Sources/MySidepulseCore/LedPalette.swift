import Foundation

/// The colour of every state the owner can recolour on the Colours page. A
/// colour is a true colour: the strip's brightness setting dims it, never a
/// darker hex. `standard` is K's, and a slot with no saved override paints it.
public struct LedPalette: Equatable {
    public var working: String
    public var codexWorking: String
    public var copilotWorking: String
    public var opencodeWorking: String
    public var needsYou: String
    public var done: String
    public var jobRunning: String
    public var batteryCritical: String
    public var batteryLow: String
    public var batteryMid: String
    public var batteryHigh: String

    public static let standard = LedPalette(
        working: K.claudeWorking, codexWorking: K.codexWorking, copilotWorking: K.copilotWorking,
        opencodeWorking: K.opencodeWorking, needsYou: K.askAmber,
        done: K.doneGreen, jobRunning: K.jobRunning, batteryCritical: K.batteryCriticalRed,
        batteryLow: K.batteryLowRed, batteryMid: K.batteryMidAmber,
        batteryHigh: K.batteryHighGreen)

    /// One recolourable colour. The raw value is its key in `config.json`,
    /// so renaming a case is a migration. Declared in the page's order.
    ///
    /// Each agent works in a colour of its own; needs you and done are one
    /// colour for every agent: the strip says that the Mac wants the user,
    /// not which agent does. A failed command shares `needsYou` and a
    /// succeeded one shares `done` for the same reason: they are the same
    /// alert on the strip, and the ladder already tells them apart by
    /// precedence, not by colour.
    public enum Slot: String, CaseIterable, Sendable {
        case working, codexWorking, copilotWorking, opencodeWorking, needsYou, done, jobRunning
        case batteryCritical, batteryLow, batteryMid, batteryHigh

        /// What the Colours page plays for this slot: the state the colour
        /// paints, and for a battery bar a charge at the top of its band, so
        /// the bar lights as many LEDs as that colour ever does.
        public var preview: (state: DisplayState, power: PowerState?) {
            switch self {
            case .working: return (.working(.claude), nil)
            case .codexWorking: return (.working(.codex), nil)
            case .copilotWorking: return (.working(.copilot), nil)
            case .opencodeWorking: return (.working(.opencode), nil)
            case .needsYou: return (.waiting(.claude), nil)
            case .done: return (.done(.claude), nil)
            case .jobRunning: return (.jobRunning, nil)
            case .batteryCritical: return (.batteryCritical, nil)
            case .batteryLow: return (.batteryGlance, PowerState(percent: K.batteryCriticalPercent))
            case .batteryMid: return (.batteryGlance, PowerState(percent: K.batteryMidPercent))
            case .batteryHigh: return (.batteryGlance, PowerState(percent: 100))
            }
        }
    }

    public subscript(slot: Slot) -> String {
        get {
            switch slot {
            case .working: return working
            case .codexWorking: return codexWorking
            case .copilotWorking: return copilotWorking
            case .opencodeWorking: return opencodeWorking
            case .needsYou: return needsYou
            case .done: return done
            case .jobRunning: return jobRunning
            case .batteryCritical: return batteryCritical
            case .batteryLow: return batteryLow
            case .batteryMid: return batteryMid
            case .batteryHigh: return batteryHigh
            }
        }
        set {
            switch slot {
            case .working: working = newValue
            case .codexWorking: codexWorking = newValue
            case .copilotWorking: copilotWorking = newValue
            case .opencodeWorking: opencodeWorking = newValue
            case .needsYou: needsYou = newValue
            case .done: done = newValue
            case .jobRunning: jobRunning = newValue
            case .batteryCritical: batteryCritical = newValue
            case .batteryLow: batteryLow = newValue
            case .batteryMid: batteryMid = newValue
            case .batteryHigh: batteryHigh = newValue
            }
        }
    }

    /// The colour an agent rolls in.
    public func working(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: return working
        case .codex: return codexWorking
        case .copilot: return copilotWorking
        case .opencode: return opencodeWorking
        }
    }

    /// The colours of a roll shared by `agents`, in the agents' order, Claude's
    /// first: one per pass for two, one per LED for three or more
    /// (`LedProgram.rollPasses`). Never empty: a roll with no agent named
    /// takes Claude's colour.
    public func rollColors(_ agents: Agents) -> [String] {
        let colors = agents.kinds.map(working)
        return colors.isEmpty ? [working] : colors
    }

    /// This palette with the saved overrides applied. An override that is
    /// not `#` and six hex digits is ignored rather than trusted: one
    /// malformed colour makes the whole program unreadable to the device,
    /// and `config.json` can be edited by hand. Unknown keys are ignored.
    public func applying(overrides: [String: String]) -> LedPalette {
        var result = self
        for slot in Slot.allCases {
            if let hex = overrides[slot.rawValue], LedMode.isRGBHex(hex) {
                result[slot] = hex.lowercased()
            }
        }
        return result
    }

    /// The overrides to save after setting `slot` to `hex`. Nil, or the
    /// slot's own default, removes the override, so a slot at its default
    /// stores nothing and follows any later change of the default. A
    /// malformed hex changes nothing.
    public static func overrides(_ current: [String: String], setting slot: Slot,
                                 to hex: String?) -> [String: String] {
        var result = current
        guard let hex else {
            result.removeValue(forKey: slot.rawValue)
            return result
        }
        guard LedMode.isRGBHex(hex) else { return current }
        let colour = hex.lowercased()
        if colour == standard[slot] {
            result.removeValue(forKey: slot.rawValue)
        } else {
            result[slot.rawValue] = colour
        }
        return result
    }
}

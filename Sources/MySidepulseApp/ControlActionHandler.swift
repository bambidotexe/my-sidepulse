import AppKit

/// Closure target for any `NSControl`, so a button's action can be written where the button is
/// built. The onboarding wizard is AppKit, not SwiftUI, and builds its buttons in place.
private final class ActionTrampoline: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any?) { handler() }
}

private var trampolineKey: UInt8 = 0

extension NSControl {
    /// Retained by the control through an associated object: the trampoline lives exactly as long
    /// as the button does, which is what lets a row be built and forgotten.
    var actionHandler: (() -> Void)? {
        get { (objc_getAssociatedObject(self, &trampolineKey) as? ActionTrampoline)?.handler }
        set {
            guard let handler = newValue else {
                objc_setAssociatedObject(self, &trampolineKey, nil, .OBJC_ASSOCIATION_RETAIN)
                return
            }
            let trampoline = ActionTrampoline(handler)
            objc_setAssociatedObject(self, &trampolineKey, trampoline, .OBJC_ASSOCIATION_RETAIN)
            target = trampoline
            action = #selector(ActionTrampoline.fire(_:))
        }
    }
}

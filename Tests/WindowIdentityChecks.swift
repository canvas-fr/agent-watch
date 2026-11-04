import Foundation
import CoreGraphics

/// Pure rectangle-policy checks; these never enumerate or contact real windows.
@main
struct WindowIdentityChecks {
    static func main() {
        let targetPID: Int32 = 71
        let original = WindowIdentityRect(x: 100, y: 80, width: 640, height: 480)

        expect(
            WindowIdentityPolicy.uniqueWindowNumber(
                pid: targetPID,
                accessibilityBounds: original,
                candidates: [candidate(pid: 72, number: 90, bounds: original)]
            ) == nil,
            "a matching rectangle owned by another process is ignored"
        )
        expect(
            WindowIdentityPolicy.uniqueWindowNumber(
                pid: targetPID,
                accessibilityBounds: original,
                candidates: [
                    candidate(pid: 72, number: 90, bounds: original),
                    candidate(pid: targetPID, number: 91, bounds: original)
                ]
            ) == 91,
            "only the selected PID participates in matching"
        )
        expect(
            WindowIdentityPolicy.uniqueWindowNumber(
                pid: targetPID,
                accessibilityBounds: original,
                candidates: [
                    candidate(pid: targetPID, number: 91, bounds: original),
                    candidate(pid: targetPID, number: 92, bounds: original)
                ]
            ) == nil,
            "two same-process windows with the same rectangle are ambiguous"
        )
        expect(
            WindowIdentityPolicy.uniqueWindowNumber(
                pid: targetPID,
                accessibilityBounds: original,
                candidates: [candidate(
                    pid: targetPID,
                    number: 93,
                    bounds: WindowIdentityRect(x: 101.5, y: 79, width: 641.5, height: 479)
                )]
            ) == 93,
            "small position and border differences fit within the tolerance"
        )
        expect(
            WindowIdentityPolicy.uniqueWindowNumber(
                pid: targetPID,
                accessibilityBounds: original,
                candidates: [candidate(
                    pid: targetPID,
                    number: 94,
                    bounds: WindowIdentityRect(x: 102.01, y: 80, width: 640, height: 480)
                )]
            ) == nil,
            "a difference beyond the tolerance does not match"
        )
        expect(
            WindowIdentityPolicy.uniqueWindowNumber(
                pid: targetPID,
                accessibilityBounds: original,
                candidates: []
            ) == nil,
            "a disappeared window has no OS identity"
        )
        expect(
            WindowIdentityPolicy.preferredWindowNumber(
                privateAXWindowNumber: 95,
                geometryWindowNumber: 96
            ) == 95,
            "an AX-derived OS ID takes precedence over geometry"
        )
        expect(
            WindowIdentityPolicy.preferredWindowNumber(
                privateAXWindowNumber: 0,
                geometryWindowNumber: 96
            ) == 96,
            "a missing private-SPI ID retains the geometry fallback"
        )

        print("PASS: PID-filtered private and geometry window identity")
    }

    private static func candidate(
        pid: Int32,
        number: CGWindowID,
        bounds: WindowIdentityRect
    ) -> WindowIdentityCandidate {
        WindowIdentityCandidate(ownerPID: pid, windowNumber: number, bounds: bounds)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, "CHECK FAILED: \(message)")
    }
}

import Foundation

/// Pure policy checks; these never connect to or change an application.
@main
struct ChromiumAccessibilityChecks {
    static func main() {
        let mainBundle = ChromiumAccessibilityPolicy.doubaoBundleIdentifier
        let browserBundle = ChromiumAccessibilityPolicy.doubaoBrowserBundleIdentifier
        let mainPath = ChromiumAccessibilityPolicy.doubaoBundlePath
        let browserPath = ChromiumAccessibilityPolicy.doubaoBrowserBundlePath

        expect(
            ChromiumAccessibilityPolicy.admission(
                pid: 42,
                requestedBundleIdentifier: "com.google.GeminiMacOS",
                liveBundleIdentifier: "com.google.GeminiMacOS",
                liveBundlePath: "/Applications/Gemini.app",
                parentPID: nil,
                parentBundleIdentifier: nil,
                parentBundlePath: nil,
                accessibilityTrusted: true,
                alreadyAttempted: false
            ) == .ignore,
            "other browser app is never targeted"
        )
        expect(
            ChromiumAccessibilityPolicy.admission(
                pid: 0,
                requestedBundleIdentifier: mainBundle,
                liveBundleIdentifier: mainBundle,
                liveBundlePath: "/Applications/Doubao.app",
                parentPID: nil,
                parentBundleIdentifier: nil,
                parentBundlePath: nil,
                accessibilityTrusted: true,
                alreadyAttempted: false
            ) == .ignore,
            "invalid process IDs are ignored"
        )
        expect(
            ChromiumAccessibilityPolicy.admission(
                pid: 42,
                requestedBundleIdentifier: mainBundle,
                liveBundleIdentifier: mainBundle,
                liveBundlePath: "/Applications/Doubao.app",
                parentPID: nil,
                parentBundleIdentifier: nil,
                parentBundlePath: nil,
                accessibilityTrusted: false,
                alreadyAttempted: false
            ) == .permissionDenied,
            "missing AX permission rejects the request"
        )
        expect(
            ChromiumAccessibilityPolicy.admission(
                pid: 42,
                requestedBundleIdentifier: mainBundle,
                liveBundleIdentifier: mainBundle,
                liveBundlePath: nil,
                parentPID: nil,
                parentBundleIdentifier: nil,
                parentBundlePath: nil,
                accessibilityTrusted: true,
                alreadyAttempted: false
            ) == .proceed,
            "main Doubao keeps its original bundle-ID admission rule"
        )
        expect(
            ChromiumAccessibilityPolicy.admission(
                pid: 43,
                requestedBundleIdentifier: browserBundle,
                liveBundleIdentifier: browserBundle,
                liveBundlePath: "/Applications/Doubao.app/Contents/Helpers/Doubao Browser.app",
                parentPID: 42,
                parentBundleIdentifier: mainBundle,
                parentBundlePath: "/Applications/Doubao.app",
                accessibilityTrusted: true,
                alreadyAttempted: false
            ) == .proceed,
            "verified Browser helper child is eligible"
        )
        expect(
            ChromiumAccessibilityPolicy.admission(
                pid: 43,
                requestedBundleIdentifier: browserBundle,
                liveBundleIdentifier: browserBundle,
                liveBundlePath: "/tmp/Doubao Browser.app",
                parentPID: 42,
                parentBundleIdentifier: mainBundle,
                parentBundlePath: "/Applications/Doubao.app",
                accessibilityTrusted: true,
                alreadyAttempted: false
            ) == .ignore,
            "a copied helper bundle path is rejected"
        )
        expect(
            ChromiumAccessibilityPolicy.admission(
                pid: 43,
                requestedBundleIdentifier: browserBundle,
                liveBundleIdentifier: browserBundle,
                liveBundlePath: "/Applications/Doubao.app/Contents/Helpers/Doubao Browser.app",
                parentPID: 42,
                parentBundleIdentifier: "com.google.GeminiMacOS",
                parentBundlePath: "/Applications/Doubao.app",
                accessibilityTrusted: true,
                alreadyAttempted: false
            ) == .ignore,
            "an unrelated parent process is rejected"
        )
        expect(
            ChromiumAccessibilityPolicy.admission(
                pid: 42,
                requestedBundleIdentifier: mainBundle,
                liveBundleIdentifier: mainBundle,
                liveBundlePath: "/Applications/Doubao.app",
                parentPID: nil,
                parentBundleIdentifier: nil,
                parentBundlePath: nil,
                accessibilityTrusted: true,
                alreadyAttempted: true
            ) == .alreadyAttempted,
            "one PID is configured at most once"
        )
        expect(
            ChromiumAccessibilityPolicy.rootDiscoveryAdmission(
                appID: "doubao",
                requestedBundleIdentifier: mainBundle,
                liveBundleIdentifier: mainBundle,
                liveBundlePath: mainPath,
                parentPID: nil,
                parentBundleIdentifier: nil,
                parentBundlePath: nil
            ),
            "Doubao main root discovery requires its configured app path"
        )
        expect(
            !ChromiumAccessibilityPolicy.rootDiscoveryAdmission(
                appID: "doubao",
                requestedBundleIdentifier: mainBundle,
                liveBundleIdentifier: mainBundle,
                liveBundlePath: "/tmp/Doubao.app",
                parentPID: nil,
                parentBundleIdentifier: nil,
                parentBundlePath: nil
            ),
            "a copied Doubao main app is not a root-discovery target"
        )
        expect(
            ChromiumAccessibilityPolicy.rootDiscoveryAdmission(
                appID: "doubao",
                requestedBundleIdentifier: browserBundle,
                liveBundleIdentifier: browserBundle,
                liveBundlePath: browserPath,
                parentPID: 42,
                parentBundleIdentifier: mainBundle,
                parentBundlePath: mainPath
            ),
            "the exact packaged Doubao Browser child passes root-discovery admission"
        )
        expect(
            !ChromiumAccessibilityPolicy.rootDiscoveryAdmission(
                appID: "doubao",
                requestedBundleIdentifier: browserBundle,
                liveBundleIdentifier: browserBundle,
                liveBundlePath: browserPath,
                parentPID: 42,
                parentBundleIdentifier: mainBundle,
                parentBundlePath: "/tmp/Doubao.app"
            ),
            "a helper under a copied or unrelated parent is rejected"
        )
        expect(
            !ChromiumAccessibilityPolicy.rootDiscoveryAdmission(
                appID: "doubao",
                requestedBundleIdentifier: browserBundle,
                liveBundleIdentifier: browserBundle,
                liveBundlePath: "/tmp/Doubao Browser.app",
                parentPID: 42,
                parentBundleIdentifier: mainBundle,
                parentBundlePath: mainPath
            ),
            "a copied Browser helper is rejected even with a Doubao parent"
        )
        expect(
            ChromiumAccessibilityPolicy.rootDiscoveryAdmission(
                appID: "devin",
                requestedBundleIdentifier: ChromiumAccessibilityPolicy.devinBundleIdentifier,
                liveBundleIdentifier: ChromiumAccessibilityPolicy.devinBundleIdentifier,
                liveBundlePath: "/Applications/Devin.app",
                parentPID: nil,
                parentBundleIdentifier: nil,
                parentBundlePath: nil
            ),
            "Devin root discovery is limited to the configured live bundle ID"
        )
        expect(
            !ChromiumAccessibilityPolicy.rootDiscoveryAdmission(
                appID: "devin",
                requestedBundleIdentifier: "com.google.GeminiMacOS",
                liveBundleIdentifier: "com.google.GeminiMacOS",
                liveBundlePath: "/Applications/Gemini.app",
                parentPID: nil,
                parentBundleIdentifier: nil,
                parentBundlePath: nil
            ),
            "other apps are never root-discovery targets"
        )
        expect(
            ChromiumAccessibilityPolicy.writeDecision(
                attributeRead: .unsupported,
                settableCheck: .notChecked
            ) == .checkSettable,
            "unsupported reads require an explicit setter capability check"
        )
        expect(
            ChromiumAccessibilityPolicy.writeDecision(
                attributeRead: .unsupported,
                settableCheck: .notSettable
            ) == .refuseNotSettable,
            "unsupported read plus read-only attribute never writes"
        )
        expect(
            ChromiumAccessibilityPolicy.writeDecision(
                attributeRead: .unsupported,
                settableCheck: .failed
            ) == .refuseSettableCheckFailure,
            "setter capability errors never fall through to a write"
        )
        expect(
            ChromiumAccessibilityPolicy.writeDecision(
                attributeRead: .unsupported,
                settableCheck: .settable
            ) == .setOnce,
            "unsupported read plus confirmed settable attribute permits one write"
        )
        expect(
            ChromiumAccessibilityPolicy.writeDecision(
                attributeRead: .failed,
                settableCheck: .settable
            ) == .refuseReadFailure,
            "other read failures block writes even if the attribute is settable"
        )
        expect(
            ChromiumAccessibilityPolicy.writeDecision(
                attributeRead: .alreadyEnabled,
                settableCheck: .notChecked
            ) == .alreadyEnabled,
            "an already enabled attribute is not written again"
        )

        print("PASS: Doubao-only Chromium setter policy")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, "CHECK FAILED: \(message)")
    }
}

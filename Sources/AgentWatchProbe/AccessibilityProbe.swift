import ApplicationServices
import CoreFoundation
import Foundation

struct AccessibilityProbeResult: Codable, Sendable {
    let status: String
    let trusted: Bool
    let windowsObserved: Int?
    let elementsVisited: Int
    let roleCounts: [String: Int]
    let truncated: Bool
    let elapsedMilliseconds: Int
    let errors: [String]
}

private enum AccessibilityProbeLimits {
    static let messageTimeout: Float = 0.2
    static let timeBudgetSeconds: TimeInterval = 1.8
    static let maximumElements = 100
    static let maximumDepth = 7
    static let maximumArrayElements = 20
    static let maximumErrors = 50

    static let knownRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXSheet", "AXDialog", "AXPopover",
        "AXDrawer", "AXGroup", "AXButton", "AXRadioButton", "AXCheckBox",
        "AXStaticText", "AXTextField", "AXTextArea", "AXImage", "AXLink",
        "AXMenu", "AXMenuItem", "AXMenuBar", "AXToolbar", "AXTable",
        "AXRow", "AXCell", "AXOutline", "AXBrowser", "AXScrollArea",
        "AXList", "AXComboBox", "AXTabGroup", "AXTab", "AXSlider",
        "AXProgressIndicator", "AXUnknown"
    ]
}

private final class AccessibilityProbeAccumulator {
    private let startedAt: TimeInterval
    private let deadline: TimeInterval

    private(set) var windowsObserved: Int?
    private(set) var elementsVisited = 0
    private(set) var roleCounts: [String: Int] = [:]
    private(set) var truncated = false
    private(set) var errors: [String] = []

    private var omittedErrors = false

    private var hasReadableEvidence: Bool {
        roleCounts.values.contains(where: { $0 > 0 }) || (windowsObserved ?? 0) > 0
    }

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        self.deadline = startedAt + AccessibilityProbeLimits.timeBudgetSeconds
    }

    var elapsedMilliseconds: Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))
    }

    func configureTimeout(for element: AXUIElement) -> Bool {
        guard canContinue() else { return false }
        let result = AXUIElementSetMessagingTimeout(
            element,
            AccessibilityProbeLimits.messageTimeout
        )
        guard result == .success else {
            recordError("set_timeout", code: result)
            return false
        }
        return true
    }

    func inspectApplication(_ application: AXUIElement) {
        guard configureTimeout(for: application) else { return }
        elementsVisited = 1
        readRole(from: application)

        guard let count = readArrayCount(
            from: application,
            attribute: kAXWindowsAttribute as CFString,
            operation: "windows_count"
        ) else {
            return
        }
        windowsObserved = count
        if count > AccessibilityProbeLimits.maximumArrayElements {
            truncated = true
        }
        guard count > 0 else { return }

        let windowLimit = min(count, AccessibilityProbeLimits.maximumArrayElements)
        guard let windows = readArrayValues(
            from: application,
            attribute: kAXWindowsAttribute as CFString,
            count: windowLimit,
            operation: "windows_values"
        ) else {
            return
        }

        for window in windows {
            guard elementsVisited < AccessibilityProbeLimits.maximumElements else {
                truncated = true
                return
            }
            visit(window, depth: 1)
        }
    }

    func result(trusted: Bool) -> AccessibilityProbeResult {
        let status: String
        if !hasReadableEvidence {
            status = "unavailable"
        } else if errors.isEmpty && !truncated {
            status = "readable"
        } else {
            status = "partial"
        }

        return AccessibilityProbeResult(
            status: status,
            trusted: trusted,
            windowsObserved: windowsObserved,
            elementsVisited: elementsVisited,
            roleCounts: roleCounts,
            truncated: truncated,
            elapsedMilliseconds: elapsedMilliseconds,
            errors: errors
        )
    }

    private func visit(_ element: AXUIElement, depth: Int) {
        guard elementsVisited < AccessibilityProbeLimits.maximumElements else {
            truncated = true
            return
        }
        guard configureTimeout(for: element) else { return }
        elementsVisited += 1
        readRole(from: element)

        guard let childCount = readArrayCount(
            from: element,
            attribute: kAXChildrenAttribute as CFString,
            operation: "children_count"
        ) else {
            return
        }
        guard childCount > 0 else { return }
        guard depth < AccessibilityProbeLimits.maximumDepth else {
            truncated = true
            return
        }

        if childCount > AccessibilityProbeLimits.maximumArrayElements {
            truncated = true
        }
        let childLimit = min(childCount, AccessibilityProbeLimits.maximumArrayElements)
        guard let children = readArrayValues(
            from: element,
            attribute: kAXChildrenAttribute as CFString,
            count: childLimit,
            operation: "children_values"
        ) else {
            return
        }

        for child in children {
            guard elementsVisited < AccessibilityProbeLimits.maximumElements else {
                truncated = true
                return
            }
            visit(child, depth: depth + 1)
        }
    }

    private func readRole(from element: AXUIElement) {
        guard canContinue() else { return }
        var copiedRole: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &copiedRole
        )
        guard result == .success, let copiedRole,
              CFGetTypeID(copiedRole) == CFStringGetTypeID(),
              let role = copiedRole as? String else {
            if !isExpectedMissingAttribute(result) {
                recordError("role", code: result)
            }
            return
        }

        let safeRole = AccessibilityProbeLimits.knownRoles.contains(role) ? role : "AXOther"
        roleCounts[safeRole, default: 0] += 1
    }

    private func readArrayCount(
        from element: AXUIElement,
        attribute: CFString,
        operation: String
    ) -> Int? {
        guard canContinue() else { return nil }
        var valueCount: CFIndex = 0
        let result = AXUIElementGetAttributeValueCount(element, attribute, &valueCount)
        guard result == .success else {
            if !isExpectedMissingAttribute(result) {
                recordError(operation, code: result)
            }
            return nil
        }
        guard valueCount >= 0 else {
            recordError("\(operation)_invalid_count")
            return nil
        }
        return Int(valueCount)
    }

    private func readArrayValues(
        from element: AXUIElement,
        attribute: CFString,
        count: Int,
        operation: String
    ) -> [AXUIElement]? {
        guard count > 0 else { return [] }
        guard canContinue() else { return nil }

        var copiedValues: CFArray?
        let result = AXUIElementCopyAttributeValues(
            element,
            attribute,
            0,
            CFIndex(count),
            &copiedValues
        )
        guard result == .success, let copiedValues else {
            if !isExpectedMissingAttribute(result) {
                recordError(operation, code: result)
            }
            return nil
        }

        let valueCount = CFArrayGetCount(copiedValues)
        if valueCount > AccessibilityProbeLimits.maximumArrayElements {
            truncated = true
        }
        let inspectedCount = min(valueCount, AccessibilityProbeLimits.maximumArrayElements)
        var elements: [AXUIElement] = []
        elements.reserveCapacity(inspectedCount)
        for index in 0..<inspectedCount {
            guard let pointer = CFArrayGetValueAtIndex(copiedValues, index) else {
                recordError("\(operation)_unexpected_value")
                continue
            }
            let typeReference = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(typeReference) == AXUIElementGetTypeID() else {
                recordError("\(operation)_unexpected_value")
                continue
            }
            let elementValue = Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
            elements.append(elementValue)
        }
        return elements
    }

    private func canContinue() -> Bool {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            truncated = true
            return false
        }
        return true
    }

    private func isExpectedMissingAttribute(_ error: AXError) -> Bool {
        error == .attributeUnsupported || error == .noValue
    }

    private func recordError(_ operation: String, code: AXError) {
        recordError("\(operation)_axerror_\(code.rawValue)")
    }

    private func recordError(_ message: String) {
        guard errors.count < AccessibilityProbeLimits.maximumErrors else {
            if !omittedErrors {
                errors.append("additional_errors_omitted")
                omittedErrors = true
            }
            truncated = true
            return
        }
        errors.append(message)
    }
}

func inspectAccessibility(pid: Int32, enabled: Bool) -> AccessibilityProbeResult {
    guard enabled else {
        return AccessibilityProbeResult(
            status: "disabled",
            trusted: false,
            windowsObserved: nil,
            elementsVisited: 0,
            roleCounts: [:],
            truncated: false,
            elapsedMilliseconds: 0,
            errors: []
        )
    }

    let startedAt = ProcessInfo.processInfo.systemUptime
    guard AXIsProcessTrusted() else {
        return AccessibilityProbeResult(
            status: "permission_required",
            trusted: false,
            windowsObserved: nil,
            elementsVisited: 0,
            roleCounts: [:],
            truncated: false,
            elapsedMilliseconds: max(
                0,
                Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            ),
            errors: []
        )
    }

    let accumulator = AccessibilityProbeAccumulator(startedAt: startedAt)
    let application = AXUIElementCreateApplication(pid)
    accumulator.inspectApplication(application)
    return accumulator.result(trusted: true)
}

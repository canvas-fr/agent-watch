import AppKit
@preconcurrency import ApplicationServices
import SwiftUI

@main
struct AgentWatchApp: App {
    var body: some Scene {
        WindowGroup("Agent Watch 只读探测") {
            ProbeView()
        }
        .defaultSize(width: 820, height: 640)
    }
}

@MainActor
struct ProbeView: View {
    @State private var includeAccessibility = false
    @State private var collecting = false
    @State private var report = "点击“生成报告”检查八个应用。\n\n本原型尚未识别任务的运行、完成或等待授权状态。"
    @State private var permissionMessage = "辅助功能检查为可选项。基础探测无需授权。"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agent Watch · 接入验证原型")
                .font(.title2.bold())
            Text("检查应用版本、运行实例和可选的界面结构。报告只保存结构与元数据。")
                .foregroundStyle(.secondary)
            Toggle("尝试辅助功能结构检查", isOn: $includeAccessibility)
                .disabled(collecting)
            HStack {
                Button("生成报告") { collect() }
                    .disabled(collecting)
                Button("申请辅助功能权限") { requestAccessibility() }
                    .disabled(collecting)
                Button("复制报告") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .disabled(collecting)
                if collecting { ProgressView().controlSize(.small) }
            }
            Text(permissionMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                Text(report)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
    }

    private func collect() {
        collecting = true
        let accessibility = includeAccessibility
        Task { @MainActor in
            report = await Task.detached(priority: .utility) {
                let observations = InventoryProbe(home: FileManager.default.homeDirectoryForCurrentUser,
                                                  accessibility: accessibility).collect(AppCatalog.applications)
                return ProbeReport(collectedAt: ProbeDate.text(Date()),
                                   operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                                   accessibilityRequested: accessibility,
                                   applications: observations).markdown()
            }.value
            permissionMessage = AXIsProcessTrusted()
                ? "当前程序已有辅助功能权限；可读结构仍需要进一步验证是否包含任务状态。"
                : "当前程序没有辅助功能权限。基础信息可读取，界面结构暂不可用。"
            collecting = false
        }
    }

    private func requestAccessibility() {
        // Only this explicit user action asks macOS for access. Launch and collection do not prompt.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        includeAccessibility = true
        permissionMessage = trusted
            ? "已有辅助功能权限，请生成报告。"
            : "请在系统显示的辅助功能设置中为 Agent Watch Probe 开启权限，再生成报告；必要时重新打开本程序。"
    }
}

import Foundation

struct ProbeReport: Encodable {
    let schemaVersion = 1
    let probeVersion = "0.1.0-dev"
    let collectedAt: String
    let operatingSystem: String
    let accessibilityRequested: Bool
    let applications: [ApplicationObservation]
    let scope = "passive_inventory_and_accessibility_structure_only"
    let lifecycleAdaptersImplemented = false
    let privateContentCollected = false

    func markdown() -> String {
        var lines = [
            "# 八应用后台状态可观测性报告", "",
            "采集时间：\(collectedAt)（UTC）。系统：\(operatingSystem)。原型版本：\(probeVersion)。", "",
            "本轮只读检查安装信息、应用进程、明确候选路径的元数据，以及可选的辅助功能角色结构。所有应用的任务状态均为未知；尚未实现任务生命周期接入。", "",
            "未采集聊天正文、窗口标题、控件文本或截图；未遍历会话目录、修改配置、激活或操作目标应用。", "",
            "| 应用 | 安装版本 | 运行实例 | 辅助功能结构 | 任务状态 |", "| --- | --- | --- | --- | --- |"
        ]
        for app in applications {
            let versions = app.installations.map { $0.version ?? "版本未知" }.joined(separator: "、")
            let ax = app.instances.isEmpty ? "无运行实例，未探测" : Array(Set(app.instances.map { axLabel($0.accessibility.status) })).sorted().joined(separator: "、")
            lines.append("| \(app.name) | \(versions.isEmpty ? "标准位置未发现" : versions) | \(app.instances.count) | \(ax) | 未知 |")
        }
        lines += ["", "## 已观察到的证据与下一步", ""]
        for app in applications {
            lines += ["### \(app.name)", ""]
            for install in app.installations {
                lines.append("- 应用包：\(install.path)；包标识：\(install.bundleID ?? "未知")；版本：\(install.version ?? "未知")。")
            }
            for instance in app.instances {
                let ax = instance.accessibility
                lines.append("- 进程 \(instance.pid)：应用隐藏=\(instance.hidden)，位于前台=\(instance.frontmost)。这些信息不说明任务是否运行。")
                lines.append("- 辅助功能：\(axLabel(ax.status))；窗口数=\(ax.windowsObserved.map(String.init) ?? "未知")；访问节点=\(ax.elementsVisited)；遍历裁剪=\(ax.truncated)。")
                if !ax.roleCounts.isEmpty {
                    lines.append("- 角色统计：" + ax.roleCounts.keys.sorted().map { "\($0)=\(ax.roleCounts[$0]!)" }.joined(separator: "，") + "。角色存在不证明可读到任务状态。")
                }
                if !ax.errors.isEmpty { lines.append("- 结构探测信息：\(ax.errors.joined(separator: "；"))。") }
            }
            for candidate in app.sourceCandidates {
                lines.append("- 候选路径 \(candidate.path)：\(candidate.status)。\(candidate.purpose)。")
            }
            lines += ["- 待验证：\(app.nextVerification)", ""]
        }
        lines += [
            "## 本轮未验收的能力", "",
            "- 正常回复结束、任务成功、失败、取消、授权请求和用户提问的识别。",
            "- 前台、后台、最小化、其他桌面、多窗口和后台子任务场景。",
            "- 通知去重、两秒提醒、会话跳转及断线恢复。", "",
            "辅助功能角色树可读只说明结构可访问。缺少系统授权或状态控件时，不能推断客户端已经兼容。候选文件存在、文件修改时间和进程存活均不是任务生命周期证据。", "",
            "下一轮应使用专门测试会话按 docs/ACCEPTANCE.zh-CN.md 记录人工标注及事件证据。辅助功能授权在探测程序运行所在的系统身份下生效；本程序不主动弹出授权请求。", ""
        ]
        return lines.joined(separator: "\n")
    }

    private func axLabel(_ status: String) -> String {
        switch status {
        case "disabled": return "本轮未启用"
        case "permission_required": return "缺少辅助功能授权"
        case "readable": return "可读结构，状态未验证"
        case "partial": return "部分结构可读，状态未验证"
        case "round_budget_exhausted": return "本轮时间预算已用完，未探测"
        default: return "不可用（\(status)）"
        }
    }
}

import AppKit
import ServiceManagement
import SwiftUI

struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("登录 Mac 时打开 AI Everything", isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        error = nil
                    } catch {
                        self.error = "设置未成功。请先将应用放入“应用程序”文件夹，再重试。"
                    }
                    status = SMAppService.mainApp.status
                }
            ))
            .toggleStyle(.switch).controlSize(.small)
            if status == .requiresApproval {
                Button("前往系统设置允许登录项") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error { Text(error).foregroundStyle(.orange).font(.system(size: 12)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
    }
}

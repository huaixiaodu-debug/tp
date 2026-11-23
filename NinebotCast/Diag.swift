import Foundation

/// 读取广播扩展回传的诊断状态（/var/mobile/Documents/nbc_diag.json）
enum Diag {
    static let path = "/var/mobile/Documents/nbc_diag.json"

    static func read() -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}

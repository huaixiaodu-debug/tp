import Foundation

/// 扩展诊断状态：写 /var/mobile/Documents/nbc_diag.json（AppSync 越狱环境无沙盒，
/// 主 App 与 Filza 均可直接读取），替代不可见的扩展进程日志。
enum Diag {
    static let path = "/var/mobile/Documents/nbc_diag.json"

    static func write(_ dict: [String: Any]) {
        var d = dict
        d["ts"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: d,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = path + ".tmp"
        try? data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.moveItem(atPath: tmp, toPath: path)
    }

    static func read() -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}

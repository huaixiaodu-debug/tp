import SwiftUI
import ReplayKit
import Network

/// 全局持有 picker，供兜底按钮直接触发
enum PickerHolder {
    static var picker: RPSystemBroadcastPickerView?

    /// 递归找到 picker 内部的 broadcast 按钮并触发（绕过按钮不可见的渲染问题）
    static func trigger() -> Bool {
        guard let picker else { return false }
        return tapButton(in: picker)
    }

    private static func tapButton(in view: UIView) -> Bool {
        if let btn = view as? UIButton {
            btn.sendActions(for: .touchUpInside)
            return true
        }
        for sub in view.subviews where tapButton(in: sub) { return true }
        return false
    }
}

/// 把系统广播选择器包成 SwiftUI 可用的控件
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 240, height: 44))
        picker.showsMicrophoneButton = false
        picker.preferredExtension = "com.ninebot.cast.broadcast"
        picker.backgroundColor = .clear
        PickerHolder.picker = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct ContentView: View {
    @AppStorage("dashHost") private var dashHost = "192.168.1.1"
    @State private var probeStatus = ""
    @State private var probing = false
    @State private var pickerHint = ""

    var body: some View {
        Form {
            Section {
                TextField("仪表 IP（默认 192.168.1.1）", text: $dashHost)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button {
                    probe()
                } label: {
                    if probing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("探测中…（最长 12 秒）")
                        }
                    } else {
                        Text("探测仪表接收态（发心跳）")
                    }
                }
                .disabled(probing)
                if !probeStatus.isEmpty {
                    Text(probeStatus).font(.footnote)
                }
            } header: {
                Text("九号仪表")
            } footer: {
                Text("探测通过 = 仪表已进入投屏接收态，可以开始推流。")
            }

            Section {
                BroadcastPicker()
                    .frame(height: 44)
                    .frame(maxWidth: .infinity, alignment: .center)
                Button {
                    pickerHint = PickerHolder.trigger()
                        ? "已触发系统投屏面板，请在弹出的面板里选择 Ninebot Broadcast 并开始广播。"
                        : "投屏按钮未初始化，请重启手机后重新打开本 App。"
                } label: {
                    Text("打不开按钮？点这里直接调起系统投屏面板")
                        .font(.footnote)
                }
                if !pickerHint.isEmpty {
                    Text(pickerHint).font(.footnote).foregroundColor(.secondary)
                }
            } header: {
                Text("开始投屏")
            } footer: {
                Text("点上方圆形按钮 → 选择 Ninebot Broadcast → 开始广播。然后手机全屏打开导航（高德 / 百度 / Apple Maps 都行），画面会实时推到仪表。若按钮区域一直是空白：先重启一次手机（越狱/伪签名安装后系统需要重启才会注册投屏扩展），再打开本 App。")
            }

            Section {
                Text("视频为单向传输，触控请在手机上操作。音频走手机扬声器或车载蓝牙。骑行时请以路面安全为先。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } header: {
                Text("说明")
            }
        }
        .onAppear(perform: save)
        .onChange(of: dashHost) { _ in save() }
    }

    private func save() {
        UserDefaults(suiteName: "group.ninebot.cast")?
            .set(dashHost.trimmingCharacters(in: .whitespaces), forKey: "dashHost")
    }

    // MARK: - 探测（App 内直连实现，独立于扩展的 NinebotOutput）

    /// 20 字节心跳包：85 CC 00 04 | 8×00 | counter(LE32) | 02 00 00 00
    private func heartbeat(counter: UInt32) -> Data {
        var buf = Data(count: 20)
        buf[0] = 0x85
        buf[1] = 0xCC
        buf[3] = 0x04
        withUnsafeBytes(of: counter.littleEndian) { buf.replaceSubrange(12..<16, with: $0) }
        buf[16] = 0x02
        return buf
    }

    private func isPong(_ data: Data) -> Bool {
        data.count >= 20 && data[0] == 0x85 && data[1] == 0xCC
            && data[2] == 0x00 && data[3] == 0x04
    }

    private func probe() {
        save()
        let host = dashHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        probing = true
        probeStatus = ""

        var finished = false
        let params = NWParameters.udp
        guard let port = NWEndpoint.Port(rawValue: 5013) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)

        conn.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            // 进入接收态需要仪表开投屏；每 1.5 秒发一次心跳，共 7 次
            for i in 0..<7 {
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * 1.5) {
                    guard !finished else { return }
                    conn.send(content: heartbeat(counter: UInt32(i + 1)),
                              completion: .contentProcessed { _ in })
                }
            }
        }
        conn.start(queue: .global(qos: .userInitiated))

        func recv() {
            guard !finished else { return }
            conn.receiveMessage { data, _, _, _ in
                if let data, isPong(data) {
                    finished = true
                    conn.cancel()
                    DispatchQueue.main.async {
                        probing = false
                        probeStatus = "✓ 心跳有回应，仪表已进入投屏接收态。可以直接开始投屏。"
                    }
                    return
                }
                recv()
            }
        }
        recv()

        DispatchQueue.main.asyncAfter(deadline: .now() + 12.5) {
            guard !finished else { return }
            finished = true
            conn.cancel()
            DispatchQueue.main.async {
                probing = false
                probeStatus = "✗ 12 秒内无 pong 回应。检查：①手机连的是仪表热点而非家里路由器 ②仪表已打开投屏 ③IP 是否为 \(host)"
            }
        }
    }
}

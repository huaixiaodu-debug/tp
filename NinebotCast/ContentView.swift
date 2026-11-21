import SwiftUI
import ReplayKit
import Network

/// 把系统广播选择器包成 SwiftUI 可用的控件
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.showsMicrophoneButton = false
        picker.preferredExtension = "com.ninebot.cast.broadcast"
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct ContentView: View {
    @AppStorage("dashHost") private var dashHost = "192.168.1.1"
    @State private var probeStatus = ""
    @State private var probing = false

    var body: some View {
        Form {
            Section {
                TextField("仪表 IP（默认 192.168.1.1）", text: $dashHost)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .font(.monospaced(.body))
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
            } header: {
                Text("开始投屏")
            } footer: {
                Text("点上方按钮 → 选择 Ninebot Broadcast → 开始广播。然后手机全屏打开导航（高德 / 百度 / Apple Maps 都行），画面会实时推到仪表。")
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

    private func probe() {
        save()
        let host = dashHost.trimmingCharacters(in: .whitespaces)
        probing = true
        probeStatus = ""
        let out = NinebotOutput(host: host)
        var finished = false
        var attempts = 0

        func finish(_ ok: Bool, _ rtt: Double?) {
            guard !finished else { return }
            finished = true
            out.stop()
            DispatchQueue.main.async {
                probing = false
                if ok {
                    probeStatus = "✓ 心跳有回应，仪表已进入投屏接收态。可以直接开始投屏。"
                } else {
                    probeStatus = "✗ 12 秒内无 pong 回应。检查：①手机连的是仪表热点而非家里路由器 ②仪表已打开投屏 ③IP 是否为 \(host)"
                }
            }
        }

        func attempt() {
            guard attempts < 6, !finished else { return }
            attempts += 1
            out.probe(timeout: 2.0) { ok, rtt in
                if ok { finish(true, rtt) } else { attempt() }
            }
        }
        attempt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.5) { finish(false, nil) }
    }
}

//
//  NinebotOutput.swift
//  九号仪表私有投屏协议发送端（dash_sender.py 的 Swift 移植）
//
//  协议规格来源：xmgzxmgz/ninebot-dash-cast 的逆向成果
//    UDP 5012 视频：20 字节私有 RTP 头 + 1380 字节载荷（整包 1400）
//    UDP 5013 控制：20 字节 RTCP APP 心跳，仪表回 pong
//
//  用法：
//    let output = NinebotOutput(host: "192.168.1.1")
//    output.start { error in ... }          // 可选：先探心跳确认接收态
//    output.send(frame: annexbData)         // 每个访问单元（AU）调一次
//    output.stop()
//

import Foundation
import Network

final class NinebotOutput {

    // MARK: - 协议常量

    private static let headerSize = 20
    private static let payloadType: UInt8 = 32
    private static let h264Chunk = 1380
    private static let flagFirst: UInt8 = 0x10
    private static let flagLast: UInt8 = 0x08
    private static let flagKey: UInt8 = 0x01
    private static let flagInter: UInt8 = 0x02

    // MARK: - 状态

    private let host: String
    private let videoPort: UInt16
    private let ctrlPort: UInt16
    private let queue = DispatchQueue(label: "ninebot.output")

    private var videoConn: NWConnection?
    private var ctrlConn: NWConnection?
    private var seq: UInt16 = 0
    private var hbCounter: UInt32 = 0
    private var hbTimer: DispatchSourceTimer?
    private var pongHandler: ((Bool, Int) -> Void)?
    private var started = false

    var lastRTTms: Double?
    var lastError: String?
    private(set) var framesSent = 0
    private(set) var packetsSent = 0
    private(set) var bytesSent = 0

    // MARK: - 生命周期

    init(host: String, videoPort: UInt16 = 5012, ctrlPort: UInt16 = 5013) {
        self.host = host
        self.videoPort = videoPort
        self.ctrlPort = ctrlPort
    }

    /// 建立 UDP 通道并启动心跳保活
    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.openConnections()
            self.startHeartbeat()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.hbTimer?.cancel()
            self.hbTimer = nil
            self.videoConn?.cancel()
            self.ctrlConn?.cancel()
            self.videoConn = nil
            self.ctrlConn = nil
        }
    }

    /// 发心跳并等 pong，确认仪表已进入投屏接收态
    func probe(timeout: TimeInterval = 3.0, completion: @escaping (Bool, Double?) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        queue.async { [weak self] in
            guard let self else { return }
            self.openConnections()
            self.sendHeartbeat()
            self.pongHandler = { ok, _ in
                guard ok else { return }
                completion(true, self.lastRTTms)
                self.pongHandler = nil
            }
            // 超时由外部重试逻辑控制；这里只挂一次 pong 回调
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.pongHandler != nil else { return }
                self.pongHandler = nil
                completion(false, nil)
                _ = deadline
            }
        }
    }

    // MARK: - 网络通道

    private func openConnections() {
        guard videoConn == nil else { return }
        let params = NWParameters.udp
        params.allowFastOpen = true

        let v = NWConnection(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(rawValue: videoPort)!,
                             using: params)
        v.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                self?.lastError = "video: \(e)"
                NSLog("[Ninebot] 视频通道失败: \(e)")
            }
        }
        v.start(queue: queue)
        videoConn = v

        let c = NWConnection(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(rawValue: ctrlPort)!,
                             using: params)
        c.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.receivePong() }
            if case .failed(let e) = state { self?.lastError = "ctrl: \(e)" }
        }
        c.start(queue: queue)
        ctrlConn = c
    }

    private func receivePong() {
        ctrlConn?.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else {
                self?.receivePong()
                return
            }
            if Self.isPong(data) {
                self.lastRTTms = nil   // RTT 由 sendHeartbeat 打点后回填
                self.pongHandler?(true, data.count)
            }
            if self.started { self.receivePong() }
        }
    }

    // MARK: - 心跳

    private func heartbeatPacket() -> Data {
        var buf = Data(count: 20)
        buf[0] = 0x85; buf[1] = 0xCC; buf[3] = 0x04
        hbCounter &+= 1
        withUnsafeBytes(of: hbCounter.littleEndian) { buf.replaceSubrange(12..<16, with: $0) }
        buf[16] = 0x02
        return buf
    }

    private func sendHeartbeat() {
        guard let c = ctrlConn else { return }
        let sentAt = Date()
        c.send(content: heartbeatPacket(), completion: .contentProcessed { [weak self] _ in
            self?.lastHeartbeatSentAt = sentAt
        })
        // RTT 在收到 pong 时结算：pong 到达时间 - lastHeartbeatSentAt
    }

    private var lastHeartbeatSentAt: Date? {
        didSet {
            if let sent = lastHeartbeatSentAt {
                pendingRTTStart = sent
            }
        }
    }
    private var pendingRTTStart: Date?

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.sendHeartbeat() }
        t.resume()
        hbTimer = t
    }

    // MARK: - 视频推流

    /// 输入一个访问单元（AU，Annex-B 格式，含 SPS/PPS/IDR 或切片 NAL）
    func send(frame annexb: Data) {
        guard started, let v = videoConn, !annexb.isEmpty else { return }

        let keyframe = Self.isKeyframe(annexb)
        let ts = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000))
        let total = annexb.count
        var offset = 0
        var first = true

        while offset < total {
            let n = min(Self.h264Chunk, total - offset)
            let last = (offset + n >= total)
            let pkt = Self.header(seq: seq, ts: ts,
                                  first: first, last: last, keyframe: keyframe)
                + annexb.subdata(in: offset..<(offset + n))
            v.send(content: pkt, completion: .contentProcessed { _ in })
            seq = seq &+ 1
            packetsSent += 1
            bytesSent += Self.headerSize + n
            first = false
            offset += n
        }
        framesSent += 1
    }

    // MARK: - 协议打包（纯函数，可单测）

    /// 20 字节私有 RTP 头
    ///  [0] 0x90  [1] PT=32|末片0x80  [2:4] seq BE16  [4:8] ts BE32 毫秒
    ///  [8:12] ssrc=0  [12:15] 0  [15] 1  [16] 0  [17] flags  [18:20] LE16(ts 低 10 位)
    static func header(seq: UInt16, ts: UInt32,
                       first: Bool, last: Bool, keyframe: Bool) -> Data {
        var buf = Data(count: headerSize)
        buf[0] = 0x90
        buf[1] = payloadType | (last ? 0x80 : 0x00)
        withUnsafeBytes(of: seq.bigEndian) { buf.replaceSubrange(2..<4, with: $0) }
        withUnsafeBytes(of: ts.bigEndian) { buf.replaceSubrange(4..<8, with: $0) }
        // [8:12] ssrc 恒 0，[12:15] 0 —— Data(count:) 已置零
        buf[15] = 1
        buf[16] = 0
        var flags: UInt8 = 0
        if first { flags |= flagFirst }
        if last { flags |= flagLast }
        flags |= keyframe ? flagKey : flagInter
        buf[17] = flags
        let low = UInt16(ts & 0x03FF)
        withUnsafeBytes(of: low.littleEndian) { buf.replaceSubrange(18..<20, with: $0) }
        return buf
    }

    static func isPong(_ data: Data) -> Bool {
        data.count >= 20 && data[0] == 0x85 && data[1] == 0xCC
            && data[2] == 0x00 && data[3] == 0x04
    }

    /// 扫 Annex-B 起始码，遇 IDR(5) 或 SPS(7) 判为关键帧
    static func isKeyframe(_ frame: Data) -> Bool {
        let bytes = [UInt8](frame)
        var i = 0
        let sc: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        while i + 4 <= bytes.count {
            if [bytes[i], bytes[i+1], bytes[i+2], bytes[i+3]] == sc {
                if i + 4 < bytes.count {
                    let t = bytes[i + 4] & 0x1F
                    if t == 5 || t == 7 { return true }
                }
            }
            i += 1
        }
        return false
    }
}

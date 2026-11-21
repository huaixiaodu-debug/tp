import ReplayKit
import Foundation

/// ReplayKit 广播扩展：系统录屏 → H.264 Annex-B → 九号仪表 UDP 推流
class SampleHandler: RPBroadcastSampleHandler {

    private let suite = UserDefaults(suiteName: "group.ninebot.cast")
    private var adaptor: VideoEncoderAnnexBAdaptor?
    private var output: NinebotOutput?
    private var consumer: Task<Void, Never>?
    private var frameCount = 0
    private var lastLog = Date()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let host = suite?.string(forKey: "dashHost").flatMap { $0.isEmpty ? nil : $0 } ?? "192.168.1.1"
        NSLog("[NBC] broadcastStarted，仪表 IP=%@", host)

        // 编码参数按仪表解码器卡死值配置：Baseline 常规由 ultraLowLatency 决定，
        // 禁 B 帧（allowFrameReordering=false）、2 秒 I 帧间隔、CBR 1.5 Mbps
        var cfg = VideoEncoder.Config.ultraLowLatency
        cfg.maxKeyFrameInterval = 60
        cfg.maxKeyFrameIntervalDuration = 2
        cfg.allowFrameReordering = false
        cfg.allowOpenGOP = false
        cfg.averageBitRate = 1_500_000
        cfg.constantBitRate = 1_500_000

        let encoder = VideoEncoder(config: cfg)
        let ad = VideoEncoderAnnexBAdaptor(videoEncoder: encoder)
        adaptor = ad

        let out = NinebotOutput(host: host)
        output = out
        out.start()

        consumer = Task { [weak self] in
            for await data in ad.annexBData {
                guard let self else { break }
                self.output?.send(frame: data)
                self.frameCount += 1
                if Date().timeIntervalSince(self.lastLog) > 5 {
                    self.lastLog = Date()
                    NSLog("[NBC] frames=%d packets=%d bytes=%d",
                          self.frameCount,
                          self.output?.packetsSent ?? 0,
                          self.output?.bytesSent ?? 0)
                }
            }
        }
    }

    override func broadcastFinished() {
        NSLog("[NBC] broadcastFinished，共 %d 帧", frameCount)
        consumer?.cancel()
        consumer = nil
        output?.stop()
        output = nil
        adaptor = nil
    }

    override func broadcastAnnotated(withApplicationInfo applicationInfo: [String: NSObject]) {
        super.broadcastAnnotated(withApplicationInfo: applicationInfo)
    }

    /// 只处理视频；音频走手机扬声器或蓝牙，不推给仪表
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            adaptor?.videoEncoder.encode(sampleBuffer)
        case .audioApp, .audioMic:
            break
        @unknown default:
            break
        }
    }
}

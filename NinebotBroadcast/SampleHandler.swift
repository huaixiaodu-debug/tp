import ReplayKit
import Foundation
import VideoToolbox

/// ReplayKit 广播扩展：系统录屏 → H.264 Annex-B → 九号仪表 UDP 推流
class SampleHandler: RPBroadcastSampleHandler {

    private let suite = UserDefaults(suiteName: "group.ninebot.cast")
    private var adaptor: VideoEncoderAnnexBAdaptor?
    private var output: NinebotOutput?
    private var consumer: Task<Void, Never>?
    private var frameCount = 0
    private var recvCount = 0
    private var lastLog = Date()
    private var statTimer: DispatchSourceTimer?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let host = suite?.string(forKey: "dashHost").flatMap { $0.isEmpty ? nil : $0 } ?? "192.168.1.1"
        NSLog("[NBC] broadcastStarted，仪表 IP=%@", host)
        Diag.write(["stage": "broadcastStarted", "host": host])

        // 仪表硬解要求：H.264 Baseline、固定 848×480、无 B 帧、CBR 1.5 Mbps
        var cfg = VideoEncoder.Config.ultraLowLatency
        cfg.codecType = kCMVideoCodecType_H264
        cfg.profileLevel = kVTProfileLevel_H264_Baseline_AutoLevel
        cfg.expectedFrameRate = 30
        cfg.maxKeyFrameInterval = 60
        cfg.maxKeyFrameIntervalDuration = 2
        cfg.allowFrameReordering = false
        cfg.allowOpenGOP = false
        cfg.averageBitRate = 1_500_000
        cfg.constantBitRate = 1_500_000

        let encoder = VideoEncoder(config: cfg)
        encoder.targetSize = CGSize(width: 848, height: 480)

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

        // 每 2 秒把扩展内部状态写进诊断文件，主 App 读取显示
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1.0, repeating: 2.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Diag.write([
                "stage": "broadcasting",
                "host": host,
                "recvFrames": self.recvCount,
                "encFrames": self.frameCount,
                "packets": self.output?.packetsSent ?? 0,
                "bytes": self.output?.bytesSent ?? 0,
                "netError": self.output?.lastError ?? ""
            ])
        }
        t.resume()
        statTimer = t
    }

    override func broadcastFinished() {
        NSLog("[NBC] broadcastFinished，共 %d 帧", frameCount)
        Diag.write(["stage": "finished",
                    "encFrames": frameCount,
                    "packets": output?.packetsSent ?? 0])
        statTimer?.cancel()
        statTimer = nil
        consumer?.cancel()
        consumer = nil
        output?.stop()
        output = nil
        adaptor = nil
    }

    /// 只处理视频；音频走手机扬声器或蓝牙，不推给仪表
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            recvCount += 1
            adaptor?.videoEncoder.encode(sampleBuffer)
        case .audioApp, .audioMic:
            break
        @unknown default:
            break
        }
    }
}

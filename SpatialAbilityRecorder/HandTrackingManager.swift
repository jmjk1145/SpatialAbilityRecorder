import Vision
import CoreVideo
import CoreImage

/// 手部追踪管理器：使用 Vision 的 VNDetectHumanHandPoseRequest 实时自动检测双手。
///
/// 自动识别手部关键点，支持双手同时检测。
/// 每只手取食指尖位置作为特效锚点；当检测到两只手时，
/// 特效中心自动定位到两手之间，距离决定特效大小。
final class HandTrackingManager {

    /// 追踪结果：检测到的手部信息
    struct HandResult {
        /// 手部位置（视图归一化坐标，左上角原点，y 向下）
        var position: CGPoint
        /// 置信度 (0~1)
        var confidence: Float
        /// 是否为左手
        var isLeft: Bool
    }

    /// 当前检测到的手部结果（最多2只）
    private(set) var hands: [HandResult] = []

    /// 是否检测到手
    var hasHand: Bool { !hands.isEmpty }

    /// 是否检测到双手
    var hasBothHands: Bool { hands.count >= 2 }

    /// 主手位置（第一只检测到的手）
    var primaryHandPosition: CGPoint {
        hands.first?.position ?? CGPoint(x: 0.5, y: 0.5)
    }

    /// 双手中点位置（两只手都检测到时）
    var handsMidpoint: CGPoint {
        guard hands.count >= 2 else { return primaryHandPosition }
        let h1 = hands[0].position
        let h2 = hands[1].position
        return CGPoint(x: (h1.x + h2.x) / 2, y: (h1.y + h2.y) / 2)
    }

    /// 双手间距离（归一化）
    var handsDistance: Float {
        guard hands.count >= 2 else { return 0 }
        let h1 = hands[0].position
        let h2 = hands[1].position
        let dx = Float(h1.x - h2.x)
        let dy = Float(h1.y - h2.y)
        return sqrt(dx * dx + dy * dy)
    }

    /// 综合置信度
    var overallConfidence: Float {
        if hands.isEmpty { return 0 }
        return hands.map { $0.confidence }.reduce(0, +) / Float(hands.count)
    }

    private let handPoseRequest: VNDetectHumanHandPoseRequest
    private let lock = NSLock()

    init() {
        handPoseRequest = VNDetectHumanHandPoseRequest()
        handPoseRequest.maximumHandCount = 2
    }

    /// 每帧调用：检测手部姿态
    func update(with pixelBuffer: CVPixelBuffer, time: CMTime) {
        lock.lock()
        defer { lock.unlock() }

        // AVFoundation 已通过 videoOrientation=.portrait 输出竖屏正立 buffer
        let orientation: CGImagePropertyOrientation = .up
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])

        do {
            try handler.perform([handPoseRequest])
        } catch {
            hands = []
            return
        }

        guard let observations = handPoseRequest.results, !observations.isEmpty else {
            hands = []
            return
        }

        var results: [HandResult] = []

        for obs in observations {
            // 获取食指尖位置（最常用于定位特效）
            guard let indexTip = obs.indexTips?.first else {
                // 回退到手心位置
                guard let wrist = obs.landmarks[.wrist] else { continue }
                let pos = CGPoint(x: wrist.location.x, y: 1.0 - wrist.location.y)
                results.append(HandResult(position: pos, confidence: obs.confidence, isLeft: obs.chirality == .left))
                continue
            }

            // Vision 坐标系：左下角原点，y 向上
            // 视图坐标系：左上角原点，y 向下 → 翻转 y
            let pos = CGPoint(x: indexTip.location.x, y: 1.0 - indexTip.location.y)
            results.append(HandResult(position: pos, confidence: obs.confidence, isLeft: obs.chirality == .left))
        }

        // 按置信度排序，取前2只
        results.sort { $0.confidence > $1.confidence }
        hands = Array(results.prefix(2))
    }

    /// 重置
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        hands = []
    }
}

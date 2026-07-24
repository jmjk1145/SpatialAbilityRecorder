import Vision
import CoreVideo
import CoreImage

/// 手部追踪管理器：使用 Vision 的 VNDetectHumanHandPoseRequest 实时自动检测双手。
///
/// 智能特性：
/// 1. 位置平滑（指数移动平均 EMA）—— 消除抖动，追踪流畅
/// 2. 丢手保持 —— 手短暂丢失时保留最后位置 ~10 帧，避免特效闪烁
/// 3. 动态半径 —— 双手距离越远特效越大，单手时基于手部包围盒大小
/// 4. 多关键点融合 —— 使用食指尖 + 中指尖 + 手腕的加权质心，比单点更稳定
/// 5. 手势感知 —— 检测握拳/张开/捏合手势，可用于智能切换行为
final class HandTrackingManager {

    /// 追踪结果：检测到的手部信息
    struct HandResult {
        /// 平滑后的手部位置（视图归一化坐标，左上角原点，y 向下）
        var position: CGPoint
        /// 原始检测位置（未平滑）
        var rawPosition: CGPoint
        /// 置信度 (0~1)
        var confidence: Float
        /// 是否为左手
        var isLeft: Bool
        /// 手势类型
        var gesture: HandGesture
        /// 手部包围盒大小（归一化）
        var handSize: Float
    }

    /// 手势类型
    enum HandGesture {
        case open       // 张开手掌
        case fist       // 握拳
        case pinch      // 捏合（食指+拇指）
        case pointing   // 指向（仅食指伸出）
        case unknown
    }

    /// 当前检测到的手部结果（最多2只，已平滑）
    private(set) var hands: [HandResult] = []

    /// 上一帧的手部结果（用于丢手保持）
    private var lastHands: [HandResult] = []

    /// 丢手保持计数器
    private var lostFrameCount: Int = 0

    /// 最大丢手保持帧数（超过此帧数才真正清除）
    private let maxLostFrames: Int = 10

    /// 位置平滑系数（0~1，越大越平滑但延迟越大）
    private let smoothingFactor: CGFloat = 0.35

    /// 是否检测到手
    var hasHand: Bool { !hands.isEmpty }

    /// 是否检测到双手
    var hasBothHands: Bool { hands.count >= 2 }

    /// 主手位置（第一只检测到的手，已平滑）
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

    /// 动态特效半径（基于手部状态自适应）
    /// - 双手：距离的 40%，范围 0.12~0.35
    /// - 单手：手部大小的 1.5 倍，范围 0.10~0.25
    var dynamicRadius: Float {
        if hands.count >= 2 {
            let dist = handsDistance
            return min(max(dist * 0.4, 0.12), 0.35)
        } else if let hand = hands.first {
            return min(max(hand.handSize * 1.5, 0.10), 0.25)
        }
        return 0.18
    }

    /// 综合置信度
    var overallConfidence: Float {
        if hands.isEmpty { return 0 }
        return hands.map { $0.confidence }.reduce(0, +) / Float(hands.count)
    }

    /// 主手手势
    var primaryGesture: HandGesture {
        hands.first?.gesture ?? .unknown
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
            applyLostFrame()
            return
        }

        guard let observations = handPoseRequest.results, !observations.isEmpty else {
            applyLostFrame()
            return
        }

        var results: [HandResult] = []

        for obs in observations {
            let (rawPos, handSize) = computeHandCenterAndSize(obs)
            let gesture = detectGesture(obs)
            let confidence = obs.confidence

            // 平滑位置：与上一帧同侧手做 EMA
            let smoothedPos = smoothPosition(rawPos, chirality: obs.chirality)

            results.append(HandResult(
                position: smoothedPos,
                rawPosition: rawPos,
                confidence: confidence,
                isLeft: obs.chirality == .left,
                gesture: gesture,
                handSize: handSize
            ))
        }

        // 按置信度排序，取前2只
        results.sort { $0.confidence > $1.confidence }
        let topResults = Array(results.prefix(2))

        // 重置丢手计数
        lostFrameCount = 0
        lastHands = topResults
        hands = topResults
    }

    // MARK: - 智能计算

    /// 计算手部中心和大小：使用食指尖、中指尖、手腕三点加权质心
    private func computeHandCenterAndSize(_ obs: VNHumanHandPoseObservation) -> (CGPoint, Float) {
        var points: [CGPoint] = []

        // 收集可用关键点
        if let indexTip = obs.indexTips?.first { points.append(indexTip.location) }
        if let middleTip = obs.middleTips?.first { points.append(middleTip.location) }
        if let wrist = obs.landmarks[.wrist] { points.append(wrist.location) }
        if let thumbTip = obs.thumbTips?.first { points.append(thumbTip.location) }
        if let ringTip = obs.ringTips?.first { points.append(ringTip.location) }
        if let littleTip = obs.littleTips?.first { points.append(littleTip.location) }

        guard !points.isEmpty else {
            return (CGPoint(x: 0.5, y: 0.5), 0.1)
        }

        // 加权质心：食指尖权重最高（用于精确定位特效）
        var totalWeight: CGFloat = 0
        var weightedX: CGFloat = 0
        var weightedY: CGFloat = 0

        let weights: [CGFloat] = [3.0, 2.0, 1.5, 1.0, 0.8, 0.8] // 食指、中指、手腕、拇指、无名指、小指
        for (i, p) in points.enumerated() {
            let w = i < weights.count ? weights[i] : 0.5
            totalWeight += w
            weightedX += p.x * w
            weightedY += p.y * w
        }

        let cx = weightedX / totalWeight
        let cy = weightedY / totalWeight

        // Vision 坐标系：左下角原点，y 向上 → 视图坐标系：左上角原点，y 向下
        let pos = CGPoint(x: cx, y: 1.0 - cy)

        // 计算手部包围盒大小
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        let width = Float(xs.max()! - xs.min()!)
        let height = Float(ys.max()! - ys.min()!)
        let handSize = sqrt(width * width + height * height)

        return (pos, handSize)
    }

    /// 手势识别
    private func detectGesture(_ obs: VNHumanHandPoseObservation) -> HandGesture {
        guard let wrist = obs.landmarks[.wrist],
              let indexTip = obs.indexTips?.first,
              let thumbTip = obs.thumbTips?.first,
              let middleTip = obs.middleTips?.first else {
            return .unknown
        }

        // 计算各指尖到手腕的距离
        let dist = { (a: CGPoint, b: CGPoint) -> CGFloat in
            let dx = a.x - b.x, dy = a.y - b.y
            return sqrt(dx * dx + dy * dy)
        }

        let indexDist = dist(indexTip, wrist.location)
        let middleDist = dist(middleTip, wrist.location)
        let thumbIndexDist = dist(thumbTip, indexTip)

        // 参考距离：手腕到中指根（用于归一化）
        let refDist = max(middleDist, 0.01)

        // 捏合：拇指与食指尖距离很近
        if thumbIndexDist < refDist * 0.3 {
            return .pinch
        }

        // 握拳：食指和中指都靠近手腕
        if indexDist < refDist * 0.5 && middleDist < refDist * 0.5 {
            return .fist
        }

        // 指向：食指远伸但中指弯曲
        if indexDist > refDist * 0.8 && middleDist < refDist * 0.6 {
            return .pointing
        }

        // 张开：所有手指都伸展
        return .open
    }

    /// 位置平滑：与上一帧同侧手做指数移动平均
    private func smoothPosition(_ raw: CGPoint, chirality: VNHumanHandPoseObservation.Chirality) -> CGPoint {
        // 查找上一帧同侧手
        let prev = lastHands.first { $0.isLeft == (chirality == .left) }

        guard let prev = prev else {
            return raw // 首帧或新手出现，直接使用原始位置
        }

        let alpha = smoothingFactor
        return CGPoint(
            x: prev.position.x * (1 - alpha) + raw.x * alpha,
            y: prev.position.y * (1 - alpha) + raw.y * alpha
        )
    }

    /// 丢手保持：手短暂丢失时保留最后位置，避免特效闪烁
    private func applyLostFrame() {
        lostFrameCount += 1
        if lostFrameCount <= maxLostFrames && !lastHands.isEmpty {
            // 保留最后位置，但降低置信度（逐渐淡出）
            let fadeFactor = 1.0 - Float(lostFrameCount) / Float(maxLostFrames)
            hands = lastHands.map { hand in
                var h = hand
                h.confidence *= fadeFactor
                return h
            }
        } else {
            hands = []
            lastHands = []
        }
    }

    /// 重置
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        hands = []
        lastHands = []
        lostFrameCount = 0
    }
}

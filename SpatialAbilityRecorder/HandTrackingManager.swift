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
/// 6. 帧间匹配 —— 按距离最近原则匹配上一帧的手，实现稳定的逐手平滑
final class HandTrackingManager {

    /// 追踪结果：检测到的手部信息
    struct HandResult {
        /// 平滑后的手部位置（视图归一化坐标，左上角原点，y 向下）
        var position: CGPoint
        /// 原始检测位置（未平滑）
        var rawPosition: CGPoint
        /// 置信度 (0~1)
        var confidence: Float
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

    /// 上一帧的手部结果（用于丢手保持和帧间匹配）
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

            results.append(HandResult(
                position: rawPos,
                rawPosition: rawPos,
                confidence: confidence,
                gesture: gesture,
                handSize: handSize
            ))
        }

        // 按置信度排序，取前2只
        results.sort { $0.confidence > $1.confidence }
        let topResults = Array(results.prefix(2))

        // 帧间匹配 + 位置平滑
        let smoothedResults = smoothHands(topResults)

        // 重置丢手计数
        lostFrameCount = 0
        lastHands = smoothedResults
        hands = smoothedResults
    }

    // MARK: - 智能计算

    /// 计算手部中心和大小：使用多关键点加权质心
    private func computeHandCenterAndSize(_ obs: VNHumanHandPoseObservation) -> (CGPoint, Float) {
        guard let allPoints = try? obs.recognizedPoints(.all), !allPoints.isEmpty else {
            return (CGPoint(x: 0.5, y: 0.5), 0.1)
        }

        // 关节名与对应权重（食指尖权重最高，用于精确定位特效）
        let jointWeights: [(VNHumanHandPoseObservation.JointName, CGFloat)] = [
            (.indexTip, 3.0),
            (.middleTip, 2.0),
            (.wrist, 1.5),
            (.thumbTip, 1.0),
            (.ringTip, 0.8),
            (.littleTip, 0.8)
        ]

        var weightedPoints: [(CGPoint, CGFloat)] = []
        var allLocations: [CGPoint] = []

        for (jointName, weight) in jointWeights {
            if let point = allPoints[jointName], point.confidence > 0 {
                weightedPoints.append((point.location, weight))
                allLocations.append(point.location)
            }
        }

        guard !weightedPoints.isEmpty else {
            return (CGPoint(x: 0.5, y: 0.5), 0.1)
        }

        // 加权质心
        var totalWeight: CGFloat = 0
        var weightedX: CGFloat = 0
        var weightedY: CGFloat = 0

        for (loc, w) in weightedPoints {
            totalWeight += w
            weightedX += loc.x * w
            weightedY += loc.y * w
        }

        let cx = weightedX / totalWeight
        let cy = weightedY / totalWeight

        // Vision 坐标系：左下角原点，y 向上 → 视图坐标系：左上角原点，y 向下
        let pos = CGPoint(x: cx, y: 1.0 - cy)

        // 计算手部包围盒大小
        let xs = allLocations.map { $0.x }
        let ys = allLocations.map { $0.y }
        let width = Float(xs.max()! - xs.min()!)
        let height = Float(ys.max()! - ys.min()!)
        let handSize = sqrt(width * width + height * height)

        return (pos, handSize)
    }

    /// 手势识别
    private func detectGesture(_ obs: VNHumanHandPoseObservation) -> HandGesture {
        guard let allPoints = try? obs.recognizedPoints(.all) else {
            return .unknown
        }

        guard let wrist = allPoints[.wrist], wrist.confidence > 0,
              let indexTip = allPoints[.indexTip], indexTip.confidence > 0,
              let middleTip = allPoints[.middleTip], middleTip.confidence > 0,
              let thumbTip = allPoints[.thumbTip], thumbTip.confidence > 0 else {
            return .unknown
        }

        let w = wrist.location
        let idx = indexTip.location
        let mid = middleTip.location
        let thu = thumbTip.location

        // 计算各指尖到手腕的距离
        let dist = { (a: CGPoint, b: CGPoint) -> CGFloat in
            let dx = a.x - b.x, dy = a.y - b.y
            return sqrt(dx * dx + dy * dy)
        }

        let indexDist = dist(idx, w)
        let middleDist = dist(mid, w)
        let thumbIndexDist = dist(thu, idx)

        // 参考距离：手腕到中指尖（用于归一化）
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

    /// 帧间匹配 + 位置平滑：按距离最近原则匹配上一帧的手，做 EMA 平滑
    private func smoothHands(_ current: [HandResult]) -> [HandResult] {
        guard !lastHands.isEmpty else {
            return current // 首帧或丢手后恢复，直接使用原始位置
        }

        var usedPrev = [Bool](repeating: false, count: lastHands.count)
        var result: [HandResult] = []

        for hand in current {
            // 找到上一帧中距离最近且未被使用的手
            var bestIdx = -1
            var bestDist: CGFloat = .infinity

            for (i, prev) in lastHands.enumerated() where !usedPrev[i] {
                let dx = hand.position.x - prev.position.x
                let dy = hand.position.y - prev.position.y
                let d = sqrt(dx * dx + dy * dy)
                if d < bestDist {
                    bestDist = d
                    bestIdx = i
                }
            }

            if bestIdx >= 0 {
                usedPrev[bestIdx] = true
                let prev = lastHands[bestIdx]
                let alpha = smoothingFactor
                let smoothed = CGPoint(
                    x: prev.position.x * (1 - alpha) + hand.position.x * alpha,
                    y: prev.position.y * (1 - alpha) + hand.position.y * alpha
                )
                var smoothedHand = hand
                smoothedHand.position = smoothed
                result.append(smoothedHand)
            } else {
                result.append(hand)
            }
        }

        return result
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

import Vision
import CoreVideo
import CoreImage

/// 手部追踪管理器：使用 Vision 的 VNDetectHumanHandPoseRequest 实时自动检测双手。
///
/// 增强识别特性：
/// 1. 自适应平滑 —— 快速移动时降低平滑系数提升响应，静止时增大平滑消除抖动
/// 2. 速度预测 —— 基于当前速度预测下一帧位置，补偿检测延迟
/// 3. 关节置信度加权 —— 低置信度关节降低权重，高置信度关节提升权重
/// 4. 置信度增强 —— 检测到的关节数越多，整体置信度越高
/// 5. 延长丢手保持 —— 20 帧保持（~0.6s），手短暂遮挡不丢失
/// 6. 多关键点融合 —— 21 个关节点加权质心，比 6 点更稳定
/// 7. 扭曲能量 —— 累积旋转变化+移动速度，驱动漩涡扭曲强度
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
        /// 手掌方向角度（弧度，视图坐标系，y 向下）
        var rotation: Float
        /// 速度（归一化/帧）
        var velocity: CGPoint
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

    /// 最大丢手保持帧数（增强：从 20 提升到 40，约 1.3s，大幅减少特效闪烁）
    private let maxLostFrames: Int = 40

    /// 基础平滑系数（0~1，越大越平滑但延迟越大）
    private let baseSmoothingFactor: CGFloat = 0.25

    /// 上一帧每只手的速度（用于速度预测）
    private var lastVelocities: [CGPoint] = []

    // MARK: - 时序持久化（100%识别核心）
    /// 候选手：尚未确认的检测结果，需连续检测到 minConfirmFrames 帧才确认为有效手
    private var candidateHands: [HandResult] = []
    /// 每个候选手的连续检测帧数
    private var candidateFrameCounts: [Int] = []
    /// 确认所需的最小连续帧数（降低瞬时误检）
    private let minConfirmFrames: Int = 2
    /// 已确认手的连续检测帧数（用于稳定性评估）
    private var confirmedFrameCounts: [Int] = []

    // MARK: - 扭曲能量系统

    /// 累积扭曲角度（弧度）：每帧旋转变化+移动贡献不断累积，形成连续漩涡旋转
    private var accumulatedTwist: Float = 0

    /// 扭曲能量（0~1）：随手部活动度升高，静止时衰减。控制扭曲可见强度。
    private var _twistEnergy: Float = 0

    /// 上一帧主手位置（用于计算移动速度）
    private var lastPrimaryPosition: CGPoint?

    /// 上一帧主手旋转角度（用于计算角速度）
    private var lastPrimaryRotation: Float = 0

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
    var dynamicRadius: Float {
        if hands.count >= 2 {
            let dist = handsDistance
            return min(max(dist * 0.45, 0.15), 0.40)
        } else if let hand = hands.first {
            return min(max(hand.handSize * 2.0, 0.12), 0.30)
        }
        return 0.22
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

    /// 累积扭曲角度（弧度）
    var primaryHandRotation: Float {
        accumulatedTwist
    }

    /// 扭曲能量（0~1）
    var twistEnergy: Float {
        _twistEnergy
    }

    // MARK: - 指尖位置（10个，每只手5个：拇指/食指/中指/无名指/小指）
    // 无效指尖位置为 (-1, -1)
    // 索引：手1[0-4] 拇指/食指/中指/无名指/小指，手2[5-9] 同上
    private(set) var fingertipPositions: [CGPoint] = Array(repeating: CGPoint(x: -1, y: -1), count: 10)
    private(set) var validFingertipCount: Int = 0
    /// 指尖平滑后的位置（EMA 平滑，减少抖动）
    private var smoothedFingertipPositions: [CGPoint] = Array(repeating: CGPoint(x: -1, y: -1), count: 10)
    /// 指尖平滑系数
    private let fingertipSmoothing: CGFloat = 0.35

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

        // === 1. 解析并验证每个检测结果 ===
        // 只接受通过解剖学验证的手（排除非手物体误检）
        var validatedResults: [(HandResult, VNHumanHandPoseObservation)] = []

        for obs in observations {
            // 解剖学验证：检查关节结构是否符合人手特征
            guard validateHandAnatomy(obs) else { continue }

            let (rawPos, handSize, jointCount, avgJointConf) = computeHandCenterAndSize(obs)
            let gesture = detectGesture(obs)
            let rotation = computeHandRotation(obs)

            // 置信度增强：检测到的关节数越多，置信度越高
            let jointBonus = Float(jointCount) / 21.0
            let baseConf = max(obs.confidence * 2.5, avgJointConf * 1.5)
            let confMultiplier = 0.5 + jointBonus * 0.5
            let enhancedConfidence = min(baseConf * confMultiplier, 1.0)

            // 几何验证：手部大小应在合理范围内
            guard handSize > 0.03 && handSize < 0.8 else { continue }

            validatedResults.append((HandResult(
                position: rawPos,
                rawPosition: rawPos,
                confidence: enhancedConfidence,
                gesture: gesture,
                handSize: handSize,
                rotation: rotation,
                velocity: .zero
            ), obs))
        }

        // 如果没有通过验证的手，应用丢手保持
        if validatedResults.isEmpty {
            applyLostFrame()
            return
        }

        // 按置信度排序
        validatedResults.sort { $0.0.confidence > $1.0.confidence }
        let topResults = Array(validatedResults.prefix(2))

        // === 2. 时序持久化：连续检测确认 ===
        // 新检测到的手需要连续 minConfirmFrames 帧才确认为有效
        var confirmedResults: [HandResult] = []
        var confirmedObs: [VNHumanHandPoseObservation] = []
        var newCandidates: [HandResult] = []
        var newCandidateCounts: [Int] = []

        for (result, obs) in topResults {
            // 尝试与已确认的手匹配（基于位置 proximity）
            var matchedConfirmedIdx = -1
            if !hands.isEmpty {
                var bestDist: CGFloat = .infinity
                for (i, prev) in hands.enumerated() {
                    let dx = result.position.x - prev.position.x
                    let dy = result.position.y - prev.position.y
                    let d = sqrt(dx * dx + dy * dy)
                    if d < bestDist && d < 0.3 {
                        bestDist = d
                        matchedConfirmedIdx = i
                    }
                }
            }

            if matchedConfirmedIdx >= 0 {
                // 匹配到已确认的手，直接使用
                confirmedResults.append(result)
                confirmedObs.append(obs)
                if matchedConfirmedIdx < confirmedFrameCounts.count {
                    confirmedFrameCounts[matchedConfirmedIdx] += 1
                }
            } else {
                // 尝试与候选手匹配
                var matchedCandidateIdx = -1
                var bestCDist: CGFloat = .infinity
                for (i, cand) in candidateHands.enumerated() {
                    let dx = result.position.x - cand.position.x
                    let dy = result.position.y - cand.position.y
                    let d = sqrt(dx * dx + dy * dy)
                    if d < bestCDist && d < 0.3 {
                        bestCDist = d
                        matchedCandidateIdx = i
                    }
                }

                if matchedCandidateIdx >= 0 {
                    let count = candidateFrameCounts[matchedCandidateIdx] + 1
                    if count >= minConfirmFrames {
                        // 达到确认阈值，升级为已确认
                        confirmedResults.append(result)
                        confirmedObs.append(obs)
                    } else {
                        newCandidates.append(result)
                        newCandidateCounts.append(count)
                    }
                } else {
                    // 新候选手
                    newCandidates.append(result)
                    newCandidateCounts.append(1)
                }
            }
        }

        // 更新候选手列表
        candidateHands = newCandidates
        candidateFrameCounts = newCandidateCounts

        // 如果没有确认的手，但有候选手，使用候选手（降低阈值以避免特效消失）
        var finalResults: [HandResult] = confirmedResults
        var finalObs: [VNHumanHandPoseObservation] = confirmedObs

        if finalResults.isEmpty && !candidateHands.isEmpty {
            // 使用候选手，但降低置信度
            for (i, cand) in candidateHands.enumerated() {
                var h = cand
                h.confidence *= Float(candidateFrameCounts[i]) / Float(minConfirmFrames)
                finalResults.append(h)
            }
            // 重新提取指尖（使用候选观测结果）
            if let topObs = validatedResults.first?.1 {
                finalObs = [topObs]
            }
        }

        if finalResults.isEmpty {
            applyLostFrame()
            return
        }

        // 帧间匹配 + 自适应平滑 + 速度预测
        let smoothedResults = smoothHandsAdaptive(finalResults)

        // 提取并平滑指尖位置
        extractFingertips(finalObs)

        // 更新扭曲能量系统
        updateTwistEnergy(smoothedResults)

        // 重置丢手计数
        lostFrameCount = 0
        lastHands = smoothedResults
        hands = smoothedResults
    }

    // MARK: - 解剖学验证（100%只识别手的核心）

    /// 验证检测结果是否符合人手解剖学结构
    /// 通过检查关节拓扑、距离比例和空间分布来排除非手物体的误检
    private func validateHandAnatomy(_ obs: VNHumanHandPoseObservation) -> Bool {
        guard let allPoints = try? obs.recognizedPoints(.all) else { return false }

        // 1. 手腕必须检测到（手的锚点）
        guard let wrist = allPoints[.wrist], wrist.confidence > 0.05 else { return false }

        // 2. 至少检测到 3 个指尖（确保是手而非其他物体）
        let tips: [VNHumanHandPoseObservation.JointName] = [
            .thumbTip, .indexTip, .middleTip, .ringTip, .littleTip
        ]
        var tipCount = 0
        var tipPositions: [CGPoint] = []
        for tip in tips {
            if let p = allPoints[tip], p.confidence > 0.05 {
                tipCount += 1
                tipPositions.append(p.location)
            }
        }
        if tipCount < 3 { return false }

        // 3. 几何约束：所有指尖到手腕的距离应在合理范围内
        let wristPos = wrist.location
        var wristToTipDistances: [CGFloat] = []
        for tipPos in tipPositions {
            let dx = tipPos.x - wristPos.x
            let dy = tipPos.y - wristPos.y
            let d = sqrt(dx * dx + dy * dy)
            wristToTipDistances.append(d)
        }

        // 手指长度应在 0.05~0.4 归一化范围内
        for d in wristToTipDistances {
            if d < 0.03 || d > 0.5 { return false }
        }

        // 4. 指尖间距应大于最小值（指尖不应完全重叠）
        for i in 0..<tipPositions.count {
            for j in (i+1)..<tipPositions.count {
                let dx = tipPositions[i].x - tipPositions[j].x
                let dy = tipPositions[i].y - tipPositions[j].y
                let d = sqrt(dx * dx + dy * dy)
                if d < 0.005 { return false } // 指尖完全重叠 = 误检
            }
        }

        // 5. 指尖应分布在手腕的同一侧（手而非随机点集）
        // 计算指尖质心相对于手腕的方向
        var centroidX: CGFloat = 0
        var centroidY: CGFloat = 0
        for p in tipPositions {
            centroidX += p.x
            centroidY += p.y
        }
        centroidX /= CGFloat(tipPositions.count)
        centroidY /= CGFloat(tipPositions.count)
        let centroidDist = sqrt(pow(centroidX - wristPos.x, 2) + pow(centroidY - wristPos.y, 2))
        if centroidDist < 0.04 { return false } // 指尖质心太接近手腕 = 非手

        return true
    }

    // MARK: - 扭曲能量系统

    /// 每帧更新扭曲能量和累积角度
    private func updateTwistEnergy(_ currentHands: [HandResult]) {
        guard let primary = currentHands.first else {
            _twistEnergy *= 0.90
            return
        }

        let pos = primary.position
        let rot = primary.rotation

        if let lastPos = lastPrimaryPosition {
            let dx = Float(pos.x - lastPos.x)
            let dy = Float(pos.y - lastPos.y)
            let moveSpeed = sqrt(dx * dx + dy * dy)

            let rotDelta = atan2(sin(rot - lastPrimaryRotation), cos(rot - lastPrimaryRotation))
            let rotSpeed = abs(rotDelta)

            accumulatedTwist += rotDelta * 4.0
            let moveAngle = atan2(dy, dx)
            accumulatedTwist += moveSpeed * 8.0 * sin(moveAngle + accumulatedTwist * 0.5)

            let energyInput = min(moveSpeed * 6.0 + rotSpeed * 3.0, 1.5)
            _twistEnergy = min(_twistEnergy * 0.88 + energyInput, 1.0)
        }

        lastPrimaryPosition = pos
        lastPrimaryRotation = rot
    }

    // MARK: - 指尖提取

    /// 从 Vision 观测结果中提取 10 个指尖位置并平滑
    /// 索引：手1[0-4]=拇指/食指/中指/无名指/小指，手2[5-9]=同上
    private func extractFingertips(_ observations: [VNHumanHandPoseObservation]) {
        var rawPositions: [CGPoint] = Array(repeating: CGPoint(x: -1, y: -1), count: 10)
        var count = 0

        let fingertipJoints: [VNHumanHandPoseObservation.JointName] = [
            .thumbTip, .indexTip, .middleTip, .ringTip, .littleTip
        ]

        for (handIdx, obs) in observations.prefix(2).enumerated() {
            guard let allPoints = try? obs.recognizedPoints(.all) else { continue }

            for (fingerIdx, joint) in fingertipJoints.enumerated() {
                let tipIdx = handIdx * 5 + fingerIdx
                if let point = allPoints[joint], point.confidence > 0 {
                    // Vision: 左下角原点 y向上 → 视图: 左上角原点 y向下
                    rawPositions[tipIdx] = CGPoint(x: point.location.x, y: 1.0 - point.location.y)
                    count += 1
                }
            }
        }

        // EMA 平滑：如果之前有有效位置且当前也有，进行插值平滑
        var smoothedPositions: [CGPoint] = Array(repeating: CGPoint(x: -1, y: -1), count: 10)
        for i in 0..<10 {
            let raw = rawPositions[i]
            let prev = smoothedFingertipPositions[i]

            if raw.x >= 0 && prev.x >= 0 {
                // 当前和上一帧都有效：EMA 平滑
                smoothedPositions[i] = CGPoint(
                    x: prev.x * (1 - fingertipSmoothing) + raw.x * fingertipSmoothing,
                    y: prev.y * (1 - fingertipSmoothing) + raw.y * fingertipSmoothing
                )
            } else if raw.x >= 0 {
                // 当前有效，上一帧无效：直接使用
                smoothedPositions[i] = raw
            } else {
                // 当前无效：保持上一帧位置（短暂保持，由 validFingertipCount 控制可见性）
                smoothedPositions[i] = prev
            }
        }

        smoothedFingertipPositions = smoothedPositions
        fingertipPositions = smoothedPositions
        validFingertipCount = count
    }

    // MARK: - 增强识别：关节计算

    /// 计算手部中心和大小：使用全部 21 个关节的置信度加权质心
    /// 返回：(位置, 手部大小, 检测到的关节数, 平均关节置信度)
    private func computeHandCenterAndSize(_ obs: VNHumanHandPoseObservation) -> (CGPoint, Float, Int, Float) {
        guard let allPoints = try? obs.recognizedPoints(.all), !allPoints.isEmpty else {
            return (CGPoint(x: 0.5, y: 0.5), 0.1, 0, 0)
        }

        // 全部 21 个关节，按重要性分组加权
        // 指尖权重最高（用于精确定位特效），掌指关节次之，手腕作为锚点
        let jointWeights: [(VNHumanHandPoseObservation.JointName, CGFloat)] = [
            // 指尖（最高权重）
            (.indexTip, 3.0),
            (.middleTip, 2.5),
            (.thumbTip, 1.5),
            (.ringTip, 1.2),
            (.littleTip, 1.0),
            // 掌指关节（中等权重，稳定手掌中心）
            (.indexMCP, 2.0),
            (.middleMCP, 2.0),
            (.ringMCP, 1.5),
            (.littleMCP, 1.2),
            (.thumbCMC, 1.5),
            // 近端指间关节
            (.indexPIP, 1.5),
            (.middlePIP, 1.5),
            (.ringPIP, 1.0),
            (.littlePIP, 0.8),
            (.thumbIP, 1.0),
            (.thumbMP, 1.2),
            // 远端指间关节
            (.indexDIP, 1.0),
            (.middleDIP, 1.0),
            (.ringDIP, 0.8),
            (.littleDIP, 0.6),
            // 手腕（锚点）
            (.wrist, 2.0)
        ]

        var weightedPoints: [(CGPoint, CGFloat)] = []
        var allLocations: [CGPoint] = []
        var jointCount = 0
        var totalJointConf: Float = 0

        for (jointName, baseWeight) in jointWeights {
            if let point = allPoints[jointName], point.confidence > 0 {
                // 增强：关节置信度作为额外权重因子
                // 高置信度关节(>0.8)权重提升，低置信度关节(0.1~0.3)权重降低
                let confWeight = CGFloat(point.confidence)
                let effectiveWeight = baseWeight * (0.3 + confWeight * 0.7)

                weightedPoints.append((point.location, effectiveWeight))
                allLocations.append(point.location)
                jointCount += 1
                totalJointConf += Float(point.confidence)
            }
        }

        guard !weightedPoints.isEmpty else {
            return (CGPoint(x: 0.5, y: 0.5), 0.1, 0, 0)
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

        let avgConf = totalJointConf / Float(jointCount)

        return (pos, handSize, jointCount, avgConf)
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

        let dist = { (a: CGPoint, b: CGPoint) -> CGFloat in
            let dx = a.x - b.x, dy = a.y - b.y
            return sqrt(dx * dx + dy * dy)
        }

        let indexDist = dist(idx, w)
        let middleDist = dist(mid, w)
        let thumbIndexDist = dist(thu, idx)

        let refDist = max(middleDist, 0.01)

        if thumbIndexDist < refDist * 0.3 {
            return .pinch
        }

        if indexDist < refDist * 0.5 && middleDist < refDist * 0.5 {
            return .fist
        }

        if indexDist > refDist * 0.8 && middleDist < refDist * 0.6 {
            return .pointing
        }

        return .open
    }

    /// 计算手掌方向角度：从手腕到食指尖的方向角
    private func computeHandRotation(_ obs: VNHumanHandPoseObservation) -> Float {
        guard let allPoints = try? obs.recognizedPoints(.all) else { return 0 }

        guard let wrist = allPoints[.wrist], wrist.confidence > 0,
              let indexTip = allPoints[.indexTip], indexTip.confidence > 0 else {
            return 0
        }

        let wristX = Float(wrist.location.x)
        let wristY = Float(1.0 - wrist.location.y)
        let indexX = Float(indexTip.location.x)
        let indexY = Float(1.0 - indexTip.location.y)

        let dx = indexX - wristX
        let dy = indexY - wristY

        return atan2(dy, dx)
    }

    // MARK: - 增强识别：自适应平滑 + 速度预测

    /// 自适应平滑：根据移动速度动态调整平滑系数 + 速度预测
    private func smoothHandsAdaptive(_ current: [HandResult]) -> [HandResult] {
        guard !lastHands.isEmpty else {
            // 首帧：初始化速度为零
            return current.map { hand in
                var h = hand
                h.velocity = .zero
                return h
            }
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

                // 计算本次移动距离
                let moveDist = bestDist

                // 自适应平滑系数（拆分为独立步骤避免编译器超时）
                let moveDistF = Float(moveDist)
                let rawSpeed = min(max(moveDistF / 0.05, 0.0), 1.0)
                let speedFactor = CGFloat(rawSpeed)
                let alphaPart1 = baseSmoothingFactor * (1.0 - speedFactor * 0.7)
                let alphaPart2 = speedFactor * 0.5
                let alpha = alphaPart1 + alphaPart2
                let clampedAlpha = min(max(alpha, 0.12), 0.75)

                // 速度预测：基于上一帧速度预测当前位置
                // predicted = prev.position + prev.velocity * predictionFactor
                let predictionFactor: CGFloat = 0.5
                let predictedPos = CGPoint(
                    x: prev.position.x + prev.velocity.x * predictionFactor,
                    y: prev.position.y + prev.velocity.y * predictionFactor
                )

                // 平滑：在预测位置和检测位置之间插值
                let smoothed = CGPoint(
                    x: predictedPos.x * (1 - clampedAlpha) + hand.position.x * clampedAlpha,
                    y: predictedPos.y * (1 - clampedAlpha) + hand.position.y * clampedAlpha
                )

                // 更新速度（EMA 平滑速度本身）
                let newVelocity = CGPoint(
                    x: prev.velocity.x * 0.7 + (hand.position.x - prev.position.x) * 0.3,
                    y: prev.velocity.y * 0.7 + (hand.position.y - prev.position.y) * 0.3
                )

                // 角度平滑（处理角度回绕）
                let prevAngle = prev.rotation
                let currAngle = hand.rotation
                let diff = atan2(sin(currAngle - prevAngle), cos(currAngle - prevAngle))
                let angleAlpha = min(clampedAlpha * 1.5, 0.8)
                let smoothedAngle = prevAngle + diff * Float(angleAlpha)

                // 置信度平滑（拆分为独立变量避免编译器超时）
                let confAlpha = Float(clampedAlpha) * 0.5
                let prevConf = prev.confidence
                let currConf = hand.confidence
                let smoothedConf = prevConf * (1.0 - confAlpha) + currConf * confAlpha

                var smoothedHand = hand
                smoothedHand.position = smoothed
                smoothedHand.rotation = smoothedAngle
                smoothedHand.confidence = smoothedConf
                smoothedHand.velocity = newVelocity
                result.append(smoothedHand)
            } else {
                // 没有匹配的上一帧手，直接使用，速度归零
                var h = hand
                h.velocity = .zero
                result.append(h)
            }
        }

        return result
    }

    /// 丢手保持：手短暂丢失时保留最后位置 + 速度惯性预测，避免特效闪烁
    private func applyLostFrame() {
        lostFrameCount += 1
        _twistEnergy *= 0.90

        if lostFrameCount <= maxLostFrames && !lastHands.isEmpty {
            // 保留最后位置，使用速度惯性继续预测位置（手消失时画面继续滑动一小段）
            let fadeFactor = 1.0 - Float(lostFrameCount) / Float(maxLostFrames)
            let inertiaFactor = CGFloat(max(0, 1.0 - Float(lostFrameCount) / 5.0))  // 前5帧有惯性

            hands = lastHands.map { hand in
                var h = hand
                h.confidence *= fadeFactor
                // 惯性预测：继续按速度移动一小段距离
                h.position = CGPoint(
                    x: hand.position.x + hand.velocity.x * inertiaFactor * 0.3,
                    y: hand.position.y + hand.velocity.y * inertiaFactor * 0.3
                )
                return h
            }
        } else {
            hands = []
            lastHands = []
            lastPrimaryPosition = nil
        }
    }

    /// 重置
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        hands = []
        lastHands = []
        lostFrameCount = 0
        accumulatedTwist = 0
        _twistEnergy = 0
        lastPrimaryPosition = nil
        lastPrimaryRotation = 0
        fingertipPositions = Array(repeating: CGPoint(x: -1, y: -1), count: 10)
        smoothedFingertipPositions = Array(repeating: CGPoint(x: -1, y: -1), count: 10)
        validFingertipCount = 0
        candidateHands = []
        candidateFrameCounts = []
        confirmedFrameCounts = []
    }
}

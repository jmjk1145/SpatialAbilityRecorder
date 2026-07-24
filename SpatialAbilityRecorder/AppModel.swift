import SwiftUI
import AVFoundation

/// 全局应用状态：协调相机、手部追踪、特效渲染与录制之间的数据流。
///
/// 默认使用自动手部识别模式（VNDetectHumanHandPoseRequest），
/// 实时检测双手并智能定位特效。支持手动点击覆盖。
final class AppModel: ObservableObject {

    let cameraManager = CameraManager()
    let handTrackingManager = HandTrackingManager()
    let recordingManager = RecordingManager()
    let renderer = EffectRenderer()

    @Published var isRecording = false
    @Published var isTrackingActive = false
    @Published var trackedPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published var secondaryHandPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)  // 第二只手位置
    @Published var trackedConfidence: Float = 0
    @Published var statusMessage = "举起手部即可自动识别"
    @Published var hasTrackedPoint = false
    @Published var handCount: Int = 0  // 当前检测到的手数
    @Published var currentGestureName: String = ""  // 当前手势名称
    @Published var currentGestureIcon: String = ""  // 当前手势图标

    // 特效管理
    @Published var currentEffectIndex: Int = 0
    @Published var isUsingFrontCamera = false

    /// 特效名称列表（与 shader 中 effectType 对应）
    let effectNames: [String] = ["空间裂缝", "能量护盾", "烈焰能量", "闪电链", "黑洞引力"]
    let effectIcons: [String] = ["bolt.fill", "shield.lefthalf.filled", "flame.fill", "bolt.slash.fill", "circle.dashed"]

    init() {
        bindPipeline()
    }

    /// 组装数据流：相机帧 → 手部追踪 → 渲染器属性 → MTKView 驱动绘制 → 录制
    private func bindPipeline() {
        // 相机交付新帧 → 更新手部追踪 + 将最新帧推入渲染器
        cameraManager.onFrame = { [weak self] sampleBuffer, pixelBuffer in
            guard let self = self else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // 1. 更新手部追踪（自动识别双手）
            self.handTrackingManager.update(with: pixelBuffer, time: time)

            // 2. 将追踪结果推入渲染器（手势调节强度）
            let baseConfidence = self.handTrackingManager.overallConfidence
            let gesture = self.handTrackingManager.primaryGesture
            let intensityMultiplier = self.gestureIntensityMultiplier(gesture)
            let adjustedConfidence = min(baseConfidence * intensityMultiplier, 1.0)

            self.renderer.latestCameraBuffer = pixelBuffer
            self.renderer.latestFrameTime = time
            self.renderer.hand1Point = self.handTrackingManager.primaryHandPosition
            self.renderer.hand2Point = self.handTrackingManager.hands.count >= 2
                ? self.handTrackingManager.hands[1].position
                : self.handTrackingManager.primaryHandPosition
            self.renderer.hasHand2 = self.handTrackingManager.hasBothHands
            self.renderer.confidence = adjustedConfidence
            self.renderer.effectRadius = self.handTrackingManager.dynamicRadius
            self.renderer.handRotation = self.handTrackingManager.primaryHandRotation
            self.renderer.twistEnergy = self.handTrackingManager.twistEnergy
            self.renderer.setTrackingActive(self.handTrackingManager.hasHand)

            // 3. 追踪结果回主线程更新 UI
            let handCount = self.handTrackingManager.hands.count
            let conf = self.handTrackingManager.overallConfidence
            let primaryPos = self.handTrackingManager.primaryHandPosition
            let secondaryPos = self.handTrackingManager.hands.count >= 2
                ? self.handTrackingManager.hands[1].position
                : primaryPos
            let hasBoth = self.handTrackingManager.hasBothHands
            let (gestureName, gestureIcon) = self.gestureDisplayInfo(gesture)

            DispatchQueue.main.async {
                self.handCount = handCount
                self.trackedConfidence = conf
                self.trackedPoint = primaryPos
                self.secondaryHandPoint = secondaryPos
                self.currentGestureName = gestureName
                self.currentGestureIcon = gestureIcon

                if handCount > 0 {
                    self.hasTrackedPoint = true
                    self.isTrackingActive = true
                    if hasBoth {
                        self.statusMessage = "双手识别中 · 闪电连接已激活"
                    } else if !gestureName.isEmpty {
                        self.statusMessage = "\(gestureName) · \(Int(conf * 100))% 置信度"
                    } else {
                        self.statusMessage = "单手识别中 · \(Int(conf * 100))% 置信度"
                    }
                } else {
                    self.hasTrackedPoint = false
                    self.isTrackingActive = false
                    self.statusMessage = "举起手部即可自动识别"
                }
            }
        }

        // 摄像头切换回调
        cameraManager.onCameraSwitched = { [weak self] isFront in
            DispatchQueue.main.async {
                self?.isUsingFrontCamera = isFront
                self?.renderer.isFrontCamera = isFront
                self?.statusMessage = isFront ? "已切换至前置摄像头" : "已切换至后置摄像头"
            }
        }

        // 渲染器完成一帧后 → 录制
        renderer.recordingCallback = { [weak self] pixelBuffer, time in
            guard let self = self, self.isRecording else { return }
            self.recordingManager.appendVideoFrame(pixelBuffer, time: time)
        }
    }

    // MARK: - 用户交互

    /// 手动点击覆盖（可选）：设置手动追踪锚点
    func setTrackingAnchor(normalizedPoint: CGPoint) {
        // 在自动模式下，手动点击可以临时覆盖特效位置
        DispatchQueue.main.async {
            self.hasTrackedPoint = true
            self.isTrackingActive = true
            self.trackedPoint = normalizedPoint
            self.trackedConfidence = 1.0
            self.statusMessage = "手动锚点已设置 · 举起新手部恢复自动"
        }
    }

    // MARK: - 手势智能

    /// 根据手势调节特效强度倍数
    private func gestureIntensityMultiplier(_ gesture: HandTrackingManager.HandGesture) -> Float {
        switch gesture {
        case .pinch:    return 1.5  // 捏合 → 能量集中，强度增强
        case .pointing: return 1.3  // 指向 → 聚焦光束
        case .open:     return 1.0  // 张开 → 正常强度
        case .fist:     return 0.6  // 握拳 → 能量压缩，降低显示
        case .unknown:  return 1.0
        }
    }

    /// 手势对应的显示名称和 SF Symbol 图标
    private func gestureDisplayInfo(_ gesture: HandTrackingManager.HandGesture) -> (String, String) {
        switch gesture {
        case .open:     return ("张开手掌", "hand.raised.fill")
        case .fist:     return ("握拳", "hand.raised.fill")
        case .pinch:    return ("捏合手势", "hand.point.up.left.fill")
        case .pointing: return ("指向手势", "hand.point.up.fill")
        case .unknown:  return ("", "")
        }
    }

    /// 重置追踪
    func resetTracking() {
        handTrackingManager.reset()
        renderer.setTrackingActive(false)
        DispatchQueue.main.async {
            self.hasTrackedPoint = false
            self.isTrackingActive = false
            self.trackedConfidence = 0
            self.handCount = 0
            self.currentGestureName = ""
            self.currentGestureIcon = ""
            self.statusMessage = "举起手部即可自动识别"
        }
    }

    /// 切换前后摄像头
    func switchCamera() {
        resetTracking()
        cameraManager.switchCamera()
    }

    /// 切换到下一个特效（循环）
    func switchEffect() {
        let next = (currentEffectIndex + 1) % effectNames.count
        currentEffectIndex = next
        renderer.effectType = Int32(next)
        DispatchQueue.main.async {
            self.statusMessage = "特效：\(self.effectNames[next])"
        }
    }

    /// 切换到上一个特效（循环）
    func switchEffectPrevious() {
        let prev = (currentEffectIndex - 1 + effectNames.count) % effectNames.count
        currentEffectIndex = prev
        renderer.effectType = Int32(prev)
        DispatchQueue.main.async {
            self.statusMessage = "特效：\(self.effectNames[prev])"
        }
    }

    func toggleRecording() {
        if isRecording {
            recordingManager.stop { url in
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.statusMessage = "已保存至相册：\(url.lastPathComponent)"
                }
            }
        } else {
            let size = renderer.outputSize
            recordingManager.start(videoSize: size) { success in
                DispatchQueue.main.async {
                    if success {
                        self.isRecording = true
                        self.statusMessage = "录制中…"
                    } else {
                        self.statusMessage = "录制启动失败，请检查相册权限"
                    }
                }
            }
        }
    }

    func startSession() {
        cameraManager.startSession()
    }

    func stopSession() {
        cameraManager.stopSession()
    }
}

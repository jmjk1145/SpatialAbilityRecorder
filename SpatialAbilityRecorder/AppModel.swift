import SwiftUI
import AVFoundation

/// 全局应用状态：协调相机、追踪、特效渲染与录制之间的数据流。
final class AppModel: ObservableObject {

    let cameraManager = CameraManager()
    let trackingManager = TrackingManager()
    let recordingManager = RecordingManager()
    let renderer = EffectRenderer()

    @Published var isRecording = false
    @Published var isTrackingActive = false
    @Published var trackedPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published var trackedConfidence: Float = 0
    @Published var statusMessage = "点击屏幕选择空间锚点"
    @Published var hasTrackedPoint = false

    init() {
        bindPipeline()
    }

    /// 组装数据流：相机帧 → 追踪 → 渲染器属性 → MTKView 驱动绘制 → 录制
    private func bindPipeline() {
        // 相机交付新帧 → 更新追踪 + 将最新帧推入渲染器
        cameraManager.onFrame = { [weak self] sampleBuffer, pixelBuffer in
            guard let self = self else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // 1. 更新追踪（同步执行，更新 lastTrackedPointNormalized）
            self.trackingManager.update(with: pixelBuffer, time: time)

            // 2. 将最新帧数据推入渲染器（MTKView 的 draw 循环会读取）
            self.renderer.latestCameraBuffer = pixelBuffer
            self.renderer.latestFrameTime = time
            self.renderer.trackedPoint = self.trackingManager.lastTrackedPointNormalized
            self.renderer.confidence = self.trackingManager.lastConfidence

            // 3. 追踪结果回主线程更新 UI
            let point = self.trackingManager.lastTrackedPointNormalized
            let conf = self.trackingManager.lastConfidence
            DispatchQueue.main.async {
                self.trackedPoint = point
                self.trackedConfidence = conf
                if conf < 0.3 && self.isTrackingActive {
                    self.isTrackingActive = false
                    self.renderer.setTrackingActive(false)
                    self.statusMessage = "追踪丢失，请重新点击锚点"
                }
            }
        }

        // 渲染器完成一帧后 → 录制
        renderer.recordingCallback = { [weak self] pixelBuffer, time in
            guard let self = self, self.isRecording else { return }
            self.recordingManager.appendVideoFrame(pixelBuffer, time: time)
        }
    }

    // MARK: - 用户交互

    /// 用户在预览上点击，设置追踪锚点（手动追踪的起点）
    func setTrackingAnchor(normalizedPoint: CGPoint) {
        trackingManager.startTracking(at: normalizedPoint)
        renderer.setTrackingActive(true)
        DispatchQueue.main.async {
            self.hasTrackedPoint = true
            self.isTrackingActive = true
            self.trackedPoint = normalizedPoint
            self.trackedConfidence = 1.0
            self.statusMessage = "空间锚点已锁定"
        }
    }

    /// 重置追踪
    func resetTracking() {
        trackingManager.stopTracking()
        renderer.setTrackingActive(false)
        DispatchQueue.main.async {
            self.hasTrackedPoint = false
            self.isTrackingActive = false
            self.trackedConfidence = 0
            self.statusMessage = "点击屏幕选择空间锚点"
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

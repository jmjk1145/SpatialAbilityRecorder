import Vision
import CoreVideo
import CoreImage

/// 手动追踪管理器：用户点击设置锚点后，用 Vision 逐帧追踪该目标区域。
///
/// 实现思路：将点击点转为一个小的检测框，作为 `VNTrackObjectRequest` 的初始观测；
/// 每一帧用上一帧的观测结果更新请求，得到新的边界框，取其中心作为追踪点。
final class TrackingManager {

    /// 追踪结果回调（归一化坐标 + 置信度）
    var onTrackUpdate: ((CGPoint, Float) -> Void)?

    /// 最近一次追踪到的归一化点（Vision 坐标系：左下角原点，y 向上）
    private(set) var lastTrackedPointNormalized: CGPoint = CGPoint(x: 0.5, y: 0.5)

    /// 最近一次追踪置信度
    private(set) var lastConfidence: Float = 0.0

    private var trackingRequest: VNTrackObjectRequest?
    private var lastObservation: VNDetectedObjectObservation?
    private var isTracking = false
    private let visionQueue = DispatchQueue(label: "com.spatialability.vision", qos: .userInitiated)

    /// 锚点框的归一化半边长（点击后生成的初始检测框大小）
    private let anchorHalfSize: CGFloat = 0.08

    /// 启动追踪：用户点击点（视图坐标系，左上角原点）转为 Vision 归一化坐标
    func startTracking(at viewNormalizedPoint: CGPoint) {
        // viewNormalizedPoint: x,y ∈ [0,1]，原点在左上角
        // Vision 坐标系原点在左下角，y 向上 → 翻转 y
        let visionPoint = CGPoint(x: viewNormalizedPoint.x, y: 1.0 - viewNormalizedPoint.y)

        let bbox = CGRect(x: visionPoint.x - anchorHalfSize,
                          y: visionPoint.y - anchorHalfSize,
                          width: anchorHalfSize * 2,
                          height: anchorHalfSize * 2)

        let observation = VNDetectedObjectObservation(boundingBox: bbox)
        lastObservation = observation
        trackingRequest = VNTrackObjectRequest(detectedObjectObservation: observation)
        trackingRequest?.trackingLevel = .accurate
        isTracking = true

        lastTrackedPointNormalized = visionPoint
        lastConfidence = 1.0
        onTrackUpdate?(viewNormalizedPoint, 1.0)
    }

    /// 每帧调用：用新图像更新追踪
    func update(with pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard isTracking, let request = trackingRequest else { return }

        // 复用上一帧观测结果
        request.inputObservation = lastObservation ?? request.inputObservation

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let result = request.results?.first as? VNDetectedObjectObservation else {
            return
        }

        lastObservation = result
        let confidence = result.confidence
        lastConfidence = confidence

        // 取边界框中心
        let center = CGPoint(x: result.boundingBox.midX,
                             y: result.boundingBox.midY)

        // Vision 坐标 → 视图坐标（翻转 y）
        let viewPoint = CGPoint(x: center.x, y: 1.0 - center.y)
        lastTrackedPointNormalized = viewPoint
        onTrackUpdate?(viewPoint, confidence)

        // 置信度过低则停止
        if confidence < 0.2 {
            isTracking = false
        }
    }

    func stopTracking() {
        isTracking = false
        trackingRequest = nil
        lastObservation = nil
        lastConfidence = 0.0
    }
}

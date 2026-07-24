import MetalKit
import CoreVideo
import CoreMedia
import AVFoundation

/// 与 Metal 着色器中 PortalParams 结构体完全对应的 Swift 端定义（逐字段对应，保证内存布局一致）。
struct PortalParams {
    var centerX: Float
    var centerY: Float
    var time: Float
    var aspect: Float
    var radius: Float
    var intensity: Float
    var effectType: Int32   // 0传送门 1护盾 2烈焰 3闪电 4黑洞
    var _pad0: Float = 0
    var _pad1: Float = 0
    var _pad2: Float = 0
}

/// 包装 CVMetalTexture + MTLTexture，确保 CVMetalTexture 在命令缓冲执行期间不被释放。
/// MTLTexture 由 CVMetalTexture 持有，若 CVMetalTexture 过早释放会导致 MTLTexture 失效。
private final class TextureRef {
    let cvTexture: CVMetalTexture
    let texture: MTLTexture
    init(cvTexture: CVMetalTexture, texture: MTLTexture) {
        self.cvTexture = cvTexture
        self.texture = texture
    }
}

/// Metal 渲染器：将相机帧 + 空间异能传送门特效渲染到离屏 CVPixelBuffer，
/// 再通过简单纹理拷贝绘制到 MTKView 的 drawable。录制使用离屏 CVPixelBuffer。
final class EffectRenderer: NSObject, MTKViewDelegate {

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private var portalPipeline: MTLRenderPipelineState!
    private var blitPipeline: MTLRenderPipelineState!
    private var textureCache: CVMetalTextureCache!

    // 离屏渲染目标池
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0

    // 最新相机帧数据（由 AppModel 在相机回调中更新）
    var latestCameraBuffer: CVPixelBuffer?
    var trackedPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var confidence: Float = 0
    var latestFrameTime: CMTime = .invalid
    var effectType: Int32 = 0   // 0传送门 1护盾 2烈焰 3闪电 4黑洞

    /// 渲染完成回调，返回可用于录制的 CVPixelBuffer 及其时间戳
    var recordingCallback: ((CVPixelBuffer, CMTime) -> Void)?

    /// 输出尺寸（跟随相机）
    var outputSize: CGSize = CGSize(width: 720, height: 1280)

    // 去重：仅录制新帧
    private var lastRecordedTime: CMTime = .invalid

    // drawable 尺寸仅初始化一次
    private var drawableSizeInitialized = false

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        super.init()
        setupPipelines()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    // MARK: - 管线初始化

    private func setupPipelines() {
        guard let library = device.makeDefaultLibrary() else {
            assertionFailure("无法加载 Metal 着色器库，请确认 PortalShader.metal 已加入编译目标")
            return
        }
        let vertexFunc = library.makeFunction(name: "quad_vertex")

        // 传送门特效管线
        let portalDesc = MTLRenderPipelineDescriptor()
        portalDesc.vertexFunction = vertexFunc
        portalDesc.fragmentFunction = library.makeFunction(name: "portal_fragment")
        portalDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        portalPipeline = try? device.makeRenderPipelineState(descriptor: portalDesc)

        // 纹理拷贝管线
        let blitDesc = MTLRenderPipelineDescriptor()
        blitDesc.vertexFunction = vertexFunc
        blitDesc.fragmentFunction = library.makeFunction(name: "blit_fragment")
        blitDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        blitPipeline = try? device.makeRenderPipelineState(descriptor: blitDesc)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // drawable 尺寸由 CameraPreviewView 设置为相机输出尺寸，此处无需处理
    }

    func draw(in view: MTKView) {
        guard let cameraBuffer = latestCameraBuffer,
              portalPipeline != nil,
              blitPipeline != nil else { return }

        let width = CVPixelBufferGetWidth(cameraBuffer)
        let height = CVPixelBufferGetHeight(cameraBuffer)
        outputSize = CGSize(width: CGFloat(width), height: CGFloat(height))

        // 首帧时设置 drawable 尺寸（仅一次，避免每帧重设导致性能问题）
        if !drawableSizeInitialized {
            view.drawableSize = CGSize(width: width, height: height)
            drawableSizeInitialized = true
        }

        ensurePool(width: width, height: height)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let drawable = view.currentDrawable,
              let cameraTexRef = makeTextureRef(from: cameraBuffer, width: width, height: height),
              let offscreenBuffer = dequeueOffscreenBuffer(),
              let offscreenTexRef = makeTextureRef(from: offscreenBuffer, width: width, height: height) else {
            return
        }

        let cameraTexture = cameraTexRef.texture
        let offscreenTexture = offscreenTexRef.texture
        let time = latestFrameTime
        let animTime = Float(CACurrentMediaTime())

        // ---- 1. 渲染传送门特效到离屏纹理 ----
        let portalPass = MTLRenderPassDescriptor()
        portalPass.colorAttachments[0].texture = offscreenTexture
        portalPass.colorAttachments[0].loadAction = .dontCare
        portalPass.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: portalPass) {
            encoder.setRenderPipelineState(portalPipeline)
            encoder.setFragmentTexture(cameraTexture, index: 0)

            var params = PortalParams(
                centerX: Float(trackedPoint.x),
                centerY: Float(trackedPoint.y),
                time: animTime,
                aspect: Float(width) / Float(height),
                radius: 0.18,
                intensity: confidence > 0.3 ? confidence : 0.0,
                effectType: effectType
            )
            if !hasActiveTracking {
                // 未追踪时不显示特效（intensity = 0）
                params.intensity = 0
            }
            encoder.setFragmentBytes(&params, length: MemoryLayout<PortalParams>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // ---- 2. 将离屏纹理拷贝到 drawable ----
        let blitPass = MTLRenderPassDescriptor()
        blitPass.colorAttachments[0].texture = drawable.texture
        blitPass.colorAttachments[0].loadAction = .dontCare
        blitPass.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: blitPass) {
            encoder.setRenderPipelineState(blitPipeline)
            encoder.setFragmentTexture(offscreenTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // 保留 TextureRef（内含 CVMetalTexture）直到命令缓冲完成，防止纹理过早失效
        let retainedRefs = [cameraTexRef, offscreenTexRef]
        commandBuffer.addCompletedHandler { [weak self] _ in
            _ = retainedRefs // 防止 CVMetalTexture 过早释放
            guard let self = self else { return }
            // 仅录制新帧
            if self.recordingCallback != nil,
               time != self.lastRecordedTime,
               time.isValid {
                self.lastRecordedTime = time
                self.recordingCallback?(offscreenBuffer, time)
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - 追踪状态

    private var hasActiveTracking: Bool = true

    /// AppModel 设置追踪是否激活
    func setTrackingActive(_ active: Bool) {
        hasActiveTracking = active
    }

    // MARK: - 纹理与缓冲池

    private func makeTextureRef(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> TextureRef? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTex = cvTexture,
              let mtlTex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return TextureRef(cvTexture: cvTex, texture: mtlTex)
    }

    private func ensurePool(width: Int, height: Int) {
        guard width != poolWidth || height != poolHeight || pixelBufferPool == nil else { return }

        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &newPool)
        pixelBufferPool = newPool
        poolWidth = width
        poolHeight = height
    }

    private func dequeueOffscreenBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }
}

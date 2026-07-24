import MetalKit
import CoreVideo
import CoreMedia
import AVFoundation

/// 与 Metal 着色器中 PortalParams 结构体完全对应的 Swift 端定义（逐字段对应，保证内存布局一致）。
struct PortalParams {
    var center1X: Float       // 第一只手 x
    var center1Y: Float       // 第一只手 y
    var center2X: Float       // 第二只手 x
    var center2Y: Float       // 第二只手 y
    var hasHand2: Float       // 是否有第二只手 (0 或 1)
    var time: Float
    var aspect: Float
    var radius: Float
    var intensity: Float
    var effectType: Int32     // 0空间裂缝 1护盾 2烈焰 3闪电 4黑洞
    var isFrontCamera: Int32  // 0后置 1前置
    var _pad0: Float = 0
    var _pad1: Float = 0
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
    private var blitFlippedPipeline: MTLRenderPipelineState!
    private var textureCache: CVMetalTextureCache!

    // 离屏渲染目标池
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0

    // 最新相机帧数据（由 AppModel 在相机回调中更新）
    var latestCameraBuffer: CVPixelBuffer?
    var hand1Point: CGPoint = CGPoint(x: 0.5, y: 0.5)   // 第一只手位置
    var hand2Point: CGPoint = CGPoint(x: 0.5, y: 0.5)   // 第二只手位置
    var hasHand2: Bool = false                           // 是否检测到第二只手
    var confidence: Float = 0
    var latestFrameTime: CMTime = .invalid
    var effectType: Int32 = 0   // 0空间裂缝 1护盾 2烈焰 3闪电 4黑洞
    var isFrontCamera: Bool = false  // 当前是否使用前置摄像头
    var effectRadius: Float = 0.18  // 动态特效半径（由 HandTrackingManager 计算）

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

        // 纹理拷贝管线（预览：正常方向）
        let blitDesc = MTLRenderPipelineDescriptor()
        blitDesc.vertexFunction = vertexFunc
        blitDesc.fragmentFunction = library.makeFunction(name: "blit_fragment")
        blitDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        blitPipeline = try? device.makeRenderPipelineState(descriptor: blitDesc)

        // Y 翻转纹理拷贝管线（录制：Metal 底左原点 → 视频顶左原点）
        let blitFlippedDesc = MTLRenderPipelineDescriptor()
        blitFlippedDesc.vertexFunction = vertexFunc
        blitFlippedDesc.fragmentFunction = library.makeFunction(name: "blit_flipped_fragment")
        blitFlippedDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        blitFlippedPipeline = try? device.makeRenderPipelineState(descriptor: blitFlippedDesc)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // drawable 尺寸由 CameraPreviewView 设置为相机输出尺寸，此处无需处理
    }

    func draw(in view: MTKView) {
        guard let cameraBuffer = latestCameraBuffer,
              portalPipeline != nil,
              blitPipeline != nil else { return }

        // 相机 buffer 为竖屏 720x1280（AVFoundation 已旋转）
        let camWidth = CVPixelBufferGetWidth(cameraBuffer)   // 720
        let camHeight = CVPixelBufferGetHeight(cameraBuffer)  // 1280

        // 渲染目标与相机 buffer 尺寸一致（竖屏 720x1280）
        let renderWidth = camWidth   // 720
        let renderHeight = camHeight  // 1280
        outputSize = CGSize(width: CGFloat(renderWidth), height: CGFloat(renderHeight))

        // 首帧时设置 drawable 尺寸为竖屏（仅一次，避免每帧重设导致性能问题）
        if !drawableSizeInitialized {
            view.drawableSize = CGSize(width: renderWidth, height: renderHeight)
            drawableSizeInitialized = true
        }

        // 离屏渲染缓冲池使用竖屏尺寸
        ensurePool(width: renderWidth, height: renderHeight)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let drawable = view.currentDrawable,
              // 相机纹理使用竖屏尺寸
              let cameraTexRef = makeTextureRef(from: cameraBuffer, width: camWidth, height: camHeight),
              // 离屏和录制缓冲使用竖屏尺寸
              let offscreenBuffer = dequeueOffscreenBuffer(),
              let offscreenTexRef = makeTextureRef(from: offscreenBuffer, width: renderWidth, height: renderHeight) else {
            return
        }

        let cameraTexture = cameraTexRef.texture
        let offscreenTexture = offscreenTexRef.texture
        let time = latestFrameTime
        let animTime = Float(CACurrentMediaTime())

        // 是否需要录制：预分配录制缓冲并创建纹理
        let needsRecording = recordingCallback != nil
        var recordingBuffer: CVPixelBuffer? = nil
        var recordingTexRef: TextureRef? = nil
        if needsRecording {
            recordingBuffer = dequeueOffscreenBuffer()
            if let rb = recordingBuffer {
                recordingTexRef = makeTextureRef(from: rb, width: renderWidth, height: renderHeight)
            }
        }

        // ---- 1. 渲染特效到离屏纹理（竖屏 720x1280） ----
        let portalPass = MTLRenderPassDescriptor()
        portalPass.colorAttachments[0].texture = offscreenTexture
        portalPass.colorAttachments[0].loadAction = .dontCare
        portalPass.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: portalPass) {
            encoder.setRenderPipelineState(portalPipeline)
            encoder.setFragmentTexture(cameraTexture, index: 0)

            var params = PortalParams(
                center1X: Float(hand1Point.x),
                center1Y: Float(hand1Point.y),
                center2X: Float(hand2Point.x),
                center2Y: Float(hand2Point.y),
                hasHand2: hasHand2 ? 1.0 : 0.0,
                time: animTime,
                aspect: Float(renderWidth) / Float(renderHeight),  // 720/1280 ≈ 0.5625
                radius: effectRadius,
                intensity: confidence > 0.15 ? confidence : 0.0,
                effectType: effectType,
                isFrontCamera: isFrontCamera ? 1 : 0
            )
            if !hasActiveTracking {
                // 未追踪时不显示特效（intensity = 0）
                params.intensity = 0
            }
            encoder.setFragmentBytes(&params, length: MemoryLayout<PortalParams>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // ---- 2. 将离屏纹理拷贝到 drawable（预览，UV 已翻转无需 Y 翻转） ----
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

        // ---- 3. 将离屏纹理拷贝到录制缓冲（UV 已翻转，直接使用 blitPipeline） ----
        if let recTex = recordingTexRef?.texture,
           let recBuffer = recordingBuffer,
           blitPipeline != nil {
            let recPass = MTLRenderPassDescriptor()
            recPass.colorAttachments[0].texture = recTex
            recPass.colorAttachments[0].loadAction = .dontCare
            recPass.colorAttachments[0].storeAction = .store

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: recPass) {
                encoder.setRenderPipelineState(blitPipeline)
                encoder.setFragmentTexture(offscreenTexture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        }

        // 保留 TextureRef（内含 CVMetalTexture）直到命令缓冲完成，防止纹理过早失效
        var retainedRefs = [cameraTexRef, offscreenTexRef]
        if let recRef = recordingTexRef {
            retainedRefs.append(recRef)
        }
        commandBuffer.addCompletedHandler { [weak self] _ in
            _ = retainedRefs // 防止 CVMetalTexture 过早释放
            guard let self = self else { return }
            // 仅录制新帧，使用 Y 翻转后的录制缓冲
            if self.recordingCallback != nil,
               time != self.lastRecordedTime,
               time.isValid,
               let recBuffer = recordingBuffer {
                self.lastRecordedTime = time
                self.recordingCallback?(recBuffer, time)
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
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4
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

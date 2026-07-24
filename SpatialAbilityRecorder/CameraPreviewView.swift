import SwiftUI
import MetalKit

/// SwiftUI 包装的 MTKView，用于显示 Metal 渲染结果。
struct CameraPreviewView: UIViewRepresentable {

    @ObservedObject var appModel: AppModel

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = appModel.renderer.device
        view.delegate = appModel.renderer
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = false
        view.preferredFramesPerSecond = 30
        view.autoResizeDrawable = false
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.backgroundColor = .black
        view.layer.contentsGravity = .resize
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // 无需更新
    }
}

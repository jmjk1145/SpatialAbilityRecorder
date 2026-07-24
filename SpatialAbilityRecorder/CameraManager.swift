import AVFoundation
import UIKit

/// 相机管理：配置 AVCaptureSession，逐帧交付视频像素缓冲，支持前后摄像头切换。
///
/// 使用 AVFoundation 的 videoOrientation=.portrait 直接输出竖屏 buffer（720x1280），
/// 前置摄像头启用 isVideoMirrored 实现自拍镜像。
/// Metal shader 无需处理旋转，UV 直接映射。
final class CameraManager: NSObject {

    /// 每收到一帧时回调（sampleBuffer + 解出的 CVPixelBuffer）
    var onFrame: ((CMSampleBuffer, CVPixelBuffer) -> Void)?

    /// 摄像头切换完成回调（通知 UI 当前是否使用前置摄像头）
    var onCameraSwitched: ((Bool) -> Void)?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.spatialability.camera", qos: .userInitiated)
    private var isConfigured = false

    /// 当前摄像头位置（后置/前置）
    private(set) var currentPosition: AVCaptureDevice.Position = .back

    var captureSession: AVCaptureSession { session }

    /// 输出尺寸（竖屏 720x1280，AVFoundation 已旋转）
    private(set) var outputSize: CGSize = CGSize(width: 720, height: 1280)

    /// 当前是否使用前置摄像头
    var isUsingFrontCamera: Bool { currentPosition == .front }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.isConfigured {
                self.configureSession()
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    /// 切换前后摄像头
    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            self.session.beginConfiguration()

            // 移除现有视频输入
            if let existingInput = self.session.inputs.first(where: { $0 is AVCaptureDeviceInput }) as? AVCaptureDeviceInput {
                self.session.removeInput(existingInput)
            }

            // 确定新摄像头位置
            let newPosition: AVCaptureDevice.Position = self.currentPosition == .back ? .front : .back

            // 尝试添加新摄像头
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition)
                ?? AVCaptureDevice.default(for: .video) else {
                self.session.commitConfiguration()
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.currentPosition = newPosition
                } else {
                    self.session.commitConfiguration()
                    return
                }
            } catch {
                self.session.commitConfiguration()
                return
            }

            // 设置竖屏方向 + 前置镜像（AVFoundation 直接输出竖屏 buffer）
            if let conn = self.videoOutput.connection(with: .video) {
                if conn.isVideoOrientationSupported {
                    conn.videoOrientation = .portrait
                }
                if conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = (newPosition == .front)
                }
            }

            self.session.commitConfiguration()

            // 通知 UI
            let isFront = (newPosition == .front)
            DispatchQueue.main.async {
                self.onCameraSwitched?(isFront)
            }
        }
    }

    // MARK: - 配置

    private func configureSession() {
        session.beginConfiguration()

        // 预设：720p（AVFoundation 旋转后输出竖屏 720x1280）
        session.sessionPreset = .hd1280x720

        // 视频输入（后置摄像头）
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
                currentPosition = .back
            }
        } catch {
            session.commitConfiguration()
            return
        }

        // 视频数据输出
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        // 设置竖屏方向 + 后置不镜像（AVFoundation 直接输出竖屏 buffer）
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false  // 后置不镜像
            }
        }

        session.commitConfiguration()

        // 竖屏尺寸（AVFoundation 已旋转）
        outputSize = CGSize(width: 720, height: 1280)

        isConfigured = true
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(sampleBuffer, pixelBuffer)
    }
}

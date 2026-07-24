import AVFoundation
import UIKit

/// 相机管理：配置 AVCaptureSession，逐帧交付视频像素缓冲，支持前后摄像头切换。
///
/// 重要：不使用 AVCaptureConnection.videoOrientation（对 AVCaptureVideoDataOutput 不可靠），
/// 原始 buffer 始终为横屏 1280x720（传感器原生方向），旋转在 Metal shader 中处理。
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

    /// 原始输出尺寸（横屏 1280x720，portrait 旋转在 shader 中处理）
    private(set) var outputSize: CGSize = CGSize(width: 1280, height: 720)

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

            // 不在 AVFoundation 层镜像，由 Metal shader 处理前置摄像头镜像
            if let conn = self.videoOutput.connection(with: .video) {
                if conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = false
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

        // 预设：720p（横屏 1280x720）
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

        // 仅设置镜像，不设 videoOrientation（由 shader 处理旋转）
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false
            }
        }

        session.commitConfiguration()

        // 原始横屏尺寸
        outputSize = CGSize(width: 1280, height: 720)

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

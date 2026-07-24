import AVFoundation
import UIKit

/// 相机管理：配置 AVCaptureSession，逐帧交付视频像素缓冲。
final class CameraManager: NSObject {

    /// 每收到一帧时回调（sampleBuffer + 解出的 CVPixelBuffer）
    var onFrame: ((CMSampleBuffer, CVPixelBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.spatialability.camera", qos: .userInitiated)
    private var isConfigured = false

    var captureSession: AVCaptureSession { session }

    // 输出尺寸（由实际 videoFormat 决定，默认 720p）
    private(set) var outputSize: CGSize = CGSize(width: 1280, height: 720)

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

    // MARK: - 配置

    private func configureSession() {
        session.beginConfiguration()

        // 预设：720p，兼顾画质与性能
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

        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false
            }
        }

        session.commitConfiguration()

        // 记录实际输出尺寸
        if let conn = videoOutput.connection(with: .video),
           let desc = conn.videoFormatDescription {
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            // portrait 模式下宽高互换
            outputSize = CGSize(width: CGFloat(dimensions.height), height: CGFloat(dimensions.width))
        }

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

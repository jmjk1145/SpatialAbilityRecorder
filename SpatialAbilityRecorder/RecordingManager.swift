import AVFoundation
import UIKit
import Photos

/// 录制管理：使用 AVAssetWriter 将渲染后的帧（含特效）写入 MP4 文件。
final class RecordingManager {

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var pixelBufferPool: CVPixelBufferPool?
    private var videoSize: CGSize = .zero
    private var startTime: CMTime = .invalid
    private let queue = DispatchQueue(label: "com.spatialability.record", qos: .userInitiated)

    /// 启动录制
    func start(videoSize: CGSize, completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.videoSize = videoSize

            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let filename = "SpatialAbility_\(Int(Date().timeIntervalSince1970)).mp4"
            let url = docs.appendingPathComponent(filename)

            // 清理已存在的文件
            try? FileManager.default.removeItem(at: url)

            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(videoSize.width),
                AVVideoHeightKey: Int(videoSize.height)
            ]

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true

            let adaptorSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(videoSize.width),
                kCVPixelBufferHeightKey as String: Int(videoSize.height)
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: adaptorSettings
            )

            if writer.canAdd(input) {
                writer.add(input)
            }

            self.assetWriter = writer
            self.videoInput = input
            self.pixelBufferAdaptor = adaptor
            self.pixelBufferPool = adaptor.pixelBufferPool

            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            self.startTime = .invalid

            DispatchQueue.main.async { completion(true) }
        }
    }

    /// 追加一帧渲染好的画面
    func appendVideoFrame(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        queue.async { [weak self] in
            guard let self = self,
                  let input = self.videoInput,
                  input.isReadyForMoreMediaData,
                  let writer = self.assetWriter else { return }

            if !self.startTime.isValid {
                self.startTime = time
            }

            let adjustedTime = CMTimeSubtract(time, self.startTime)

            // 使用 adaptor 期望的 pixelBuffer；若类型不符，做一次拷贝
            var bufferToAppend: CVPixelBuffer = pixelBuffer
            let pbType = CVPixelBufferGetPixelFormatType(pixelBuffer)
            if pbType != kCVPixelFormatType_32BGRA {
                bufferToAppend = self.copyToBGRA(pixelBuffer) ?? pixelBuffer
            }

            self.pixelBufferAdaptor?.append(bufferToAppend, withPresentationTime: adjustedTime)

            if writer.status == .failed {
                // 写入失败，重置
                self.assetWriter = nil
            }
        }
    }

    /// 停止录制并保存到相册
    func stop(completion: @escaping (URL) -> Void) {
        queue.async { [weak self] in
            guard let self = self, let writer = self.assetWriter else { return }
            self.videoInput?.markAsFinished()
            writer.finishWriting { [weak self] in
                let url = writer.outputURL
                self?.saveToPhotos(url) {
                    DispatchQueue.main.async { completion(url) }
                }
            }
        }
    }

    // MARK: - 保存到相册

    private func saveToPhotos(_ url: URL, done: @escaping () -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                done()
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .video, fileURL: url, options: nil)
            }) { _, _ in
                done()
            }
        }
    }

    // MARK: - 格式转换

    private func copyToBGRA(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        var dst: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, nil, &dst)
        guard let dstBuffer = dst else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dstBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dstBuffer, [])
        }
        // 简单逐字节拷贝（仅当布局兼容时；多数情况 BGRA 源可直接用）
        let srcBytes = CVPixelBufferGetBaseAddress(src)
        let dstBytes = CVPixelBufferGetBaseAddress(dstBuffer)
        let srcSize = CVPixelBufferGetDataSize(src)
        memcpy(dstBytes, srcBytes, srcSize)
        return dstBuffer
    }
}

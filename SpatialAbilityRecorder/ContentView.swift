import SwiftUI
import AVFoundation

struct ContentView: View {

    @EnvironmentObject var appModel: AppModel
    @State private var showPermissionAlert = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 相机预览
                CameraPreviewView(appModel: appModel)
                    .ignoresSafeArea()

                // 点击可手动覆盖特效位置（自动模式下仍可点击）
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let normalized = CGPoint(
                                    x: value.location.x / geo.size.width,
                                    y: value.location.y / geo.size.height
                                )
                                appModel.setTrackingAnchor(normalizedPoint: normalized)
                            }
                    )
                    .ignoresSafeArea()

                // 追踪标记（显示主手位置）
                if appModel.hasTrackedPoint {
                    TrackingMarker(
                        point: appModel.trackedPoint,
                        isActive: appModel.isTrackingActive,
                        handCount: appModel.handCount,
                        size: geo.size
                    )
                    .allowsHitTesting(false)
                }

                // 顶部状态栏 + 特效选择器
                VStack {
                    // 状态消息
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Text(appModel.statusMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)

                            if appModel.isTrackingActive {
                                HStack(spacing: 6) {
                                    // 手部数量指示
                                    HStack(spacing: 3) {
                                        Image(systemName: "hand.raised.fill")
                                            .font(.system(size: 10))
                                        Text("\(appModel.handCount)")
                                            .font(.system(size: 11, weight: .bold))
                                    }
                                    .foregroundColor(appModel.handCount >= 2 ? .cyan : .green)

                                    Text("\(Int(appModel.trackedConfidence * 100))%")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                        Spacer()
                    }

                    // 特效选择器
                    HStack(spacing: 12) {
                        // 上一个特效
                        Button {
                            appModel.switchEffectPrevious()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }

                        // 当前特效名称
                        HStack(spacing: 6) {
                            Image(systemName: appModel.effectIcons[appModel.currentEffectIndex])
                                .font(.system(size: 14))
                                .foregroundColor(.cyan)
                            Text(appModel.effectNames[appModel.currentEffectIndex])
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())

                        // 下一个特效
                        Button {
                            appModel.switchEffect()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .padding(.top, 6)

                    Spacer()
                }
                .ignoresSafeArea()

                // 底部控制栏
                VStack {
                    Spacer()
                    HStack(spacing: 44) {
                        // 摄像头切换
                        Button {
                            appModel.switchCamera()
                        } label: {
                            Image(systemName: appModel.isUsingFrontCamera ? "camera.metering.matrix" : "camera.aperture")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 56, height: 56)
                                .background(.ultraThinMaterial, in: Circle())
                        }

                        // 重置追踪
                        Button {
                            appModel.resetTracking()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 56, height: 56)
                                .background(.ultraThinMaterial, in: Circle())
                        }

                        // 录制按钮
                        Button {
                            appModel.toggleRecording()
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(Color.white, lineWidth: 4)
                                    .frame(width: 74, height: 74)
                                if appModel.isRecording {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.red)
                                        .frame(width: 28, height: 28)
                                } else {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 60, height: 60)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
                .ignoresSafeArea()
            }
        }
        .onAppear {
            requestPermissions()
        }
        .onDisappear {
            appModel.stopSession()
        }
        .alert("需要相机权限", isPresented: $showPermissionAlert) {
            Button("去设置") { openSettings() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在设置中允许访问相机以使用空间异能录制功能")
        }
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if granted {
                DispatchQueue.main.async {
                    appModel.startSession()
                }
            } else {
                DispatchQueue.main.async {
                    showPermissionAlert = true
                }
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - 追踪标记

struct TrackingMarker: View {
    let point: CGPoint
    let isActive: Bool
    let handCount: Int
    let size: CGSize

    var body: some View {
        let x = point.x * size.width
        let y = point.y * size.height

        let markerColor: Color = handCount >= 2 ? .cyan : (isActive ? .green : .orange)

        ZStack {
            Circle()
                .stroke(markerColor, lineWidth: 2)
                .frame(width: 50, height: 50)

            Circle()
                .fill(markerColor)
                .frame(width: 6, height: 6)

            // 手部图标
            Image(systemName: "hand.point.up.fill")
                .font(.system(size: 14))
                .foregroundColor(markerColor)
                .offset(y: -35)

            // 十字准星
            Path { path in
                path.move(to: CGPoint(x: 0, y: 25))
                path.addLine(to: CGPoint(x: 60, y: 25))
                path.move(to: CGPoint(x: 30, y: 0))
                path.addLine(to: CGPoint(x: 30, y: 60))
            }
            .stroke(markerColor.opacity(0.6), lineWidth: 1)
            .frame(width: 60, height: 60)
        }
        .position(x: x, y: y)
        .animation(.easeOut(duration: 0.08), value: point)
    }
}

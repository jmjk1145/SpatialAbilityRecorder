# SpatialAbilityRecorder

实时手动追踪 + 空间异能传送门特效录制 iOS App。

点击屏幕任意位置设定追踪锚点，App 会用 Vision 框架实时追踪该目标，同时在画面上叠加蓝紫色传送门漩涡特效（含漩涡扭曲、边缘高光、外发光、扩散光环），并可一键录制含特效的视频保存到相册。

## 架构

```
相机帧 (AVCaptureSession)
    │
    ▼
手动追踪 (Vision VNTrackObjectRequest)
    │
    ▼
Metal 渲染 (EffectRenderer + PortalShader.metal)
    │
    ├─→ MTKView 实时预览
    │
    ▼
视频录制 (AVAssetWriter → MP4 → 相册)
```

### 核心文件

| 文件 | 职责 |
|------|------|
| `CameraManager.swift` | AVCaptureSession 配置，逐帧交付 CVPixelBuffer |
| `TrackingManager.swift` | Vision VNTrackObjectRequest 手动点追踪 |
| `EffectRenderer.swift` | Metal 渲染管线：相机帧 + 传送门特效 → 离屏纹理 → drawable |
| `PortalShader.metal` | Metal 着色器：漩涡扭曲、高光环、扩散光环、中心亮点 |
| `RecordingManager.swift` | AVAssetWriter 录制 MP4 并保存到相册 |
| `AppModel.swift` | 全局状态：协调相机→追踪→渲染→录制数据流 |
| `ContentView.swift` | SwiftUI 界面：相机预览、点击手势、录制按钮 |
| `CameraPreviewView.swift` | UIViewRepresentable 包装 MTKView |

## 构建要求

- iOS 15.0+ 部署目标
- 真机运行（相机功能无法在模拟器使用）
- 编译环境：Xcode 14+（需要 macOS 12.5+）

## 构建 IPA

### 方式一：GitHub Actions 云端构建（无需 Mac，推荐）

> 适合 Mac 太旧无法运行 Xcode 的情况，使用 GitHub 免费云端 macOS 环境编译。

**准备工作：**
1. 注册 GitHub 账号（https://github.com/signup）
2. 创建一个 **Public（公开）** 仓库（公开仓库的 macOS 构建分钟数免费无限）

**上传代码：**
1. 在新仓库页面点击 `uploading an existing file`
2. 将 `SpatialAbilityRecorder` 文件夹内所有内容拖入（包括 `.github` 隐藏文件夹）
3. 确认 `.github/workflows/build-ipa.yml` 已上传
4. 点击 Commit changes

**触发构建：**
1. 进入仓库的 `Actions` 标签页
2. 左侧选择 `构建 IPA` 工作流
3. 点击右侧 `Run workflow` → `Run workflow`
4. 等待约 5-10 分钟（绿色对勾表示成功）

**下载 IPA：**
1. 点击完成的构建记录
2. 在页面底部 `Artifacts` 区域下载 `SpatialAbilityRecorder-ipa`
3. 解压 zip 得到 `SpatialAbilityRecorder.ipa`

### 方式二：本地脚本构建（需要可用的 Mac）

```bash
cd SpatialAbilityRecorder

# 未签名构建（仅用于测试，不可直接安装到设备）
chmod +x build_ipa.sh
./build_ipa.sh --unsigned

# 签名构建（需要 Apple 开发者账号）
./build_ipa.sh --team YOUR_TEAM_ID
```

构建产物在 `build/` 目录下：
- 未签名：`build/SpatialAbilityRecorder.ipa`
- 签名：`build/ipa/SpatialAbilityRecorder.ipa`

### 方式三：Xcode 构建

1. 用 Xcode 打开 `SpatialAbilityRecorder.xcodeproj`
2. 选择真机目标
3. 在 Signing & Capabilities 中设置你的开发者团队
4. Product → Archive
5. 在 Organizer 中导出 IPA

### 方式四：XcodeGen 重新生成工程（可选）

如果需要修改工程配置，可安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 后：

```bash
cd SpatialAbilityRecorder
xcodegen generate
```

## 使用方法

1. 打开 App，允许相机和相册权限
2. 将相机对准目标物体/区域
3. **点击屏幕**设定追踪锚点（蓝色十字标记出现）
4. 传送门特效会在追踪点位置出现并跟随目标移动
5. 点击底部**红色圆形按钮**开始录制
6. 再次点击停止录制，视频自动保存到相册
7. 点击**重置按钮**（左侧）可清除追踪并重新选择锚点

## 特效细节

- **漩涡扭曲**：传送门内部的画面以追踪点为中心旋转收缩，制造空间吸入感
- **边缘高光环**：传送门边缘的蓝色高亮环
- **外发光**：超出传送门半径的蓝色辉光衰减
- **扩散光环**：3 层从内向外扩散的脉冲环
- **中心亮点**：传送门中心的白色亮点
- **强度联动**：特效强度随追踪置信度变化，追踪丢失时特效淡出

## 安装到 iPhone

云端构建产出的是**未签名 IPA**，不能直接安装到设备。安装方式：

| 方式 | 说明 |
|------|------|
| **Sideloadly** | Windows/Mac 皆可，用 Apple ID 免费签名安装（推荐） |
| **AltStore** | 需要电脑配合，每 7 天重新签名 |
| **TrollStore** | 若 iOS 14.0-16.6.1 可永久安装，无需签名 |
| **签名构建** | 有 Apple 开发者账号可在 GitHub Actions 中配置证书签名 |

## 注意事项

- 若 `build_ipa.sh` 在 macOS 上因换行符报错，执行 `sed -i '' 's/\r$//' build_ipa.sh`
- 未签名 IPA 需通过 Sideloadly、AltStore 等工具安装，或改用签名构建
- GitHub 公开仓库的 macOS Actions 构建分钟数免费无限，私有仓库每月 2000 分钟（按 10 倍计算 = 200 分钟 macOS）
- App 仅录制视频，不录制音频

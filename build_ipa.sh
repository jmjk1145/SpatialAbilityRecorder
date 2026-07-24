#!/bin/bash
# ============================================================
#  SpatialAbilityRecorder IPA 构建脚本
#  用法:
#    签名构建:  ./build_ipa.sh --team ABCDE12345
#    未签名构建: ./build_ipa.sh --unsigned
#  必须在 macOS + Xcode 环境下运行
# ============================================================
set -e

PROJECT="SpatialAbilityRecorder.xcodeproj"
SCHEME="SpatialAbilityRecorder"
CONFIGURATION="Release"
BUILD_DIR="build"

# ---- 环境检查 ----
if [[ "$(uname)" != "Darwin" ]]; then
    echo "[错误] 此脚本必须在安装了 Xcode 的 macOS 上运行。"
    exit 1
fi
if ! command -v xcodebuild &>/dev/null; then
    echo "[错误] 未找到 xcodebuild，请先安装 Xcode。"
    exit 1
fi

MODE=""
TEAM_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --team)    MODE="signed";   TEAM_ID="$2"; shift 2;;
        --unsigned) MODE="unsigned"; shift;;
        *) echo "[错误] 未知参数: $1"; exit 1;;
    esac
done

if [[ -z "$MODE" ]]; then
    echo "请选择构建模式:"
    echo "  1) 签名构建（需要 Apple 开发者 Team ID）"
    echo "  2) 未签名构建（仅用于测试，不可直接安装到设备）"
    read -p "输入 1 或 2: " choice
    case "$choice" in
        1) MODE="signed";   read -p "输入 Team ID (如 ABCDE12345): " TEAM_ID;;
        2) MODE="unsigned";;
        *) echo "[错误] 无效选择"; exit 1;;
    esac
fi

mkdir -p "$BUILD_DIR"
echo "=========================================="
echo "  构建模式: $MODE"
echo "=========================================="

if [[ "$MODE" == "signed" ]]; then
    if [[ -z "$TEAM_ID" ]]; then
        echo "[错误] 签名构建需要 Team ID"
        exit 1
    fi

    ARCHIVE_PATH="$BUILD_DIR/SpatialAbilityRecorder.xcarchive"
    EXPORT_PATH="$BUILD_DIR/ipa"
    EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"

    # 生成导出配置
    cat > "$EXPORT_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>compileBitcode</key>
    <false/>
</dict>
</plist>
EOF

    echo "[1/2] 归档中..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -archivePath "$ARCHIVE_PATH" \
        -destination "generic/platform=iOS" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE="Automatic"

    echo "[2/2] 导出 IPA..."
    rm -rf "$EXPORT_PATH"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_PLIST" \
        -exportPath "$EXPORT_PATH"

    IPA_PATH="$EXPORT_PATH/SpatialAbilityRecorder.ipa"
    echo ""
    echo "=========================================="
    echo "  构建成功!"
    echo "  IPA 路径: $IPA_PATH"
    echo "=========================================="

else
    DERIVED_DATA="$BUILD_DIR/DerivedData"

    echo "[1/2] 编译中（未签名）..."
    xcodebuild build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "generic/platform=iOS" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY=""

    APP_PATH=$(find "$DERIVED_DATA" -name "SpatialAbilityRecorder.app" -type d | head -1)
    if [[ -z "$APP_PATH" ]]; then
        echo "[错误] 未找到编译产物 .app"
        exit 1
    fi

    echo "[2/2] 打包 IPA..."
    PAYLOAD_DIR="$BUILD_DIR/Payload"
    rm -rf "$PAYLOAD_DIR"
    mkdir -p "$PAYLOAD_DIR"
    cp -R "$APP_PATH" "$PAYLOAD_DIR/"

    cd "$BUILD_DIR"
    rm -f SpatialAbilityRecorder.ipa
    zip -r -q SpatialAbilityRecorder.ipa Payload
    cd ..

    echo ""
    echo "=========================================="
    echo "  构建成功!（未签名）"
    echo "  IPA 路径: $BUILD_DIR/SpatialAbilityRecorder.ipa"
    echo "  注意: 此 IPA 未签名，不能直接安装到设备。"
    echo "  如需安装，请使用签名工具或改用签名构建。"
    echo "=========================================="
fi

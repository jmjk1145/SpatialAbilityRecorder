#include <metal_stdlib>
using namespace metal;

// MARK: - 顶点

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

/// 全屏三角形（覆盖整个 NDC 空间），UV 范围 [0,1]。
/// 渲染目标为竖屏 720x1280。
/// 重要：翻转 Y 使 UV 与 Metal 纹理坐标一致（原点左上，Y 向下），
/// 这样渲染目标 UV 和纹理采样 UV 的 Y 方向相同，避免画面上下颠倒。
vertex VertexOut quad_vertex(uint vid [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    float2 uvs[3] = {
        float2(0.0, 0.0),
        float2(2.0, 0.0),
        float2(0.0, 2.0)
    };
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    // 翻转 Y：NDC y=-1（屏幕底部）→ UV y=1（纹理底部），NDC y=1（屏幕顶部）→ UV y=0（纹理顶部）
    out.uv = float2(uvs[vid].x, 1.0 - uvs[vid].y);
    return out;
}

// MARK: - 噪声工具函数

float hash21(float2 p) {
    p = fract(p * float2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

float noise2D(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * noise2D(p);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

// MARK: - 坐标转换：竖屏屏幕 UV → 相机纹理 UV
//
// AVFoundation 已通过 videoOrientation=.portrait 将 buffer 旋转为竖屏方向，
// 前置摄像头通过 isVideoMirrored 完成镜像。
// 因此渲染目标 UV 与相机纹理 UV 完全一致，直接返回即可。

float2 toCameraUV(float2 screenUV, int isFront) {
    return screenUV;
}

// MARK: - 片元：空间异能特效

struct PortalParams {
    float2 center;        // 归一化锚点（视图坐标：左上角原点，0=顶部）
    float  time;          // 动画时间（秒）
    float  aspect;        // 竖屏宽高比 width/height = 720/1280
    float  radius;        // 特效归一化半径
    float  intensity;     // 特效强度（追踪置信度）
    int    effectType;    // 0空间裂缝 1护盾 2烈焰 3闪电 4黑洞
    int    isFrontCamera; // 0后置 1前置
    float  _pad0;
    float  _pad1;
};

// ---- 特效 0：空间裂缝（白色能量闪电 + 裂缝 + 空间扭曲） ----
// 视觉风格：手指间的白色闪电/能量裂缝，空间被撕裂的效果
float4 effectPortal(float2 uv, float2 cameraUV, float2 pos, float2 ctr,
                    float dist, float radius, float time, float I, float aspect,
                    int isFront, texture2d<float> cameraTex, sampler s) {
    float4 color = cameraTex.sample(s, cameraUV);

    // 白色/青色调色板（匹配视频中的能量效果）
    float3 whiteHot   = float3(1.0, 1.0, 1.0);      // 白热核心
    float3 energyCyan = float3(0.6, 0.9, 1.0);      // 青色能量
    float3 electricBlue = float3(0.3, 0.6, 1.0);    // 电蓝色
    float3 deepVoid   = float3(0.05, 0.05, 0.15);   // 裂缝内部虚空

    float2 dirFromCenter = pos - ctr;
    float angle = atan2(dirFromCenter.y, dirFromCenter.x);
    float t = dist / radius;

    // === 1. 空间扭曲（径向涟漪扭曲） ===
    float distortStrength = smoothstep(radius * 1.5, 0.0, dist) * 0.015 * I;
    if (distortStrength > 0.0005) {
        float2 distortDir = normalize(dirFromCenter + float2(0.001, 0.001));
        float ripple = sin(dist * 40.0 - time * 8.0) * distortStrength;
        float2 distortedUV = uv + distortDir * ripple;
        distortedUV = clamp(distortedUV, 0.0, 1.0);
        float2 distortedCamUV = toCameraUV(distortedUV, isFront);
        color = cameraTex.sample(s, distortedCamUV);
    }

    // === 2. 中心裂缝（不规则撕裂形状） ===
    // 使用噪声创建不规则的裂缝边缘
    float crackNoise = fbm(float2(angle * 3.0 + time * 0.5, dist * 8.0));
    float crackRadius = radius * (0.7 + crackNoise * 0.5);
    float crackMask = smoothstep(crackRadius, crackRadius * 0.85, dist);

    if (crackMask > 0.01) {
        // 裂缝内部：虚空 + 能量
        float3 voidColor = deepVoid;
        float voidNoise = fbm(float2(dist * 20.0 + time * 3.0, angle * 5.0));
        voidColor += electricBlue * voidNoise * 0.4;
        voidColor += whiteHot * (1.0 - t) * 0.3;

        color.rgb = mix(color.rgb, voidColor, crackMask * I);

        // 裂缝边缘：白热发光
        float edgeGlow = smoothstep(crackRadius * 0.85, crackRadius * 0.9, dist)
                       - smoothstep(crackRadius * 0.9, crackRadius * 0.95, dist);
        color.rgb += whiteHot * edgeGlow * 2.5 * I;
    }

    // === 3. 闪电弧（从中心放射的多条分叉闪电） ===
    float lightning = 0.0;
    float lightningCore = 0.0;
    int numBolts = 9;
    for (int b = 0; b < numBolts; b++) {
        float fb = float(b);
        // 每条闪电有不同的角度，随时间缓慢旋转
        float boltAngle = fb / float(numBolts) * 6.28318 + time * 0.4;
        float2 boltDir = float2(cos(boltAngle), sin(boltAngle));

        // 沿闪电方向的距离
        float along = dot(dirFromCenter, boltDir);
        if (along < 0.0 || along > radius * 2.0) continue;

        // 垂直距离（闪电的粗细）
        float2 perpDir = float2(-boltDir.y, boltDir.x);
        float perp = abs(dot(dirFromCenter, perpDir));

        // 闪电抖动（噪声驱动的之字形）
        float jitter = (noise2D(float2(along * 15.0, fb * 7.3 + floor(time * 10.0) * 1.7)) - 0.5) * radius * 0.35;
        perp = abs(perp - jitter);

        // 闪电粗细随距离衰减
        float thickness = 0.004 * (1.0 - along / (radius * 2.0)) + 0.001;
        float bolt = smoothstep(thickness, 0.0, perp) * smoothstep(radius * 2.0, 0.0, along);

        // 闪电闪烁
        float flicker = step(0.2, hash21(float2(floor(time * 15.0), fb)));
        bolt *= flicker * 0.6 + 0.4;

        lightning += bolt;
        lightningCore += bolt * smoothstep(0.0, radius * 0.3, along);
    }

    // 闪电颜色：白色核心 + 青色外发光
    color.rgb += whiteHot * lightningCore * 2.0 * I;
    color.rgb += energyCyan * lightning * 0.8 * I;

    // === 4. 能量粒子（白色火花） ===
    float2 sparkUv = dirFromCenter * 10.0;
    for (int sp = 0; sp < 4; sp++) {
        float spTime = time * (2.0 + float(sp) * 0.4) + float(sp) * 1.9;
        float2 offset = float2(cos(spTime), sin(spTime * 1.3)) * 0.3;
        float2 sparkPos = sparkUv + offset * 4.0;
        float sparkN = hash21(floor(sparkPos) + floor(spTime));
        float spark = step(0.93, sparkN) * smoothstep(radius * 1.5, 0.0, dist);
        color.rgb += whiteHot * spark * 0.6 * I;
    }

    // === 5. 中心白热核心 ===
    float core = exp(-pow(dist * 30.0, 2.0));
    float corePulse = sin(time * 10.0) * 0.2 + 0.8;
    color.rgb += whiteHot * core * corePulse * 1.5 * I;

    // === 6. 能量光晕（白色 + 青色双层） ===
    float glowInner = exp(-pow(max(dist - radius * 0.3, 0.0) * 15.0, 2.0));
    color.rgb += energyCyan * glowInner * 0.8 * I;

    float glowOuter = exp(-pow(max(dist - radius, 0.0) * 8.0, 2.0));
    color.rgb += electricBlue * glowOuter * 0.5 * I;

    // === 7. 扩散冲击波 ===
    for (int i = 0; i < 3; i++) {
        float phase = fract(time * 0.6 + float(i) * 0.33);
        float ringDist = radius * (0.5 + phase * 1.2);
        float ring = smoothstep(0.005, 0.0, abs(dist - ringDist));
        color.rgb += whiteHot * ring * (1.0 - phase) * 0.6 * I;
    }

    // === 8. 空间碎片（玻璃碎裂效果） ===
    float shardNoise = noise2D(float2(angle * 6.0 + time * 0.3, dist * 12.0));
    float shardMask = step(0.7, shardNoise) * smoothstep(radius * 1.3, radius * 0.5, dist)
                    * smoothstep(radius * 0.2, radius * 0.4, dist);
    float shardFlicker = step(0.5, hash21(float2(floor(angle * 10.0), floor(time * 6.0))));
    color.rgb += energyCyan * shardMask * shardFlicker * 0.4 * I;

    // === 9. 空间扭曲色差 ===
    float caStrength = smoothstep(radius * 1.5, radius * 0.3, dist) * 0.008 * I;
    if (caStrength > 0.0005) {
        color.r = mix(color.r, cameraTex.sample(s, cameraUV + float2(caStrength, 0.0)).r, 0.5);
        color.b = mix(color.b, cameraTex.sample(s, cameraUV - float2(caStrength, 0.0)).b, 0.5);
    }

    return color;
}

// ---- 特效 1：能量护盾（六边形蜂窝） ----
float4 effectShield(float2 uv, float2 cameraUV, float2 pos, float2 ctr,
                    float dist, float radius, float time, float I, float aspect,
                    int isFront, texture2d<float> cameraTex, sampler s) {
    float4 color = cameraTex.sample(s, cameraUV);

    float3 shieldColor = float3(0.1, 0.8, 0.6);
    float3 edgeColor   = float3(0.3, 1.0, 0.8);

    // 六边形蜂窝网格
    float2 hexUv = pos - ctr;
    hexUv.y /= 0.866;
    float2 h = float2(hexUv.x * 1.5, hexUv.y);
    float2 a = fmod(h, 1.0) - 0.5;
    float hex = abs(a.x) + abs(a.y) * 0.5 + abs(a.x - a.y) * 0.5;
    float hexLine = smoothstep(0.45, 0.5, hex);

    float shieldMask = smoothstep(radius, radius - 0.01, dist);
    hexLine *= shieldMask;

    float pulse = sin(dist * 30.0 - time * 4.0) * 0.5 + 0.5;
    pulse *= shieldMask;

    color.rgb = mix(color.rgb, shieldColor * 0.3, shieldMask * 0.35 * I);
    color.rgb += shieldColor * hexLine * 0.8 * I;
    color.rgb += edgeColor * pulse * 0.3 * I;

    float rimWidth = 0.015;
    float rim = smoothstep(radius, radius - rimWidth, dist)
              - smoothstep(radius - rimWidth, radius - rimWidth * 2.5, dist);
    color.rgb += edgeColor * rim * 2.0 * I;

    float outerGlow = exp(-pow(max(dist - radius, 0.0) * 12.0, 2.0));
    color.rgb += edgeColor * outerGlow * 0.6 * I;

    for (int i = 0; i < 2; i++) {
        float phase = fract(time * 0.3 + float(i) * 0.5);
        float ringDist = radius + phase * 0.4;
        float ring = smoothstep(0.01, 0.0, abs(dist - ringDist));
        color.rgb += edgeColor * ring * (1.0 - phase) * 0.5 * I;
    }

    float core = exp(-pow(dist * 20.0, 2.0));
    color.rgb += float3(0.5, 1.0, 0.9) * core * 0.4 * I;

    return color;
}

// ---- 特效 2：烈焰能量 ----
float4 effectFire(float2 uv, float2 cameraUV, float2 pos, float2 ctr,
                  float dist, float radius, float time, float I, float aspect,
                  int isFront, texture2d<float> cameraTex, sampler s) {
    float4 color = cameraTex.sample(s, cameraUV);

    // 火焰噪声（向上飘动）
    float2 fireUv = (pos - ctr) * float2(8.0, 8.0);
    fireUv.y -= time * 1.5;
    float n = fbm(fireUv + float2(time * 0.3, 0.0));
    float n2 = fbm(fireUv * 2.0 + float2(0.0, -time * 2.0));

    float fireShape = smoothstep(radius, 0.0, dist);
    float upFactor = smoothstep(0.0, radius, pos.y - ctr.y + radius * 0.3);
    fireShape *= upFactor * 0.7 + 0.3;

    float fire = n * fireShape * 1.5;
    fire = clamp(fire, 0.0, 1.5);

    float3 hotColor  = float3(1.0, 0.95, 0.8);
    float3 midColor  = float3(1.0, 0.6, 0.15);
    float3 coolColor = float3(0.9, 0.2, 0.05);

    float3 fireColor = mix(coolColor, midColor, smoothstep(0.0, 0.5, fire));
    fireColor = mix(fireColor, hotColor, smoothstep(0.5, 0.9, fire));

    float2 sparkUv = pos - ctr;
    float sparkN = hash21(floor(sparkUv * 20.0) + floor(time * 3.0));
    float spark = step(0.96, sparkN) * fireShape;

    float fireMask = fire * I * 0.8;
    color.rgb = mix(color.rgb, fireColor, fireMask);
    color.rgb += fireColor * fire * 0.3 * I;
    color.rgb += hotColor * spark * 0.5 * I;

    // 边缘热扭曲
    float distortMask = smoothstep(radius, radius - 0.05, dist) * I;
    float distort = n2 * 0.02;
    float2 distortPortraitUV = uv + float2(distort, -distort * 0.5) * distortMask;
    distortPortraitUV = clamp(distortPortraitUV, 0.0, 1.0);
    float2 distortCamUV = toCameraUV(distortPortraitUV, isFront);
    float4 distorted = cameraTex.sample(s, distortCamUV);
    color.rgb = mix(color.rgb, distorted.rgb, distortMask * 0.4);

    float core = exp(-pow(dist * 18.0, 2.0));
    color.rgb += float3(1.0, 0.9, 0.6) * core * 0.5 * I;

    float outerGlow = exp(-pow(max(dist - radius * 0.8, 0.0) * 10.0, 2.0));
    color.rgb += float3(1.0, 0.4, 0.1) * outerGlow * 0.4 * I;

    return color;
}

// ---- 特效 3：闪电链 ----
float4 effectLightning(float2 uv, float2 cameraUV, float2 pos, float2 ctr,
                       float dist, float radius, float time, float I, float aspect,
                       int isFront, texture2d<float> cameraTex, sampler s) {
    float4 color = cameraTex.sample(s, cameraUV);

    float3 boltColor  = float3(0.5, 0.7, 1.0);
    float3 coreColor  = float3(0.9, 0.95, 1.0);
    float3 sparkColor = float3(0.6, 0.4, 1.0);

    float bolt = 0.0;
    float coreBolt = 0.0;
    int numBolts = 7;
    for (int i = 0; i < numBolts; i++) {
        float fi = float(i);
        float angle = fi / float(numBolts) * 6.28318 + time * 0.5;
        float2 dir = float2(cos(angle), sin(angle));

        float along = dot(pos - ctr, dir);
        if (along < 0.0 || along > radius * 1.5) continue;

        float2 perpUv = float2(along * 12.0, fi * 7.3 + floor(time * 8.0) * 1.7);
        float wobble = (noise2D(perpUv) - 0.5) * radius * 0.4;
        float perp = abs(dot(pos - ctr, float2(-dir.y, dir.x)) - wobble);

        float thickness = 0.006 * (1.0 - along / (radius * 1.5));
        float b = smoothstep(thickness, 0.0, perp);
        bolt += b;
        coreBolt += b * smoothstep(0.0, 0.3, along);
    }

    float flicker = step(0.3, hash21(float2(floor(time * 12.0), 0.0)));
    bolt *= flicker * 0.7 + 0.3;

    float core = exp(-pow(dist * 22.0, 2.0));
    float corePulse = sin(time * 15.0) * 0.3 + 0.7;
    core *= corePulse;

    float2 sparkUv = (pos - ctr) * 15.0;
    float sparkN = hash21(floor(sparkUv) + floor(time * 10.0));
    float sparks = step(0.93, sparkN) * smoothstep(radius, 0.0, dist);

    color.rgb += boltColor * bolt * 1.5 * I;
    color.rgb += coreColor * coreBolt * bolt * 2.0 * I;
    color.rgb += coreColor * core * 0.8 * I;
    color.rgb += sparkColor * sparks * 0.6 * I;

    float fieldMask = smoothstep(radius * 1.2, 0.0, dist);
    float field = noise2D((pos - ctr) * 6.0 + time * 2.0) * fieldMask;
    color.rgb += boltColor * field * 0.15 * I;

    float ringDist = radius;
    float arc = smoothstep(0.01, 0.0, abs(dist - ringDist));
    arc *= flicker * 0.5 + 0.5;
    color.rgb += boltColor * arc * 0.8 * I;

    return color;
}

// ---- 特效 4：黑洞引力 ----
float4 effectBlackHole(float2 uv, float2 cameraUV, float2 pos, float2 ctr,
                       float dist, float radius, float time, float I, float aspect,
                       int isFront, texture2d<float> cameraTex, sampler s) {
    float3 accretionColor = float3(1.0, 0.5, 0.1);
    float3 hotColor       = float3(1.0, 0.85, 0.4);
    float3 rimColor       = float3(0.4, 0.2, 0.6);

    float eventHorizon = radius * 0.35;

    float4 color;

    if (dist < eventHorizon) {
        color = float4(0.0, 0.0, 0.0, 1.0);
    } else {
        // 引力透镜：扭曲周围画面
        float2 dir = normalize(pos - ctr);
        float bendStrength = (radius / max(dist, 0.001)) * 0.3 * I;
        float2 bentPos = pos - dir * bendStrength * radius;
        float2 bentPortraitUV = float2(bentPos.x / aspect, bentPos.y);
        bentPortraitUV = clamp(bentPortraitUV, 0.0, 1.0);
        float2 bentCamUV = toCameraUV(bentPortraitUV, isFront);
        color = cameraTex.sample(s, bentCamUV);

        // 吸积盘
        float2 diskPos = pos - ctr;
        float diskAngle = atan2(diskPos.y, diskPos.x);
        float doppler = sin(diskAngle - time * 3.0) * 0.5 + 0.5;

        float diskInner = eventHorizon * 1.1;
        float diskOuter = radius * 0.9;
        float diskMask = smoothstep(diskInner, diskInner + 0.01, dist)
                       * smoothstep(diskOuter, diskOuter - 0.05, dist);

        float spiral = sin(diskAngle * 3.0 + dist * 25.0 - time * 4.0) * 0.5 + 0.5;
        float diskNoise = noise2D(float2(dist * 20.0, diskAngle * 2.0 + time * 2.0));

        float3 diskColor = mix(accretionColor, hotColor, doppler);
        diskColor = mix(diskColor, diskColor * 1.5, spiral);
        diskColor = mix(diskColor, diskColor * 0.7, diskNoise);

        float diskIntensity = diskMask * (1.0 + doppler * 0.5);
        color.rgb = mix(color.rgb, diskColor, diskIntensity * I);

        float photonRing = exp(-pow((dist - eventHorizon) * 40.0, 2.0));
        color.rgb += hotColor * photonRing * 1.5 * I;

        float redshift = smoothstep(radius, eventHorizon, dist) * 0.3 * I;
        color.rgb = mix(color.rgb, float3(color.r, color.g * 0.7, color.b * 0.5), redshift);

        float outerGlow = exp(-pow(max(dist - radius, 0.0) * 8.0, 2.0));
        color.rgb += rimColor * outerGlow * 0.3 * I;
    }

    return color;
}

// MARK: - 主片元着色器

fragment float4 portal_fragment(VertexOut in [[stage_in]],
                                texture2d<float> cameraTex [[texture(0)]],
                                constant PortalParams &params [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;  // 屏幕坐标 UV (0,0=左上, 1,1=右下)，顶点着色器已翻转 Y
    float aspect = params.aspect;  // 720/1280 ≈ 0.5625

    // UV 直接映射（AVFoundation 已处理旋转和镜像）
    float2 cameraUV = toCameraUV(uv, params.isFrontCamera);

    // 等比像素空间（用于距离计算），UV 已翻转所以 y 方向与视图坐标一致（0=顶部）
    float2 pos = float2(uv.x * aspect, uv.y);
    // 追踪点：视图坐标 (0=顶部, y向下) 直接对应 UV 空间，无需翻转
    float2 ctr = float2(params.center.x * aspect, params.center.y);

    float dist = distance(pos, ctr);
    float radius = params.radius;
    float I = params.intensity;

    if (I < 0.01) {
        return cameraTex.sample(s, cameraUV);
    }

    switch (params.effectType) {
        case 0:
            return effectPortal(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, params.isFrontCamera, cameraTex, s);
        case 1:
            return effectShield(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, params.isFrontCamera, cameraTex, s);
        case 2:
            return effectFire(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, params.isFrontCamera, cameraTex, s);
        case 3:
            return effectLightning(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, params.isFrontCamera, cameraTex, s);
        case 4:
            return effectBlackHole(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, params.isFrontCamera, cameraTex, s);
        default:
            return effectPortal(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, params.isFrontCamera, cameraTex, s);
    }
}

// MARK: - 纹理拷贝（预览 + 录制：正常方向）
// 顶点着色器已翻转 Y，使 UV 与纹理坐标一致，因此直接采样即可。

fragment float4 blit_fragment(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}

// MARK: - Y 翻转纹理拷贝（已废弃，保留兼容）
fragment float4 blit_flipped_fragment(VertexOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, float2(in.uv.x, 1.0 - in.uv.y));
}

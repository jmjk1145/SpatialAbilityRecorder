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
    int    effectType;    // 0传送门 1护盾 2烈焰 3闪电 4黑洞
    int    isFrontCamera; // 0后置 1前置
    float  _pad0;
    float  _pad1;
};

// ---- 特效 0：空间传送门（漩涡扭曲 + 裂缝 + 粒子） ----
float4 effectPortal(float2 uv, float2 cameraUV, float2 pos, float2 ctr,
                    float dist, float radius, float time, float I, float aspect,
                    int isFront, texture2d<float> cameraTex, sampler s) {
    float4 color = cameraTex.sample(s, cameraUV);

    float3 deepBlue   = float3(0.1, 0.2, 0.6);
    float3 portalTint = float3(0.3, 0.6, 1.0);
    float3 rimColor   = float3(0.5, 0.8, 1.0);
    float3 hotColor   = float3(0.9, 0.95, 1.0);
    float3 sparkColor = float3(0.4, 0.7, 1.0);

    // === 1. 传送门内部：多层漩涡扭曲 ===
    if (dist < radius * 1.1) {
        float t = dist / radius;
        float t1 = clamp(t, 0.0, 1.0);

        // 第一层漩涡：主旋转
        float angle1 = (1.0 - t1) * 6.0 + time * 2.5;
        // 第二层漩涡：反向小幅旋转（增加复杂度）
        float angle2 = (1.0 - t1) * 3.0 - time * 1.8;

        float2 dir = pos - ctr;
        float ca1 = cos(angle1), sa1 = sin(angle1);
        float2 newDir1 = float2(dir.x * ca1 - dir.y * sa1, dir.x * sa1 + dir.y * ca1);
        float ca2 = cos(angle2), sa2 = sin(angle2);
        float2 newDir2 = float2(newDir1.x * ca2 - newDir1.y * sa2, newDir1.x * sa2 + newDir1.y * ca2);

        float2 samplePos = ctr + newDir2 * (t1 * 0.9 + 0.05);
        float2 samplePortraitUV = float2(samplePos.x / aspect, samplePos.y);
        samplePortraitUV = clamp(samplePortraitUV, 0.0, 1.0);
        float2 sampleCamUV = toCameraUV(samplePortraitUV, isFront);
        float4 warped = cameraTex.sample(s, sampleCamUV);

        // 内部变暗 + 蓝色调
        warped.rgb *= mix(0.15, 0.7, t1);
        warped.rgb += deepBlue * (1.0 - t1) * 0.6 * I;

        // 闪烁效果
        float shimmer = sin(time * 8.0 + t1 * 20.0) * 0.5 + 0.5;
        warped.rgb += portalTint * shimmer * (1.0 - t1) * 0.3 * I;

        // 能量流动纹理
        float energyFlow = fbm(float2(t1 * 5.0 + time * 0.8, atan2(dir.y, dir.x) * 2.0));
        warped.rgb += portalTint * energyFlow * (1.0 - t1) * 0.25 * I;

        color = mix(color, warped, smoothstep(radius * 1.1, radius * 0.98, dist));
    }

    // === 2. 裂缝线（从中心向外辐射） ===
    float2 dirFromCenter = pos - ctr;
    float angle = atan2(dirFromCenter.y, dirFromCenter.x);
    int numCracks = 8;
    float crackIntensity = 0.0;
    for (int c = 0; c < numCracks; c++) {
        float crackAngle = float(c) / float(numCracks) * 6.28318 + time * 0.3;
        float angleDiff = abs(atan2(sin(angle - crackAngle), cos(angle - crackAngle)));
        // 裂缝宽度随距离变化
        float crackWidth = 0.03 + 0.02 * sin(time * 2.0 + float(c) * 1.7);
        float crack = smoothstep(crackWidth, 0.0, angleDiff) * smoothstep(radius * 1.3, radius * 0.3, dist);
        // 裂缝随机闪烁
        float flicker = step(0.3, hash21(float2(float(c), floor(time * 4.0))));
        crackIntensity += crack * (0.5 + flicker * 0.5);
    }
    crackIntensity = clamp(crackIntensity, 0.0, 1.5);
    color.rgb += hotColor * crackIntensity * 0.6 * I;

    // === 3. 能量粒子（火花） ===
    float2 sparkUv = dirFromCenter * 12.0;
    for (int sp = 0; sp < 3; sp++) {
        float spTime = time * (1.5 + float(sp) * 0.3) + float(sp) * 2.1;
        float2 offset = float2(cos(spTime), sin(spTime * 1.3)) * 0.5;
        float2 sparkPos = sparkUv + offset * 3.0;
        float sparkN = hash21(floor(sparkPos) + floor(spTime));
        float spark = step(0.94, sparkN) * smoothstep(radius * 1.2, 0.0, dist);
        float sparkSize = step(0.94, sparkN) * (1.0 - dist / radius);
        color.rgb += sparkColor * spark * sparkSize * 0.8 * I;
    }

    // === 4. 边缘高光环（双层） ===
    float rimWidth = 0.015;
    float rim = smoothstep(radius, radius - rimWidth, dist)
              - smoothstep(radius - rimWidth, radius - rimWidth * 3.0, dist);
    color.rgb += rimColor * rim * 2.2 * I;

    // 内层细环
    float innerRim = smoothstep(radius * 0.85, radius * 0.85 - 0.008, dist)
                   - smoothstep(radius * 0.85 - 0.008, radius * 0.85 - 0.016, dist);
    color.rgb += hotColor * innerRim * 1.5 * I;

    // === 5. 外发光（更强的扩散光） ===
    float outerGlow = exp(-pow(max(dist - radius, 0.0) * 10.0, 2.0));
    color.rgb += rimColor * outerGlow * 0.9 * I;
    // 第二层柔和外发光
    float softGlow = exp(-pow(max(dist - radius, 0.0) * 5.0, 2.0));
    color.rgb += portalTint * softGlow * 0.3 * I;

    // === 6. 扩散光环 ===
    for (int i = 0; i < 4; i++) {
        float phase = fract(time * 0.4 + float(i) * 0.25);
        float ringDist = radius + phase * 0.35;
        float ring = smoothstep(0.006, 0.0, abs(dist - ringDist));
        color.rgb += rimColor * ring * (1.0 - phase) * 0.5 * I;
    }

    // === 7. 中心亮点 + 能量核心 ===
    float core = exp(-pow(dist * 25.0, 2.0));
    float corePulse = sin(time * 6.0) * 0.3 + 0.7;
    color.rgb += hotColor * core * corePulse * 0.8 * I;

    // 中心能量旋涡
    float swirlNoise = fbm(float2(dist * 15.0 + time * 3.0, angle * 3.0));
    color.rgb += portalTint * swirlNoise * core * 0.5 * I;

    // === 8. 外围微光粒子 ===
    float outerSparkN = hash21(floor(dirFromCenter * 8.0) + floor(time * 5.0));
    float outerSpark = step(0.97, outerSparkN) * smoothstep(radius * 2.0, radius * 0.8, dist)
                     * smoothstep(radius * 0.5, radius * 0.3, dist);
    color.rgb += sparkColor * outerSpark * 0.5 * I;

    // === 9. 空间扭曲色差（强化异能感） ===
    float caStrength = smoothstep(radius * 2.0, radius * 0.5, dist) * 0.006 * I;
    if (caStrength > 0.0005) {
        color.r = mix(color.r, cameraTex.sample(s, cameraUV + float2(caStrength, 0.0)).r, 0.4);
        color.b = mix(color.b, cameraTex.sample(s, cameraUV - float2(caStrength, 0.0)).b, 0.4);
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

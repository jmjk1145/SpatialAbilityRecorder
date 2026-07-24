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
    float2 center1;       // 第一只手位置（视图坐标：左上角原点，0=顶部）
    float2 center2;       // 第二只手位置
    float  hasHand2;      // 是否有第二只手 (0.0 或 1.0)
    float  time;          // 动画时间（秒）
    float  aspect;        // 竖屏宽高比 width/height = 720/1280
    float  radius;        // 特效归一化半径
    float  intensity;     // 特效强度（追踪置信度）
    int    effectType;    // 0空间裂缝 1护盾 2指尖能量网 3闪电 4黑洞 5时空之境
    int    isFrontCamera; // 0后置 1前置
    float  handRotation;  // 累积扭曲角度（弧度，随手部活动持续增长）
    float  twistEnergy;   // 扭曲能量（0~1，手部活动时升高，静止时衰减）
    // 10个指尖位置（归一化坐标 0-1，-1=无效）
    // 索引：手1[0-4]=拇指/食指/中指/无名指/小指，手2[5-9]=同上
    float  tip0X; float  tip0Y;
    float  tip1X; float  tip1Y;
    float  tip2X; float  tip2Y;
    float  tip3X; float  tip3Y;
    float  tip4X; float  tip4Y;
    float  tip5X; float  tip5Y;
    float  tip6X; float  tip6Y;
    float  tip7X; float  tip7Y;
    float  tip8X; float  tip8Y;
    float  tip9X; float  tip9Y;
    float  fingertipCount;
};

// ---- 特效 0：空间扭曲漩涡（漩涡扭曲 + 空间撕裂 + 能量闪电） ----
// 视觉风格：手抓住空间并扭转，画面被漩涡扭曲，中心撕裂出虚空裂缝
// 核心特征："扭" —— 相机画面围绕手部旋转扭曲，手动得越多扭得越剧烈
float4 effectPortal(float2 uv, float2 cameraUV, float2 pos, float2 ctr,
                    float dist, float radius, float time, float I, float aspect,
                    int isFront, texture2d<float> cameraTex, sampler s,
                    float2 ctr1, float2 ctr2, float hasHand2,
                    float handRotation, float twistEnergy) {
    // 调色板
    float3 whiteHot     = float3(1.0, 1.0, 1.0);
    float3 energyCyan   = float3(0.6, 0.9, 1.0);
    float3 electricBlue = float3(0.3, 0.6, 1.0);
    float3 deepVoid     = float3(0.02, 0.02, 0.08);

    float2 dirFromCenter = pos - ctr;
    float r = length(dirFromCenter);
    float baseAngle = atan2(dirFromCenter.y, dirFromCenter.x);

    // === 1. 核心漩涡扭曲（"扭"效果的核心） ===
    // 距离衰减：近中心扭曲最强，边缘平滑过渡
    float falloff = 1.0 - smoothstep(0.0, radius * 2.0, r);
    falloff = pow(falloff, 1.5);
    falloff = clamp(falloff, 0.0, 1.0);

    // 扭曲角度组成：
    // - handRotation：累积扭曲角度（手动得越多，累积越大，漩涡转得越多）
    // - time * 1.5：持续基础旋转（保证静止时也有可见漩涡旋转）
    // - energyMult：twistEnergy 越高手扭得越剧烈（最多 3 倍）
    float baseTwist = handRotation + time * 1.5;
    float energyMult = 1.0 + twistEnergy * 2.0;
    float twistAmount = baseTwist * energyMult;

    // 螺旋分量：中等距离额外扭曲波
    float spiralExtra = sin(r / max(radius, 0.001) * 3.14159) * twistEnergy * 1.5;

    float twistedTheta = baseAngle + (twistAmount + spiralExtra) * falloff;

    // 径向 pinch：向中心拉近像素，增强漩涡吸入感
    float pinch = twistEnergy * 0.25 * falloff;
    float twistedR = r * (1.0 - pinch);

    float2 twistedDir = float2(cos(twistedTheta), sin(twistedTheta)) * twistedR;
    float2 twistedPos = ctr + twistedDir;
    float2 twistedUV = float2(twistedPos.x / aspect, twistedPos.y);
    twistedUV = clamp(twistedUV, 0.0, 1.0);
    float2 twistedCamUV = toCameraUV(twistedUV, isFront);
    float4 color = cameraTex.sample(s, twistedCamUV);

    // === 2. 中心虚空（空间被撕裂的区域） ===
    float voidRadius = radius * 0.25;
    float voidMask = smoothstep(voidRadius, voidRadius * 0.6, r);

    if (voidMask > 0.01) {
        float3 voidColor = deepVoid;
        float voidEnergy = fbm(float2(r * 30.0 + time * 4.0, baseAngle * 4.0 + time * 2.0));
        voidColor += electricBlue * voidEnergy * 0.5;
        voidColor += whiteHot * (1.0 - r / max(voidRadius, 0.001)) * 0.2;
        color.rgb = mix(color.rgb, voidColor, voidMask * I);
    }

    // === 3. 虚空边缘撕裂光（白热边缘） ===
    float tearEdge = smoothstep(voidRadius * 0.6, voidRadius, r)
                   - smoothstep(voidRadius, voidRadius * 1.2, r);
    float tearNoise = fbm(float2(baseAngle * 5.0 + time * 1.0, r * 15.0));
    tearEdge *= 0.5 + tearNoise * 1.0;
    color.rgb += whiteHot * tearEdge * 3.0 * I;

    // === 4. 螺旋能量纹（跟随扭曲方向的能量流） ===
    float spiralAngle = baseAngle + handRotation * 1.5 + time * 1.2;
    float spiralDist = r / max(radius, 0.001);
    float spiralPattern = sin(spiralAngle * 3.0 - spiralDist * 12.0 + time * 3.0);
    float spiralMask = smoothstep(radius * 1.5, 0.0, r) * step(voidRadius, r);
    color.rgb += energyCyan * max(spiralPattern, 0.0) * spiralMask * 0.4 * I;

    float spiral2 = sin(-spiralAngle * 5.0 + spiralDist * 20.0 - time * 2.0);
    color.rgb += electricBlue * max(spiral2, 0.0) * spiralMask * 0.2 * I;

    // === 5. 闪电弧（从中心放射，跟随扭曲旋转） ===
    float lightning = 0.0;
    float lightningCore = 0.0;
    int numBolts = 7;
    for (int b = 0; b < numBolts; b++) {
        float fb = float(b);
        float boltAngle = fb / float(numBolts) * 6.28318 + handRotation * 1.0 + time * 0.5;
        float2 boltDir = float2(cos(boltAngle), sin(boltAngle));

        float along = dot(dirFromCenter, boltDir);
        if (along < 0.0 || along > radius * 1.8) continue;

        float2 perpDir = float2(-boltDir.y, boltDir.x);
        float perp = abs(dot(dirFromCenter, perpDir));

        float jitter = (noise2D(float2(along * 15.0, fb * 7.3 + floor(time * 12.0) * 1.7)) - 0.5) * radius * 0.3;
        perp = abs(perp - jitter);

        float thickness = 0.003 * (1.0 - along / (radius * 1.8)) + 0.0008;
        float bolt = smoothstep(thickness, 0.0, perp) * smoothstep(radius * 1.8, 0.0, along);

        float flicker = step(0.15, hash21(float2(floor(time * 18.0), fb)));
        bolt *= flicker * 0.7 + 0.3;

        lightning += bolt;
        lightningCore += bolt * smoothstep(voidRadius, voidRadius * 2.0, along);
    }

    color.rgb += whiteHot * lightningCore * 2.0 * I;
    color.rgb += energyCyan * lightning * 0.7 * I;

    // === 6. 中心白热核心 ===
    float core = exp(-pow(r * 25.0, 2.0));
    float corePulse = sin(time * 12.0) * 0.2 + 0.8;
    color.rgb += whiteHot * core * corePulse * 1.2 * I;

    // === 7. 能量光晕 ===
    float glowInner = exp(-pow(max(r - voidRadius, 0.0) * 12.0, 2.0));
    color.rgb += energyCyan * glowInner * 0.6 * I;

    float glowOuter = exp(-pow(max(r - radius, 0.0) * 7.0, 2.0));
    color.rgb += electricBlue * glowOuter * 0.4 * I;

    // === 8. 扩散冲击波 ===
    for (int i = 0; i < 3; i++) {
        float phase = fract(time * 0.5 + float(i) * 0.33);
        float ringDist = radius * (0.4 + phase * 1.3);
        float ring = smoothstep(0.006, 0.0, abs(r - ringDist));
        color.rgb += whiteHot * ring * (1.0 - phase) * 0.5 * I;
    }

    // === 9. 能量粒子 ===
    float2 sparkUv = dirFromCenter * 8.0;
    for (int sp = 0; sp < 3; sp++) {
        float spTime = time * (2.5 + float(sp) * 0.5) + float(sp) * 2.1;
        float2 offset = float2(cos(spTime + handRotation), sin(spTime * 1.3 + handRotation)) * 0.3;
        float2 sparkPos = sparkUv + offset * 3.0;
        float sparkN = hash21(floor(sparkPos) + floor(spTime));
        float spark = step(0.94, sparkN) * smoothstep(radius * 1.3, 0.0, r);
        color.rgb += whiteHot * spark * 0.5 * I;
    }

    // === 10. 色差（边缘色彩分离，扭曲越强色差越大） ===
    float caStrength = smoothstep(radius * 1.5, voidRadius, r) * 0.006 * I * (1.0 + twistEnergy);
    if (caStrength > 0.0005) {
        color.r = mix(color.r, cameraTex.sample(s, twistedCamUV + float2(caStrength, 0.0)).r, 0.5);
        color.b = mix(color.b, cameraTex.sample(s, twistedCamUV - float2(caStrength, 0.0)).b, 0.5);
    }

    // === 11. 双手连接闪电 ===
    if (hasHand2 > 0.5) {
        float2 handDir = ctr2 - ctr1;
        float handLen = length(handDir);
        float2 handDirN = handDir / max(handLen, 0.001);
        float2 perpN = float2(-handDirN.y, handDirN.x);

        float2 toPos = pos - ctr1;
        float along = dot(toPos, handDirN);
        float perp = abs(dot(toPos, perpN));

        float jit1 = (noise2D(float2(along * 20.0, floor(time * 12.0) * 1.3)) - 0.5) * handLen * 0.15;
        float jit2 = (noise2D(float2(along * 30.0, floor(time * 15.0) * 2.1 + 5.0)) - 0.5) * handLen * 0.1;
        float jitter = jit1 + jit2;
        perp = abs(perp - jitter);

        float boltThickness = 0.003 + 0.002 * sin(time * 20.0);
        float arc = smoothstep(boltThickness, 0.0, perp) * smoothstep(0.0, 0.02, along) * smoothstep(handLen, handLen - 0.02, along);

        float arcFlicker = step(0.15, hash21(float2(floor(time * 18.0), 0.0)));
        arc *= arcFlicker * 0.7 + 0.3;

        color.rgb += whiteHot * arc * 3.0 * I;
        color.rgb += energyCyan * smoothstep(boltThickness * 3.0, 0.0, perp) * 0.5 * I
                   * smoothstep(0.0, 0.02, along) * smoothstep(handLen, handLen - 0.02, along);

        float sparkAlong = hash21(float2(floor(along * 15.0), floor(time * 8.0)));
        float sparkArc = step(0.92, sparkAlong) * smoothstep(0.0, 0.05, along) * smoothstep(handLen, handLen - 0.05, along);
        color.rgb += whiteHot * sparkArc * 0.4 * I;
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

// ---- 辅助函数：点到线段距离 ----
float pointToSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0001), 0.0, 1.0);
    return length(pa - ba * h);
}

// ---- 特效 2：指尖能量网 ----
// 识别每个指尖位置，在指尖间绘制发光能量节点和连接线，形成能量网络
// 同手内全配对连接（蛛网），跨手对应指尖连接（能量桥）
float4 effectFingertipNetwork(float2 uv, float2 cameraUV, float2 pos,
                              float dist, float radius, float time, float I, float aspect,
                              int isFront, texture2d<float> cameraTex, sampler s,
                              constant PortalParams &params, float2 ctr) {
    float4 color = cameraTex.sample(s, cameraUV);

    // 调色板
    float3 whiteCore = float3(1.0, 1.0, 1.0);
    float3 cyan      = float3(0.3, 0.9, 1.0);
    float3 blue      = float3(0.2, 0.5, 1.0);
    float3 deepBlue  = float3(0.1, 0.3, 0.8);

    // 提取有效指尖位置（归一化坐标 → 像素空间）
    float2 tips[10];
    bool valid[10];

    tips[0] = float2(params.tip0X * aspect, params.tip0Y); valid[0] = params.tip0X >= 0.0;
    tips[1] = float2(params.tip1X * aspect, params.tip1Y); valid[1] = params.tip1X >= 0.0;
    tips[2] = float2(params.tip2X * aspect, params.tip2Y); valid[2] = params.tip2X >= 0.0;
    tips[3] = float2(params.tip3X * aspect, params.tip3Y); valid[3] = params.tip3X >= 0.0;
    tips[4] = float2(params.tip4X * aspect, params.tip4Y); valid[4] = params.tip4X >= 0.0;
    tips[5] = float2(params.tip5X * aspect, params.tip5Y); valid[5] = params.tip5X >= 0.0;
    tips[6] = float2(params.tip6X * aspect, params.tip6Y); valid[6] = params.tip6X >= 0.0;
    tips[7] = float2(params.tip7X * aspect, params.tip7Y); valid[7] = params.tip7X >= 0.0;
    tips[8] = float2(params.tip8X * aspect, params.tip8Y); valid[8] = params.tip8X >= 0.0;
    tips[9] = float2(params.tip9X * aspect, params.tip9Y); valid[9] = params.tip9X >= 0.0;

    // 检查是否有有效指尖
    bool anyValid = false;
    float minTipDist = 999.0;
    for (int i = 0; i < 10; i++) {
        if (valid[i]) {
            anyValid = true;
            minTipDist = min(minTipDist, distance(pos, tips[i]));
        }
    }
    if (!anyValid) return color;

    // 性能优化：远离所有指尖的像素直接返回
    if (minTipDist > 0.5) return color;

    // === 1. 指尖发光节点 ===
    float nodeCore = 0.0;
    float nodeGlow = 0.0;

    for (int i = 0; i < 10; i++) {
        if (!valid[i]) continue;
        float d = distance(pos, tips[i]);
        float pulse = sin(time * 6.0 + float(i) * 1.2) * 0.3 + 0.7;
        float core = exp(-pow(d * 100.0, 2.0)) * pulse;
        float glow = exp(-pow(d * 30.0, 2.0)) * 0.5;
        float halo = exp(-pow(d * 12.0, 2.0)) * 0.2;
        nodeCore = max(nodeCore, core);
        nodeGlow += glow + halo;
    }

    // === 2. 能量连线 ===
    float lineCore = 0.0;
    float lineGlow = 0.0;
    float particleFlow = 0.0;

    // 同手内全配对连接（形成蛛网）
    for (int hand = 0; hand < 2; hand++) {
        int base = hand * 5;
        for (int a = 0; a < 5; a++) {
            for (int b = a + 1; b < 5; b++) {
                int idx1 = base + a;
                int idx2 = base + b;
                if (!valid[idx1] || !valid[idx2]) continue;

                float2 pa = tips[idx1];
                float2 pb = tips[idx2];
                float d = pointToSegment(pos, pa, pb);

                float thickness = 0.003;
                float core = smoothstep(thickness, 0.0, d);
                float glow = smoothstep(thickness * 5.0, 0.0, d) * 0.3;

                lineCore = max(lineCore, core);
                lineGlow += glow * 0.25;

                // 流动粒子
                float2 ba = pb - pa;
                float lineLen = length(ba);
                float2 dir = ba / max(lineLen, 0.001);
                float along = clamp(dot(pos - pa, dir) / max(lineLen, 0.001), 0.0, 1.0);
                float flow = fract(along * 2.0 - time * 1.2 + float(idx1) * 0.3);
                float particle = smoothstep(0.04, 0.0, abs(flow - 0.5)) * core;
                particleFlow += particle * 0.4;
            }
        }
    }

    // 跨手连接（对应指尖：拇指-拇指，食指-食指...）
    for (int i = 0; i < 5; i++) {
        int idx1 = i;
        int idx2 = i + 5;
        if (!valid[idx1] || !valid[idx2]) continue;

        float2 pa = tips[idx1];
        float2 pb = tips[idx2];
        float d = pointToSegment(pos, pa, pb);

        float thickness = 0.004;
        float core = smoothstep(thickness, 0.0, d);
        float glow = smoothstep(thickness * 4.0, 0.0, d) * 0.4;

        lineCore = max(lineCore, core);
        lineGlow += glow * 0.5;

        // 双向流动粒子
        float2 ba = pb - pa;
        float lineLen = length(ba);
        float2 dir = ba / max(lineLen, 0.001);
        float along = clamp(dot(pos - pa, dir) / max(lineLen, 0.001), 0.0, 1.0);
        float flow1 = fract(along * 3.0 - time * 1.5);
        float flow2 = fract(along * 3.0 + time * 1.0);
        float particle = smoothstep(0.03, 0.0, abs(flow1 - 0.5)) * core;
        particle += smoothstep(0.03, 0.0, abs(flow2 - 0.5)) * core;
        particleFlow += particle * 0.6;
    }

    // === 3. 指尖附近空间扭曲 ===
    float warpStrength = 0.0;
    float2 warpDir = float2(0.0);
    for (int i = 0; i < 10; i++) {
        if (!valid[i]) continue;
        float d = distance(pos, tips[i]);
        float warp = exp(-pow(d * 15.0, 2.0)) * 0.01;
        warpStrength += warp;
        if (d > 0.001) {
            warpDir += (pos - tips[i]) / d * warp;
        }
    }

    if (warpStrength > 0.001) {
        float2 warpedUV = uv + warpDir * warpStrength * I;
        warpedUV = clamp(warpedUV, 0.0, 1.0);
        float2 warpedCamUV = toCameraUV(warpedUV, isFront);
        float4 warpedColor = cameraTex.sample(s, warpedCamUV);
        color.rgb = mix(color.rgb, warpedColor.rgb, min(warpStrength * 30.0 * I, 0.5));
    }

    // === 4. 能量场背景 ===
    float fieldEnergy = 0.0;
    for (int i = 0; i < 10; i++) {
        if (!valid[i]) continue;
        float d = distance(pos, tips[i]);
        fieldEnergy += exp(-pow(d * 5.0, 2.0)) * 0.1;
    }
    fieldEnergy = min(fieldEnergy, 0.3);
    color.rgb += deepBlue * fieldEnergy * I;

    // === 5. 应用颜色 ===
    color.rgb += whiteCore * nodeCore * 1.5 * I;
    color.rgb += cyan * nodeGlow * 0.8 * I;
    color.rgb += whiteCore * lineCore * 2.0 * I;
    color.rgb += blue * lineGlow * I;
    color.rgb += whiteCore * particleFlow * 1.5 * I;

    // === 6. 色差效果 ===
    if (nodeCore > 0.1 || lineCore > 0.1) {
        float ca = 0.003 * I;
        color.r = mix(color.r, cameraTex.sample(s, cameraUV + float2(ca, 0.0)).r, 0.3);
        color.b = mix(color.b, cameraTex.sample(s, cameraUV - float2(ca, 0.0)).b, 0.3);
    }

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

// HSV → RGB 转换（用于彩色渐变）
float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// ---- 特效 5：时空之境（液态玻璃 + 彩色渐变 + 指尖连接） ----
// iOS 26 Liquid Glass 风格：半透明多层玻璃 + 彩虹渐变指尖连接 + 折射模糊
float4 effectSpacetimeRealm(float2 uv, float2 cameraUV, float2 pos,
                             float dist, float radius, float time, float I, float aspect,
                             int isFront, texture2d<float> cameraTex, sampler s,
                             constant PortalParams &params, float2 ctr) {

    // 提取指尖位置
    float2 tips[10];
    bool valid[10];
    tips[0] = float2(params.tip0X * aspect, params.tip0Y); valid[0] = params.tip0X >= 0.0;
    tips[1] = float2(params.tip1X * aspect, params.tip1Y); valid[1] = params.tip1X >= 0.0;
    tips[2] = float2(params.tip2X * aspect, params.tip2Y); valid[2] = params.tip2X >= 0.0;
    tips[3] = float2(params.tip3X * aspect, params.tip3Y); valid[3] = params.tip3X >= 0.0;
    tips[4] = float2(params.tip4X * aspect, params.tip4Y); valid[4] = params.tip4X >= 0.0;
    tips[5] = float2(params.tip5X * aspect, params.tip5Y); valid[5] = params.tip5X >= 0.0;
    tips[6] = float2(params.tip6X * aspect, params.tip6Y); valid[6] = params.tip6X >= 0.0;
    tips[7] = float2(params.tip7X * aspect, params.tip7Y); valid[7] = params.tip7X >= 0.0;
    tips[8] = float2(params.tip8X * aspect, params.tip8Y); valid[8] = params.tip8X >= 0.0;
    tips[9] = float2(params.tip9X * aspect, params.tip9Y); valid[9] = params.tip9X >= 0.0;

    bool anyValid = false;
    for (int i = 0; i < 10; i++) {
        if (valid[i]) { anyValid = true; break; }
    }

    // 基础颜色：相机采样
    float4 color = cameraTex.sample(s, cameraUV);

    if (!anyValid) return color;

    // === 1. 找到最近的指尖 ===
    float minTipDist = 999.0;
    int nearestTip = -1;
    for (int i = 0; i < 10; i++) {
        if (!valid[i]) continue;
        float d = distance(pos, tips[i]);
        if (d < minTipDist) {
            minTipDist = d;
            nearestTip = i;
        }
    }

    // 性能优化：远离所有指尖的像素跳过玻璃效果
    float glassRadius = 0.12;
    bool nearTip = (nearestTip >= 0) && (minTipDist < glassRadius);

    // === 2. 液态玻璃效果（iOS 26 Liquid Glass 风格） ===
    if (nearTip) {
        float2 tipPos = tips[nearestTip];
        float2 dirFromTip = pos - tipPos;
        float tipDist = length(dirFromTip);
        float glassFalloff = 1.0 - smoothstep(0.0, glassRadius, tipDist);
        glassFalloff = pow(glassFalloff, 0.8);

        // 折射：通过玻璃看后面的画面，产生扭曲
        float2 refractDir = normalize(dirFromTip);
        float refractStrength = glassFalloff * 0.015 * I;
        float2 refractUV = uv + refractDir * refractStrength;
        refractUV = clamp(refractUV, 0.0, 1.0);
        float2 refractCamUV = toCameraUV(refractUV, isFront);

        // 毛玻璃模糊：多方向采样取平均
        float blurRadius = 0.002 * glassFalloff;
        float2 blurOffsets[6] = {
            float2(1.0, 0.0), float2(-1.0, 0.0),
            float2(0.0, 1.0), float2(0.0, -1.0),
            float2(0.707, 0.707), float2(-0.707, -0.707)
        };
        float4 blurred = float4(0.0);
        for (int b = 0; b < 6; b++) {
            float2 blurUV = clamp(refractUV + blurOffsets[b] * blurRadius, 0.0, 1.0);
            blurred += cameraTex.sample(s, toCameraUV(blurUV, isFront));
        }
        blurred /= 6.0;

        // 混合折射和模糊 = 液态玻璃效果
        float4 glassColor = mix(blurred, cameraTex.sample(s, refractCamUV), 0.4);

        // 彩色渐变叠加：每个指尖有不同的色调
        float hue = float(nearestTip) / 10.0 + time * 0.08;
        float3 gradientColor = hsv2rgb(float3(hue, 0.6, 1.0));

        // 半透明玻璃混合（iOS 26 风格：通透但有色彩）
        float glassAlpha = glassFalloff * 0.45 * I;
        color.rgb = mix(color.rgb, glassColor.rgb * 0.8 + gradientColor * 0.2, glassAlpha);

        // 玻璃边缘高光（液态玻璃的标志性边缘光）
        float edgeDist = tipDist / glassRadius;
        float edgeHighlight = smoothstep(0.7, 0.95, edgeDist) * (1.0 - smoothstep(0.95, 1.0, edgeDist));
        color.rgb += gradientColor * edgeHighlight * 2.5 * I;

        // 内部光泽（玻璃球顶部的反光）
        float2 lightDir = normalize(float2(0.3, -0.5));
        float specular = max(dot(normalize(dirFromTip), lightDir), 0.0);
        specular = pow(specular, 8.0) * glassFalloff;
        color.rgb += float3(1.0, 1.0, 1.0) * specular * 0.6 * I;

        // 玻璃中心光晕
        float coreGlow = exp(-pow(tipDist * 30.0, 2.0));
        float3 coreColor = hsv2rgb(float3(hue + 0.5, 0.4, 1.0));
        color.rgb += coreColor * coreGlow * 0.8 * I;
    }

    // === 3. 彩色渐变指尖连接线 ===
    float lineIntensity = 0.0;
    float3 lineColor = float3(0.0);
    float particleFlow = 0.0;
    float3 particleColor = float3(0.0);

    // 同手内连接（蛛网）
    for (int hand = 0; hand < 2; hand++) {
        int base = hand * 5;
        for (int a = 0; a < 5; a++) {
            for (int b = a + 1; b < 5; b++) {
                int idx1 = base + a;
                int idx2 = base + b;
                if (!valid[idx1] || !valid[idx2]) continue;

                float2 pa = tips[idx1];
                float2 pb = tips[idx2];
                float d = pointToSegment(pos, pa, pb);

                float thickness = 0.0035;
                float core = smoothstep(thickness, 0.0, d);
                float glow = smoothstep(thickness * 4.0, 0.0, d) * 0.3;

                // 沿线的渐变色（从 idx1 的色到 idx2 的色）
                float2 ba = pb - pa;
                float lineLen = length(ba);
                float2 dir = ba / max(lineLen, 0.001);
                float along = clamp(dot(pos - pa, dir) / max(lineLen, 0.001), 0.0, 1.0);

                float hue1 = float(idx1) / 10.0 + time * 0.08;
                float hue2 = float(idx2) / 10.0 + time * 0.08;
                float lineHue = mix(hue1, hue2, along);
                float3 gradColor = hsv2rgb(float3(lineHue, 0.7, 1.0));

                lineIntensity = max(lineIntensity, core + glow * 0.5);
                lineColor += gradColor * (core * 1.5 + glow * 0.3);

                // 流动粒子
                float flow = fract(along * 2.0 - time * 1.5 + float(idx1) * 0.3);
                float particle = smoothstep(0.04, 0.0, abs(flow - 0.5)) * core;
                particleFlow += particle;
                particleColor += hsv2rgb(float3(lineHue + 0.3, 0.5, 1.0)) * particle * 0.5;
            }
        }
    }

    // 跨手连接
    for (int i = 0; i < 5; i++) {
        int idx1 = i;
        int idx2 = i + 5;
        if (!valid[idx1] || !valid[idx2]) continue;

        float2 pa = tips[idx1];
        float2 pb = tips[idx2];
        float d = pointToSegment(pos, pa, pb);

        float thickness = 0.004;
        float core = smoothstep(thickness, 0.0, d);
        float glow = smoothstep(thickness * 3.5, 0.0, d) * 0.4;

        float2 ba = pb - pa;
        float lineLen = length(ba);
        float2 dir = ba / max(lineLen, 0.001);
        float along = clamp(dot(pos - pa, dir) / max(lineLen, 0.001), 0.0, 1.0);

        float hue1 = float(idx1) / 10.0 + time * 0.08;
        float hue2 = float(idx2) / 10.0 + time * 0.08;
        float lineHue = mix(hue1, hue2, along);
        float3 gradColor = hsv2rgb(float3(lineHue, 0.8, 1.0));

        lineIntensity = max(lineIntensity, core + glow * 0.5);
        lineColor += gradColor * (core * 2.0 + glow * 0.4);

        // 双向流动粒子
        float flow1 = fract(along * 3.0 - time * 1.5);
        float flow2 = fract(along * 3.0 + time * 1.0);
        float particle = smoothstep(0.03, 0.0, abs(flow1 - 0.5)) * core;
        particle += smoothstep(0.03, 0.0, abs(flow2 - 0.5)) * core;
        particleFlow += particle;
        particleColor += hsv2rgb(float3(lineHue + 0.3, 0.6, 1.0)) * particle * 0.8;
    }

    // 应用连接线颜色
    color.rgb += lineColor * I;
    color.rgb += particleColor * I;

    // === 4. 能量场背景辉光 ===
    float fieldGlow = 0.0;
    float3 fieldColor = float3(0.0);
    for (int i = 0; i < 10; i++) {
        if (!valid[i]) continue;
        float d = distance(pos, tips[i]);
        float glow = exp(-pow(d * 6.0, 2.0)) * 0.08;
        fieldGlow += glow;
        float hue = float(i) / 10.0 + time * 0.08;
        fieldColor += hsv2rgb(float3(hue, 0.5, 1.0)) * glow;
    }
    fieldGlow = min(fieldGlow, 0.25);
    color.rgb += fieldColor * I;

    // === 5. 全局色差（液态玻璃的色散效果） ===
    if (nearTip || lineIntensity > 0.1) {
        float ca = 0.004 * I;
        color.r = mix(color.r, cameraTex.sample(s, cameraUV + float2(ca, 0.0)).r, 0.3);
        color.b = mix(color.b, cameraTex.sample(s, cameraUV - float2(ca, 0.0)).b, 0.3);
    }

    return color;
}

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

    // === 双手智能锚点 ===
    // 单手：特效中心在食指尖
    // 双手：特效中心在两手之间中点，半径随两手距离缩放
    float2 ctr1 = float2(params.center1.x * aspect, params.center1.y);
    float2 ctr2 = float2(params.center2.x * aspect, params.center2.y);
    float2 ctr;
    float radius;

    if (params.hasHand2 > 0.5) {
        // 双手：中点为中心，距离决定半径
        ctr = (ctr1 + ctr2) * 0.5;
        float handDist = distance(ctr1, ctr2);
        // 半径 = 两手距离的一半 + 基础值
        radius = handDist * 0.5 + params.radius * 0.3;
        radius = clamp(radius, 0.08, 0.6);
    } else {
        // 单手：食指尖为中心
        ctr = ctr1;
        radius = params.radius;
    }

    float dist = distance(pos, ctr);
    float I = params.intensity;

    if (I < 0.005) {
        return cameraTex.sample(s, cameraUV);
    }

    switch (params.effectType) {
        case 0:
            return effectPortal(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, params.isFrontCamera, cameraTex, s, ctr1, ctr2, params.hasHand2, params.handRotation, params.twistEnergy);
        case 1:
            return effectShield(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, params.isFrontCamera, cameraTex, s);
        case 2:
            return effectFingertipNetwork(uv, cameraUV, pos, dist, radius, params.time, I, aspect, params.isFrontCamera, cameraTex, s, params, ctr);
        case 3:
            return effectLightning(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, params.isFrontCamera, cameraTex, s);
        case 4:
            return effectBlackHole(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, params.isFrontCamera, cameraTex, s);
        case 5:
            return effectSpacetimeRealm(uv, cameraUV, pos, dist, radius, params.time, I, aspect, params.isFrontCamera, cameraTex, s, params, ctr);
        default:
            return effectPortal(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, params.isFrontCamera, cameraTex, s, ctr1, ctr2, params.hasHand2, params.handRotation, params.twistEnergy);
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

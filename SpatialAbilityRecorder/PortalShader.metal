#include <metal_stdlib>
using namespace metal;

// MARK: - 顶点

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

/// 全屏三角形（覆盖整个 NDC 空间），UV 范围 [0,1]。
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
    out.uv = uvs[vid];
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

// MARK: - 片元：空间异能特效

struct PortalParams {
    float2 center;        // 归一化锚点（视图坐标：左上角原点）
    float  time;          // 动画时间（秒）
    float  aspect;        // 纹理宽高比 width/height
    float  radius;        // 特效归一化半径
    float  intensity;     // 特效强度（追踪置信度）
    int    effectType;    // 特效类型：0传送门 1护盾 2烈焰 3闪电 4黑洞
    float  _pad0;
    float  _pad1;
    float  _pad2;
};

// ---- 特效 0：空间传送门（漩涡扭曲） ----
float4 effectPortal(float2 uv, float2 cameraUV, float2 pos, float2 ctr,
                    float dist, float radius, float time, float I, float aspect,
                    texture2d<float> cameraTex, sampler s) {
    float4 color = cameraTex.sample(s, cameraUV);

    float3 portalTint = float3(0.25, 0.55, 1.0);
    float3 rimColor   = float3(0.45, 0.75, 1.0);

    // 传送门内部：漩涡扭曲
    if (dist < radius) {
        float t = dist / radius;
        float angle = (1.0 - t) * 5.5 + time * 2.2;
        float2 dir = pos - ctr;
        float ca = cos(angle), sa = sin(angle);
        float2 newDir = float2(dir.x * ca - dir.y * sa, dir.x * sa + dir.y * ca);
        float2 samplePos = ctr + newDir * (t * 0.85);
        // 从等比像素空间转回 UV 空间（pos.x = uv.x * aspect）
        float2 sampleUV = float2(samplePos.x / aspect, samplePos.y);
        sampleUV = clamp(sampleUV, 0.0, 1.0);
        float4 warped = cameraTex.sample(s, float2(sampleUV.x, 1.0 - sampleUV.y));
        warped.rgb *= mix(0.35, 0.9, t);
        warped.rgb += portalTint * (1.0 - t) * 0.45 * I;
        float shimmer = sin(time * 7.0 + t * 18.0) * 0.5 + 0.5;
        warped.rgb += portalTint * shimmer * (1.0 - t) * 0.25 * I;
        color = mix(color, warped, smoothstep(radius, radius - 0.005, dist));
    }

    // 边缘高光环
    float rimWidth = 0.012;
    float rim = smoothstep(radius, radius - rimWidth, dist)
              - smoothstep(radius - rimWidth, radius - rimWidth * 2.5, dist);
    color.rgb += rimColor * rim * 1.8 * I;

    // 外发光
    float outerGlow = exp(-pow(max(dist - radius, 0.0) * 14.0, 2.0));
    color.rgb += rimColor * outerGlow * 0.7 * I;

    // 扩散光环
    for (int i = 0; i < 3; i++) {
        float phase = fract(time * 0.45 + float(i) * 0.333);
        float ringDist = radius + phase * 0.32;
        float ring = smoothstep(0.008, 0.0, abs(dist - ringDist));
        color.rgb += rimColor * ring * (1.0 - phase) * 0.45 * I;
    }

    // 中心亮点
    float core = exp(-pow(dist * 30.0, 2.0));
    color.rgb += float3(0.8, 0.9, 1.0) * core * 0.6 * I;

    return color;
}

// ---- 特效 1：能量护盾（六边形蜂窝） ----
float4 effectShield(float2 uv, float2 cameraUV, float2 pos, float2 ctr,
                    float dist, float radius, float time, float I, float aspect,
                    texture2d<float> cameraTex, sampler s) {
    float4 color = cameraTex.sample(s, cameraUV);

    float3 shieldColor = float3(0.1, 0.8, 0.6);
    float3 edgeColor   = float3(0.3, 1.0, 0.8);

    // 六边形蜂窝网格
    float2 hexUv = pos - ctr;
    hexUv.y /= 0.866; // sqrt(3)/2，使六边形等比
    float2 h = float2(hexUv.x * 1.5, hexUv.y);
    float2 a = mod(h, 1.0) - 0.5;
    float hex = abs(a.x) + abs(a.y) * 0.5 + abs(a.x - a.y) * 0.5;
    float hexLine = smoothstep(0.45, 0.5, hex);

    // 仅在护盾范围内显示网格
    float shieldMask = smoothstep(radius, radius - 0.01, dist);
    hexLine *= shieldMask;

    // 脉冲波纹
    float pulse = sin(dist * 30.0 - time * 4.0) * 0.5 + 0.5;
    pulse *= shieldMask;

    // 能量场半透明覆盖
    color.rgb = mix(color.rgb, shieldColor * 0.3, shieldMask * 0.35 * I);

    // 蜂窝网格线
    color.rgb += shieldColor * hexLine * 0.8 * I;
    color.rgb += edgeColor * pulse * 0.3 * I;

    // 边缘高光环
    float rimWidth = 0.015;
    float rim = smoothstep(radius, radius - rimWidth, dist)
              - smoothstep(radius - rimWidth, radius - rimWidth * 2.5, dist);
    color.rgb += edgeColor * rim * 2.0 * I;

    // 外发光
    float outerGlow = exp(-pow(max(dist - radius, 0.0) * 12.0, 2.0));
    color.rgb += edgeColor * outerGlow * 0.6 * I;

    // 扩散冲击波
    for (int i = 0; i < 2; i++) {
        float phase = fract(time * 0.3 + float(i) * 0.5);
        float ringDist = radius + phase * 0.4;
        float ring = smoothstep(0.01, 0.0, abs(dist - ringDist));
        color.rgb += edgeColor * ring * (1.0 - phase) * 0.5 * I;
    }

    // 中心能量点
    float core = exp(-pow(dist * 20.0, 2.0));
    color.rgb += float3(0.5, 1.0, 0.9) * core * 0.4 * I;

    return color;
}

// ---- 特效 2：烈焰能量 ----
float4 effectFire(float2 uv, float2 cameraUV, float2 pos, float2 ctr,
                  float dist, float radius, float time, float I, float aspect,
                  texture2d<float> cameraTex, sampler s) {
    float4 color = cameraTex.sample(s, cameraUV);

    // 火焰噪声（向上飘动）
    float2 fireUv = (pos - ctr) * float2(8.0, 8.0);
    fireUv.y -= time * 1.5;
    float n = fbm(fireUv + float2(time * 0.3, 0.0));
    float n2 = fbm(fireUv * 2.0 + float2(0.0, -time * 2.0));

    // 火焰形状：从中心向上扩散，底部最热
    float fireShape = smoothstep(radius, 0.0, dist);
    // pos.y > ctr.y 时火焰更强（向上=屏幕上方）
    float upFactor = smoothstep(0.0, radius, pos.y - ctr.y + radius * 0.3);
    fireShape *= upFactor * 0.7 + 0.3;

    float fire = n * fireShape * 1.5;
    fire = clamp(fire, 0.0, 1.5);

    // 火焰颜色：底部白热 → 黄 → 橙 → 红
    float3 hotColor  = float3(1.0, 0.95, 0.8);
    float3 midColor  = float3(1.0, 0.6, 0.15);
    float3 coolColor = float3(0.9, 0.2, 0.05);

    float3 fireColor = mix(coolColor, midColor, smoothstep(0.0, 0.5, fire));
    fireColor = mix(fireColor, hotColor, smoothstep(0.5, 0.9, fire));

    // 火花粒子
    float2 sparkUv = pos - ctr;
    float sparkN = hash21(floor(sparkUv * 20.0) + floor(time * 3.0));
    float spark = step(0.96, sparkN) * fireShape;

    // 混合火焰到画面
    float fireMask = fire * I * 0.8;
    color.rgb = mix(color.rgb, fireColor, fireMask);
    color.rgb += fireColor * fire * 0.3 * I;

    // 火花
    color.rgb += hotColor * spark * 0.5 * I;

    // 边缘热扭曲
    float distortMask = smoothstep(radius, radius - 0.05, dist) * I;
    float distort = n2 * 0.02;
    float2 distortUV = cameraUV + float2(distort, -distort * 0.5) * distortMask;
    distortUV = clamp(distortUV, 0.0, 1.0);
    float4 distorted = cameraTex.sample(s, distortUV);
    color.rgb = mix(color.rgb, distorted.rgb, distortMask * 0.4);

    // 中心核心光
    float core = exp(-pow(dist * 18.0, 2.0));
    color.rgb += float3(1.0, 0.9, 0.6) * core * 0.5 * I;

    // 外发光（暖色）
    float outerGlow = exp(-pow(max(dist - radius * 0.8, 0.0) * 10.0, 2.0));
    color.rgb += float3(1.0, 0.4, 0.1) * outerGlow * 0.4 * I;

    return color;
}

// ---- 特效 3：闪电链 ----
float4 effectLightning(float2 uv, float2 cameraUV, float2 pos, float2 ctr,
                       float dist, float radius, float time, float I, float aspect,
                       texture2d<float> cameraTex, sampler s) {
    float4 color = cameraTex.sample(s, cameraUV);

    float3 boltColor  = float3(0.5, 0.7, 1.0);
    float3 coreColor  = float3(0.9, 0.95, 1.0);
    float3 sparkColor = float3(0.6, 0.4, 1.0);

    // 闪电分支：基于噪声生成多条从中心向外的闪电路径
    float bolt = 0.0;
    float coreBolt = 0.0;
    int numBolts = 7;
    for (int i = 0; i < numBolts; i++) {
        float fi = float(i);
        float angle = fi / float(numBolts) * 6.28318 + time * 0.5;
        float2 dir = float2(cos(angle), sin(angle));

        // 沿射线方向的距离
        float along = dot(pos - ctr, dir);
        if (along < 0.0 || along > radius * 1.5) continue;

        // 垂直方向的偏移（噪声调制）
        float2 perpUv = float2(along * 12.0, fi * 7.3 + floor(time * 8.0) * 1.7);
        float wobble = (noise2D(perpUv) - 0.5) * radius * 0.4;
        float2 realDir = dir;
        float perp = abs(dot(pos - ctr, float2(-realDir.y, realDir.x)) - wobble);

        // 闪电粗细随距离衰减
        float thickness = 0.006 * (1.0 - along / (radius * 1.5));
        float b = smoothstep(thickness, 0.0, perp);
        bolt += b;
        coreBolt += b * smoothstep(0.0, 0.3, along);
    }

    // 闪电闪烁
    float flicker = step(0.3, hash21(float2(floor(time * 12.0), 0.0)));
    bolt *= flicker * 0.7 + 0.3;

    // 中心电球
    float core = exp(-pow(dist * 22.0, 2.0));
    float corePulse = sin(time * 15.0) * 0.3 + 0.7;
    core *= corePulse;

    // 电火花粒子
    float2 sparkUv = (pos - ctr) * 15.0;
    float sparkN = hash21(floor(sparkUv) + floor(time * 10.0));
    float sparks = step(0.93, sparkN) * smoothstep(radius, 0.0, dist);

    // 混合
    color.rgb += boltColor * bolt * 1.5 * I;
    color.rgb += coreColor * coreBolt * bolt * 2.0 * I;
    color.rgb += coreColor * core * 0.8 * I;
    color.rgb += sparkColor * sparks * 0.6 * I;

    // 外围电磁场
    float fieldMask = smoothstep(radius * 1.2, 0.0, dist);
    float field = noise2D((pos - ctr) * 6.0 + time * 2.0) * fieldMask;
    color.rgb += boltColor * field * 0.15 * I;

    // 边缘电弧环
    float ringDist = radius;
    float arc = smoothstep(0.01, 0.0, abs(dist - ringDist));
    arc *= flicker * 0.5 + 0.5;
    color.rgb += boltColor * arc * 0.8 * I;

    return color;
}

// ---- 特效 4：黑洞引力 ----
float4 effectBlackHole(float2 uv, float2 cameraUV, float2 pos, float2 ctr,
                       float dist, float radius, float time, float I, float aspect,
                       texture2d<float> cameraTex, sampler s) {
    float3 accretionColor = float3(1.0, 0.5, 0.1);
    float3 hotColor       = float3(1.0, 0.85, 0.4);
    float3 rimColor       = float3(0.4, 0.2, 0.6);

    // 事件视界半径（黑洞中心黑色区域）
    float eventHorizon = radius * 0.35;

    float4 color;

    if (dist < eventHorizon) {
        // 事件视界内：纯黑
        color = float4(0.0, 0.0, 0.0, 1.0);
    } else {
        // 引力透镜：扭曲周围画面（向中心弯曲）
        float2 dir = normalize(pos - ctr);
        float bendStrength = (radius / max(dist, 0.001)) * 0.3 * I;
        float2 bentPos = pos - dir * bendStrength * radius;
        // 从等比像素空间转回 UV 空间
        float2 bentUV = float2(bentPos.x / aspect, bentPos.y);
        bentUV = clamp(bentUV, 0.0, 1.0);
        color = cameraTex.sample(s, float2(bentUV.x, 1.0 - bentUV.y));

        // 吸积盘：旋转的发光环
        float2 diskPos = pos - ctr;
        float diskAngle = atan2(diskPos.y, diskPos.x);
        float diskDist = dist;
        // 多普勒效应：旋转方向一侧更亮
        float doppler = sin(diskAngle - time * 3.0) * 0.5 + 0.5;

        // 吸积盘环带
        float diskInner = eventHorizon * 1.1;
        float diskOuter = radius * 0.9;
        float diskMask = smoothstep(diskInner, diskInner + 0.01, dist)
                       * smoothstep(diskOuter, diskOuter - 0.05, dist);

        // 盘内螺旋纹理
        float spiral = sin(diskAngle * 3.0 + diskDist * 25.0 - time * 4.0) * 0.5 + 0.5;
        float diskNoise = noise2D(float2(diskDist * 20.0, diskAngle * 2.0 + time * 2.0));

        float3 diskColor = mix(accretionColor, hotColor, doppler);
        diskColor = mix(diskColor, diskColor * 1.5, spiral);
        diskColor = mix(diskColor, diskColor * 0.7, diskNoise);

        float diskIntensity = diskMask * (1.0 + doppler * 0.5);
        color.rgb = mix(color.rgb, diskColor, diskIntensity * I);

        // 光子环（事件视界边缘的亮环）
        float photonRing = exp(-pow((dist - eventHorizon) * 40.0, 2.0));
        color.rgb += hotColor * photonRing * 1.5 * I;

        // 引力红移：靠近视界的画面偏红
        float redshift = smoothstep(radius, eventHorizon, dist) * 0.3 * I;
        color.rgb = mix(color.rgb, float3(color.r, color.g * 0.7, color.b * 0.5), redshift);

        // 外围引力透镜辉光
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

    float2 uv = in.uv;
    float aspect = params.aspect;

    // 相机 CVPixelBuffer 第一行在顶部，Metal UV v=0 在底部 → 采样时翻转 V
    float2 cameraUV = float2(uv.x, 1.0 - uv.y);

    // 把坐标变换到"等比像素空间"，使距离计算不被拉伸影响
    float2 pos = float2(uv.x * aspect, uv.y);
    // 追踪点 centerY 为视图坐标（0=顶部, 1=底部），UV 空间 0=底部 → 翻转
    float2 ctr = float2(params.center.x * aspect, 1.0 - params.center.y);

    float dist = distance(pos, ctr);
    float radius = params.radius;
    float I = params.intensity;

    // 如果没有追踪，直接返回相机画面
    if (I < 0.01) {
        return cameraTex.sample(s, cameraUV);
    }

    // 根据特效类型调用不同的特效函数
    switch (params.effectType) {
        case 0:
            return effectPortal(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, cameraTex, s);
        case 1:
            return effectShield(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, cameraTex, s);
        case 2:
            return effectFire(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, cameraTex, s);
        case 3:
            return effectLightning(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, cameraTex, s);
        case 4:
            return effectBlackHole(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, cameraTex, s);
        default:
            return effectPortal(uv, cameraUV, pos, ctr, dist, radius, params.time, I, aspect, cameraTex, s);
    }
}

// MARK: - 简单纹理拷贝（用于将离屏渲染结果绘制到 drawable）

fragment float4 blit_fragment(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}

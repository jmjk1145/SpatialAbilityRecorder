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

// MARK: - 片元：空间异能传送门特效

struct PortalParams {
    float2 center;        // 归一化锚点（纹理坐标，左下角为原点）
    float  time;          // 动画时间（秒）
    float  aspect;        // 纹理宽高比 width/height
    float  radius;        // 传送门归一化半径
    float  intensity;     // 特效强度（追踪置信度）
    float  _pad0;
    float  _pad1;
    float  _pad2;
};

fragment float4 portal_fragment(VertexOut in [[stage_in]],
                                texture2d<float> cameraTex [[texture(0)]],
                                constant PortalParams &params [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float aspect = params.aspect;

    // 相机 CVPixelBuffer 第一行在顶部，Metal UV v=0 在底部 → 采样时翻转 V
    float2 cameraUV = float2(uv.x, 1.0 - uv.y);

    // 把坐标变换到“等比像素空间”，使距离计算不被拉伸影响
    float2 pos = float2(uv.x * aspect, uv.y);
    // 追踪点 centerY 为视图坐标（0=顶部, 1=底部），UV 空间 0=底部 → 翻转
    float2 ctr = float2(params.center.x * aspect, 1.0 - params.center.y);

    float dist = distance(pos, ctr);
    float radius = params.radius;

    // 基础相机画面（使用翻转后的 UV）
    float4 color = cameraTex.sample(s, cameraUV);

    // 特效色（空间蓝紫）
    float3 portalTint = float3(0.25, 0.55, 1.0);
    float3 rimColor   = float3(0.45, 0.75, 1.0);
    float I = params.intensity;

    // ---- 传送门内部：漩涡扭曲 ----
    if (dist < radius) {
        float t = dist / radius;               // 0 中心 → 1 边缘
        float angle = (1.0 - t) * 5.5 + params.time * 2.2;
        float2 dir = pos - ctr;
        float ca = cos(angle), sa = sin(angle);
        float2 newDir = float2(dir.x * ca - dir.y * sa, dir.x * sa + dir.y * ca);
        // 向中心收缩采样，制造吸入感
        float2 samplePos = ctr + newDir * (t * 0.85);
        float2 sampleUV = float2(samplePos.x / aspect, samplePos.y);
        sampleUV = clamp(sampleUV, 0.0, 1.0);
        // 采样相机时同样翻转 V
        float4 warped = cameraTex.sample(s, float2(sampleUV.x, 1.0 - sampleUV.y));
        warped.rgb *= mix(0.35, 0.9, t);
        // 中心蓝紫染色
        warped.rgb += portalTint * (1.0 - t) * 0.45 * I;
        // 流光闪烁
        float shimmer = sin(params.time * 7.0 + t * 18.0) * 0.5 + 0.5;
        warped.rgb += portalTint * shimmer * (1.0 - t) * 0.25 * I;
        color = mix(color, warped, smoothstep(radius, radius - 0.005, dist));
    }

    // ---- 边缘高光环 ----
    float rimWidth = 0.012;
    float rim = smoothstep(radius, radius - rimWidth, dist)
              - smoothstep(radius - rimWidth, radius - rimWidth * 2.5, dist);
    color.rgb += rimColor * rim * 1.8 * I;

    // ---- 外发光 ----
    float outerGlow = exp(-pow(max(dist - radius, 0.0) * 14.0, 2.0));
    color.rgb += rimColor * outerGlow * 0.7 * I;

    // ---- 扩散光环 ----
    for (int i = 0; i < 3; i++) {
        float phase = fract(params.time * 0.45 + float(i) * 0.333);
        float ringDist = radius + phase * 0.32;
        float ring = smoothstep(0.008, 0.0, abs(dist - ringDist));
        color.rgb += rimColor * ring * (1.0 - phase) * 0.45 * I;
    }

    // ---- 中心亮点 ----
    float core = exp(-pow(dist * 30.0, 2.0));
    color.rgb += float3(0.8, 0.9, 1.0) * core * 0.6 * I;

    return color;
}

// MARK: - 简单纹理拷贝（用于将离屏渲染结果绘制到 drawable）

fragment float4 blit_fragment(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}

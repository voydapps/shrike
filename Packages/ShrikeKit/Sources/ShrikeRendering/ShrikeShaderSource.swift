//
//  ShrikeShaderSource.swift
//  ShrikeRendering
//
//  Minimal textured-quad vertex + fragment pair for the single-image viewer.
//  The quad is transformed by a 4x4 matrix. Keep this tiny; Lanczos
//  minification runs as a separate MPS pass before this shader.
//
//  The source is kept as a Swift string so SwiftPM needs no .metal resource
//  rule, and the same code builds with Xcode and with `swift build`.
//

import Foundation

enum ShrikeShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position [[attribute(0)]];
        float2 texCoord [[attribute(1)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    struct Uniforms {
        float4x4 transform;
    };

    vertex VertexOut shrike_vertex(
        VertexIn in [[stage_in]],
        constant Uniforms &u [[buffer(1)]]
    ) {
        VertexOut out;
        out.position = u.transform * float4(in.position, 0.0, 1.0);
        out.texCoord = in.texCoord;
        return out;
    }

    // Sampled values are LINEAR (8-bit textures are read through an
    // `rgba8Unorm_srgb` view; 16F textures are stored linear). `toP3`
    // moves them to linear Display P3: sRGB primaries -> P3 for sRGB
    // files, identity otherwise. The drawable (rgba16Float linear P3, or
    // bgra8Unorm_srgb tagged Display P3) encodes on write.
    // `alpha` multiplies the photo's alpha: 1 normally, less during the
    // Reduce Motion swipe cross-fade (the pipeline blends source-over).
    struct FragUniforms {
        float3x3 toP3;
        float alpha;
    };

    fragment float4 shrike_fragment(
        VertexOut in [[stage_in]],
        texture2d<float, access::sample> tex [[texture(0)]],
        sampler s [[sampler(0)]],
        constant FragUniforms &f [[buffer(0)]]
    ) {
        float4 c = tex.sample(s, in.texCoord);
        return float4(f.toP3 * c.rgb, c.a * f.alpha);
    }
    """
}

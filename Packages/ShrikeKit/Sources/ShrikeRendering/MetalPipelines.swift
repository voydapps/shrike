//
//  MetalPipelines.swift
//  ShrikeRendering
//
//  The viewer's shader library, render pipelines and sampler — built ONCE
//  per process, off the main thread.
//
//  Every `MetalImageView` used to compile the shader
//  source and two pipeline states in its initializer, on the main thread.
//  Measured in a test harness: the first view took 250 ms, inside
//  `applicationDidFinishLaunching` on a cold launch with a file (which
//  went from 141 ms to 404 ms). Now `warmUp()` starts
//  the build on a background queue at the top of `main`, while AppKit
//  launches; a view only needs the pipelines for its first textured draw,
//  and waits for them there if the build has not finished yet.
//

import Foundation
import Metal
import ShrikeCore

/// `@unchecked Sendable`: immutable after `init`. Metal render pipeline
/// states and sampler states are thread-safe, immutable objects (Metal
/// Programming Guide: "can be used from any thread"); the SDK just does
/// not mark the protocols `Sendable`.
public final class MetalPipelines: @unchecked Sendable {

    /// Pipeline for `rgba16Float` drawables (HDR / 16-bit photos).
    public let pipelineHalf: any MTLRenderPipelineState
    /// Pipeline for `bgra8Unorm_srgb` drawables (SDR photos).
    public let pipeline8: any MTLRenderPipelineState
    public let sampler: any MTLSamplerState

    /// Built on first access. Swift runs a static initializer exactly
    /// once and makes other threads wait for it, so a draw that arrives
    /// while `warmUp()` is still compiling simply waits for that build.
    public static let shared: MetalPipelines? = {
        let state = ShrikeSignposts.launch.begin("metalPipelines")
        defer { ShrikeSignposts.launch.end("metalPipelines", state) }
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return MetalPipelines(device: device)
    }()

    /// Starts the build on a background queue. Idempotent and cheap.
    public static func warmUp() {
        DispatchQueue.global(qos: .userInteractive).async {
            _ = MetalPipelines.shared
        }
    }

    private init?(device: any MTLDevice) {
        guard let library = try? device.makeLibrary(source: ShrikeShaderSource.metal, options: nil),
              let vfn = library.makeFunction(name: "shrike_vertex"),
              let ffn = library.makeFunction(name: "shrike_fragment")
        else { return nil }

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2
        vd.attributes[1].offset = MemoryLayout<Float>.stride * 2
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<Float>.stride * 4

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = .rgba16Float
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].rgbBlendOperation = .add
        pd.colorAttachments[0].alphaBlendOperation = .add
        pd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let half = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        guard let eight = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .notMipmapped
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }

        self.pipelineHalf = half
        self.pipeline8 = eight
        self.sampler = sampler
    }
}

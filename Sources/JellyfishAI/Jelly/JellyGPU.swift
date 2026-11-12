import Foundation
import Metal
import CoreGraphics

/// 全クラゲで共有する GPU リソース（デバイス・キュー・パイプライン）。
/// クラゲが何体いてもシェーダのコンパイルは起動時の 1 回だけ。
final class JellyGPU {
    static let shared = JellyGPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError(L("Metal が利用できません"))
        }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: JellyShader.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "jelly_vertex")
            d.fragmentFunction = lib.makeFunction(name: "jelly_fragment")
            d.colorAttachments[0].pixelFormat = pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            FileHandle.standardError.write("Shader compile failed:\n\(error)\n".data(using: .utf8)!)
            exit(2)
        }
    }

    func encode(_ cb: MTLCommandBuffer, pass rpd: MTLRenderPassDescriptor, uniforms: [SIMD4<Float>]) {
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { buf in
            enc.setFragmentBytes(buf.baseAddress!, length: buf.count, index: 0)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// オフスクリーン描画して CGImage を返す（スナップショット・アイコン生成・目視確認用）
    func renderImage(width: Int, height: Int, uniforms: [SIMD4<Float>]) -> CGImage? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        encode(cb, pass: rpd, uniforms: uniforms)
        cb.commit()
        cb.waitUntilCompleted()

        let bpr = width * 4
        var bytes = [UInt8](repeating: 0, count: bpr * height)
        tex.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

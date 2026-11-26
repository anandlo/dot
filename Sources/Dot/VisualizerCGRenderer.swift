import Accelerate
import CoreGraphics
import DotCore
import Foundation
import os

/// Immutable frame payload handed from the main-thread render loop to a live
/// CoreGraphics visualizer layer without passing through SwiftUI view diffs.
struct VisualizerFrame: Sendable {
    var visualizer: HUDVisualizer = .stretch
    var material: HUDMaterial = .black
    var history: [Double] = []
    var spectrumHistory: [AudioSpectrumFrame] = []
    var time: Double = 0
    var level: Double = 0
    var phase: Double = 0
    var pulse: Double = 0
    var ceiling: Double = 1
    var reveal: Double = 1
    var reduceMotion: Bool = false
    var highlight: Bool = true
    var glassRingLift: Double = HUDWaveform.Halo.glassRingLift
    var glassRingInkGain: Double = HUDWaveform.Halo.glassRingInkGain

    var shownReveal: Double { min(max(reveal, 0), 1) }
    var effectiveTime: Double { time > 0 ? time : pulse * 4.4 }
    var ringLift: Double { material == .glass ? min(max(glassRingLift, 0), 1) : 0 }
    var ringInkGain: Double { material == .glass ? max(glassRingInkGain, 0) : 1 }
}

/// Reusable per-layer scratch buffers avoiding heap, CGContext, and vImage allocations on live frames.
final class VisualizerRenderScratch {
    var primaryCtx: CGContext?
    var primaryWidth = 0
    var primaryHeight = 0

    var haloCtx: CGContext?
    var haloWidth = 0
    var haloHeight = 0
    var haloDstCtx: CGContext?
    var haloDstWidth = 0
    var haloDstHeight = 0

    var glowCtx: CGContext?
    var glowWidth = 0
    var glowHeight = 0
    var glowDstCtx: CGContext?
    var glowDstWidth = 0
    var glowDstHeight = 0

    var wireCtx: CGContext?
    var wireWidth = 0
    var wireHeight = 0

    var vImageTemp: [UInt8] = []
    var strandPoints: [[CGPoint]] = []
    var strandHeats: [[Double]] = []

    var silkEnergies: [Double] = []
    var silkTop: [CGPoint] = []
    var silkBottom: [CGPoint] = []
    var silkHalfThickness: [CGFloat] = []

    func ensureContext(
        _ slot: inout CGContext?,
        width: inout Int,
        height: inout Int,
        targetWidth: Int,
        targetHeight: Int,
        colorSpace: CGColorSpace,
        clear: Bool
    ) -> CGContext? {
        if let existing = slot, width == targetWidth, height == targetHeight {
            if clear, let data = existing.data {
                memset(data, 0, existing.bytesPerRow * targetHeight)
            }
            return existing
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let created = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
        slot = created
        width = created != nil ? targetWidth : 0
        height = created != nil ? targetHeight : 0
        return created
    }
}

/// Pure CoreGraphics renderer shared by the live HUD Island waveform layer and
/// Settings -> Appearance animated visualizer swatches.
enum VisualizerCGRenderer {
    private static let colorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func draw(
        _ frame: VisualizerFrame,
        in ctx: CGContext,
        size: CGSize,
        scratch: VisualizerRenderScratch? = nil
    ) {
        guard size.width > 0, size.height > 0 else { return }
        switch frame.visualizer {
        case .stretch:
            drawStretch(frame, in: ctx, size: size, scratch: scratch)
        case .matrix:
            drawMatrix(frame, in: ctx, size: size, scratch: scratch)
        case .silk:
            drawSilk(frame, in: ctx, size: size, scratch: scratch)
        case .filament:
            drawFilament(frame, in: ctx, size: size, scratch: scratch)
        case .haloEdge:
            drawHalo(frame, in: ctx, size: size)
        }
    }

    // MARK: - Color Helpers

    private static func cgColor(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double
    ) -> CGColor {
        CGColor(
            colorSpace: colorSpace,
            components: [
                CGFloat(red),
                CGFloat(green),
                CGFloat(blue),
                CGFloat(min(1, max(0, alpha))),
            ]
        )!
    }

    private static func rampColor(
        _ tint: MeterTint,
        opacity: Double,
        lift: Double = 0
    ) -> CGColor {
        VisualizerMath.cgColor(tint, opacity: opacity, lift: lift, colorSpace: colorSpace)
    }

    private static func gradient(colors: [CGColor], locations: [CGFloat]) -> CGGradient? {
        CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)
    }

    private static func allocateContext(width: Int, height: Int) -> CGContext? {
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
    }

    // MARK: - 01 Stretch

    @inline(__always)
    private static func plotCapsuleAdditive(
        ptr: UnsafeMutablePointer<UInt8>,
        stride: Int,
        width: Int,
        height: Int,
        cx: Double,
        cy: Double,
        wPx: Double,
        hPx: Double,
        rPx: Double,
        r: Double,
        g: Double,
        b: Double,
        alpha: Double
    ) {
        guard alpha > 0.002, wPx > 0.05, hPx > 0.05 else { return }
        let hsx = max(0.0, wPx * 0.5 - rPx)
        let hsy = max(0.0, hPx * 0.5 - rPx)
        let outerR = rPx + 0.5
        let outerRSq = outerR * outerR
        let fullR = outerR - 1.0
        let minX = max(0, Int(floor(cx - hsx - outerR)))
        let maxX = min(width - 1, Int(ceil(cx + hsx + outerR)))
        let minY = max(0, Int(floor(cy - hsy - outerR)))
        let maxY = min(height - 1, Int(ceil(cy + hsy + outerR)))
        guard minX <= maxX, minY <= maxY else { return }

        let aClamped = min(1.0, max(0.0, alpha))
        let baseR = r * aClamped * 255.0
        let baseG = g * aClamped * 255.0
        let baseB = b * aClamped * 255.0
        let baseA = aClamped * 255.0

        var py = minY - 1
        while py < maxY {
            py += 1
            let dy = max(0.0, abs(Double(py) + 0.5 - cy) - hsy)
            let dyZero = dy == 0
            let dySq = dy * dy
            let rowOffset = py * stride
            var xDiff = Double(minX) + 0.5 - cx
            var px = minX - 1
            while px < maxX {
                px += 1
                let dxAbs = xDiff >= 0 ? xDiff : -xDiff
                xDiff += 1.0
                let dx = dxAbs > hsx ? dxAbs - hsx : 0.0
                let cov: Double
                if dyZero {
                    guard dx < outerR else { continue }
                    cov = dx <= fullR ? 1.0 : outerR - dx
                } else if dx == 0 {
                    guard dy < outerR else { continue }
                    cov = dy <= fullR ? 1.0 : outerR - dy
                } else {
                    let dSq = dx * dx + dySq
                    guard dSq < outerRSq else { continue }
                    let dist = dSq.squareRoot()
                    cov = dist <= fullR ? 1.0 : outerR - dist
                }
                let o = rowOffset + px * 4
                let nb = Int(ptr[o]) + Int(baseB * cov + 0.5)
                let ng = Int(ptr[o + 1]) + Int(baseG * cov + 0.5)
                let nr = Int(ptr[o + 2]) + Int(baseR * cov + 0.5)
                let na = Int(ptr[o + 3]) + Int(baseA * cov + 0.5)
                ptr[o] = nb >= 255 ? 255 : UInt8(nb)
                ptr[o + 1] = ng >= 255 ? 255 : UInt8(ng)
                ptr[o + 2] = nr >= 255 ? 255 : UInt8(nr)
                ptr[o + 3] = na >= 255 ? 255 : UInt8(na)
            }
        }
    }

    @inline(__always)
    private static func plotCapsuleSourceOverGradient(
        ptr: UnsafeMutablePointer<UInt8>,
        stride: Int,
        width: Int,
        height: Int,
        cx: Double,
        cy: Double,
        wPx: Double,
        hPx: Double,
        rPx: Double,
        r: Double,
        g: Double,
        b: Double,
        baseAlpha: Double,
        tipInk: Double
    ) {
        guard baseAlpha > 0.002, wPx > 0.05, hPx > 0.05 else { return }
        let hsx = max(0.0, wPx * 0.5 - rPx)
        let hsy = max(0.0, hPx * 0.5 - rPx)
        let outerR = rPx + 0.5
        let outerRSq = outerR * outerR
        let fullRad = outerR - 1.0
        let minX = max(0, Int(floor(cx - hsx - outerR)))
        let maxX = min(width - 1, Int(ceil(cx + hsx + outerR)))
        let minY = max(0, Int(floor(cy - hsy - outerR)))
        let maxY = min(height - 1, Int(ceil(cy + hsy + outerR)))
        guard minX <= maxX, minY <= maxY else { return }

        let rectMinY = cy - hPx * 0.5
        let invH = 1.0 / max(0.001, hPx)
        let tipDelta = 1.0 - tipInk
        let rawPtr = UnsafeMutableRawPointer(ptr)
        let canUse32 = (stride & 3) == 0 && (Int(bitPattern: ptr) & 3) == 0
        let stemMinY = max(minY, Int(ceil(cy - hsy - 0.5)))
        let stemMaxY = min(maxY, Int(floor(cy + hsy - 0.5)))
        let innerMinX = (canUse32 && fullRad >= 0) ? max(minX, Int(ceil(cx - hsx - fullRad - 0.5))) : (maxX + 1)
        let innerMaxX = (canUse32 && fullRad >= 0) ? min(maxX, Int(floor(cx + hsx + fullRad - 0.5))) : (minX - 1)

        @inline(__always)
        func writeStemEdgePixel(px: Int, rowOffset: Int, rowAlpha: Double, rowScale: Double, rowB: Double, rowG: Double, rowR: Double, fullB: UInt8, fullG: UInt8, fullR: UInt8, fullA: UInt8) {
            let dxAbs = abs(Double(px) + 0.5 - cx)
            let dx = dxAbs > hsx ? dxAbs - hsx : 0.0
            guard dx < outerR else { return }
            let cov = dx <= fullRad ? 1.0 : outerR - dx
            let o = rowOffset + px * 4
            if ptr[o + 3] == 0 {
                if cov == 1.0 {
                    ptr[o] = fullB
                    ptr[o + 1] = fullG
                    ptr[o + 2] = fullR
                    ptr[o + 3] = fullA
                } else {
                    let ob = Int(rowB * cov + 0.5)
                    let og = Int(rowG * cov + 0.5)
                    let or = Int(rowR * cov + 0.5)
                    let oa = Int(rowScale * cov + 0.5)
                    ptr[o] = ob >= 255 ? 255 : UInt8(ob)
                    ptr[o + 1] = og >= 255 ? 255 : UInt8(og)
                    ptr[o + 2] = or >= 255 ? 255 : UInt8(or)
                    ptr[o + 3] = oa >= 255 ? 255 : UInt8(oa)
                }
            } else {
                let oneMinusA = 1.0 - rowAlpha * cov
                let ob = Int(rowB * cov + Double(ptr[o]) * oneMinusA + 0.5)
                let og = Int(rowG * cov + Double(ptr[o + 1]) * oneMinusA + 0.5)
                let or = Int(rowR * cov + Double(ptr[o + 2]) * oneMinusA + 0.5)
                let oa = Int(rowScale * cov + Double(ptr[o + 3]) * oneMinusA + 0.5)
                ptr[o] = ob >= 255 ? 255 : UInt8(ob)
                ptr[o + 1] = og >= 255 ? 255 : UInt8(og)
                ptr[o + 2] = or >= 255 ? 255 : UInt8(or)
                ptr[o + 3] = oa >= 255 ? 255 : UInt8(oa)
            }
        }

        var py = minY - 1
        while py < maxY {
            py += 1
            let pyCenter = Double(py) + 0.5
            let t = min(1.0, max(0.0, (pyCenter - rectMinY) * invH))
            let gradFactor = t <= 0.5
                ? (tipInk + tipDelta * (t * 2.0))
                : (1.0 - tipDelta * ((t - 0.5) * 2.0))
            let rowAlpha = min(1.0, max(0.0, baseAlpha * gradFactor))
            guard rowAlpha > 0.002 else { continue }
            let rowScale = rowAlpha * 255.0
            let rowB = b * rowScale
            let rowG = g * rowScale
            let rowR = r * rowScale
            let fullB = UInt8(min(255, Int(rowB + 0.5)))
            let fullG = UInt8(min(255, Int(rowG + 0.5)))
            let fullR = UInt8(min(255, Int(rowR + 0.5)))
            let fullA = UInt8(min(255, Int(rowScale + 0.5)))
            let rowOffset = py * stride

            if py >= stemMinY && py <= stemMaxY {
                if innerMinX <= innerMaxX {
                    if minX < innerMinX {
                        var px = minX - 1
                        while px < innerMinX - 1 {
                            px += 1
                            writeStemEdgePixel(px: px, rowOffset: rowOffset, rowAlpha: rowAlpha, rowScale: rowScale, rowB: rowB, rowG: rowG, rowR: rowR, fullB: fullB, fullG: fullG, fullR: fullR, fullA: fullA)
                        }
                    }
                    let fullPixel32 = UInt32(fullB)
                        | (UInt32(fullG) << 8)
                        | (UInt32(fullR) << 16)
                        | (UInt32(fullA) << 24)
                    let oneMinusA = 1.0 - rowAlpha
                    var px = innerMinX - 1
                    while px < innerMaxX {
                        px += 1
                        let o = rowOffset + px * 4
                        if rawPtr.load(fromByteOffset: o, as: UInt32.self) == 0 {
                            rawPtr.storeBytes(of: fullPixel32, toByteOffset: o, as: UInt32.self)
                        } else {
                            let ob = Int(rowB + Double(ptr[o]) * oneMinusA + 0.5)
                            let og = Int(rowG + Double(ptr[o + 1]) * oneMinusA + 0.5)
                            let or = Int(rowR + Double(ptr[o + 2]) * oneMinusA + 0.5)
                            let oa = Int(rowScale + Double(ptr[o + 3]) * oneMinusA + 0.5)
                            ptr[o] = ob >= 255 ? 255 : UInt8(ob)
                            ptr[o + 1] = og >= 255 ? 255 : UInt8(og)
                            ptr[o + 2] = or >= 255 ? 255 : UInt8(or)
                            ptr[o + 3] = oa >= 255 ? 255 : UInt8(oa)
                        }
                    }
                    if innerMaxX < maxX {
                        var px = innerMaxX + 1 - 1
                        while px < maxX {
                            px += 1
                            writeStemEdgePixel(px: px, rowOffset: rowOffset, rowAlpha: rowAlpha, rowScale: rowScale, rowB: rowB, rowG: rowG, rowR: rowR, fullB: fullB, fullG: fullG, fullR: fullR, fullA: fullA)
                        }
                    }
                } else {
                    var px = minX - 1
                    while px < maxX {
                        px += 1
                        writeStemEdgePixel(px: px, rowOffset: rowOffset, rowAlpha: rowAlpha, rowScale: rowScale, rowB: rowB, rowG: rowG, rowR: rowR, fullB: fullB, fullG: fullG, fullR: fullR, fullA: fullA)
                    }
                }
                continue
            }

            let dy = max(0.0, abs(pyCenter - cy) - hsy)
            let dyZero = dy == 0
            let dySq = dy * dy
            var xDiff = Double(minX) + 0.5 - cx
            var px = minX - 1
            while px < maxX {
                px += 1
                let dxAbs = xDiff >= 0 ? xDiff : -xDiff
                xDiff += 1.0
                let dx = dxAbs > hsx ? dxAbs - hsx : 0.0
                let cov: Double
                if dyZero {
                    guard dx < outerR else { continue }
                    cov = dx <= fullRad ? 1.0 : outerR - dx
                } else if dx == 0 {
                    guard dy < outerR else { continue }
                    cov = dy <= fullRad ? 1.0 : outerR - dy
                } else {
                    let dSq = dx * dx + dySq
                    guard dSq < outerRSq else { continue }
                    let dist = dSq.squareRoot()
                    cov = dist <= fullRad ? 1.0 : outerR - dist
                }
                let o = rowOffset + px * 4
                if ptr[o + 3] == 0 {
                    if cov == 1.0 {
                        ptr[o] = fullB
                        ptr[o + 1] = fullG
                        ptr[o + 2] = fullR
                        ptr[o + 3] = fullA
                    } else {
                        let ob = Int(rowB * cov + 0.5)
                        let og = Int(rowG * cov + 0.5)
                        let or = Int(rowR * cov + 0.5)
                        let oa = Int(rowScale * cov + 0.5)
                        ptr[o] = ob >= 255 ? 255 : UInt8(ob)
                        ptr[o + 1] = og >= 255 ? 255 : UInt8(og)
                        ptr[o + 2] = or >= 255 ? 255 : UInt8(or)
                        ptr[o + 3] = oa >= 255 ? 255 : UInt8(oa)
                    }
                } else {
                    let oneMinusA = 1.0 - rowAlpha * cov
                    let ob = Int(rowB * cov + Double(ptr[o]) * oneMinusA + 0.5)
                    let og = Int(rowG * cov + Double(ptr[o + 1]) * oneMinusA + 0.5)
                    let or = Int(rowR * cov + Double(ptr[o + 2]) * oneMinusA + 0.5)
                    let oa = Int(rowScale * cov + Double(ptr[o + 3]) * oneMinusA + 0.5)
                    ptr[o] = ob >= 255 ? 255 : UInt8(ob)
                    ptr[o + 1] = og >= 255 ? 255 : UInt8(og)
                    ptr[o + 2] = or >= 255 ? 255 : UInt8(or)
                    ptr[o + 3] = oa >= 255 ? 255 : UInt8(oa)
                }
            }
        }
    }

    @inline(__always)
    private static func plotCapsuleSourceOver(
        ptr: UnsafeMutablePointer<UInt8>,
        stride: Int,
        width: Int,
        height: Int,
        cx: Double,
        cy: Double,
        wPx: Double,
        hPx: Double,
        rPx: Double,
        r: Double,
        g: Double,
        b: Double,
        alpha: Double
    ) {
        guard alpha > 0.002, wPx > 0.05, hPx > 0.05 else { return }
        let hsx = max(0.0, wPx * 0.5 - rPx)
        let hsy = max(0.0, hPx * 0.5 - rPx)
        let outerR = rPx + 0.5
        let outerRSq = outerR * outerR
        let fullRad = outerR - 1.0
        let minX = max(0, Int(floor(cx - hsx - outerR)))
        let maxX = min(width - 1, Int(ceil(cx + hsx + outerR)))
        let minY = max(0, Int(floor(cy - hsy - outerR)))
        let maxY = min(height - 1, Int(ceil(cy + hsy + outerR)))
        guard minX <= maxX, minY <= maxY else { return }

        let aClamped = min(1.0, max(0.0, alpha))
        let alpha255 = aClamped * 255.0
        let baseB = b * alpha255
        let baseG = g * alpha255
        let baseR = r * alpha255
        let fullB = UInt8(min(255, Int(baseB + 0.5)))
        let fullG = UInt8(min(255, Int(baseG + 0.5)))
        let fullR = UInt8(min(255, Int(baseR + 0.5)))
        let fullA = UInt8(min(255, Int(alpha255 + 0.5)))

        var py = minY - 1
        while py < maxY {
            py += 1
            let dy = max(0.0, abs(Double(py) + 0.5 - cy) - hsy)
            let dyZero = dy == 0
            let dySq = dy * dy
            let rowOffset = py * stride
            var xDiff = Double(minX) + 0.5 - cx
            var px = minX - 1
            while px < maxX {
                px += 1
                let dxAbs = xDiff >= 0 ? xDiff : -xDiff
                xDiff += 1.0
                let dx = dxAbs > hsx ? dxAbs - hsx : 0.0
                let cov: Double
                if dyZero {
                    guard dx < outerR else { continue }
                    cov = dx <= fullRad ? 1.0 : outerR - dx
                } else if dx == 0 {
                    guard dy < outerR else { continue }
                    cov = dy <= fullRad ? 1.0 : outerR - dy
                } else {
                    let dSq = dx * dx + dySq
                    guard dSq < outerRSq else { continue }
                    let dist = dSq.squareRoot()
                    cov = dist <= fullRad ? 1.0 : outerR - dist
                }
                let o = rowOffset + px * 4
                if ptr[o + 3] == 0 {
                    if cov == 1.0 {
                        ptr[o] = fullB
                        ptr[o + 1] = fullG
                        ptr[o + 2] = fullR
                        ptr[o + 3] = fullA
                    } else {
                        let ob = Int(baseB * cov + 0.5)
                        let og = Int(baseG * cov + 0.5)
                        let or = Int(baseR * cov + 0.5)
                        let oa = Int(alpha255 * cov + 0.5)
                        ptr[o] = ob >= 255 ? 255 : UInt8(ob)
                        ptr[o + 1] = og >= 255 ? 255 : UInt8(og)
                        ptr[o + 2] = or >= 255 ? 255 : UInt8(or)
                        ptr[o + 3] = oa >= 255 ? 255 : UInt8(oa)
                    }
                } else {
                    let oneMinusA = 1.0 - aClamped * cov
                    let ob = Int(baseB * cov + Double(ptr[o]) * oneMinusA + 0.5)
                    let og = Int(baseG * cov + Double(ptr[o + 1]) * oneMinusA + 0.5)
                    let or = Int(baseR * cov + Double(ptr[o + 2]) * oneMinusA + 0.5)
                    let oa = Int(alpha255 * cov + Double(ptr[o + 3]) * oneMinusA + 0.5)
                    ptr[o] = ob >= 255 ? 255 : UInt8(ob)
                    ptr[o + 1] = og >= 255 ? 255 : UInt8(og)
                    ptr[o + 2] = or >= 255 ? 255 : UInt8(or)
                    ptr[o + 3] = oa >= 255 ? 255 : UInt8(oa)
                }
            }
        }
    }

    private static func drawStretch(
        _ frame: VisualizerFrame,
        in ctx: CGContext,
        size: CGSize,
        scratch: VisualizerRenderScratch?
    ) {
        let Stretch = HUDWaveform.Stretch.self
        let row = Stretch.bars(
            history: frame.history,
            phase: frame.phase,
            time: frame.effectiveTime,
            reveal: frame.shownReveal,
            canvas: size.width,
            reduceMotion: frame.reduceMotion,
            sampleTick: frame.spectrumHistory.last?.sample
        )
        guard !row.isEmpty else { return }
        let mid = size.height / 2
        let verticalScale: CGFloat = size.height < 26
            ? max(0.5, (size.height - 2) / Stretch.maxHeight)
            : 1

        let scale = max(1.0, min(2.0, hypot(ctx.ctm.a, ctx.ctm.b)))
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        guard let bufCtx = scratch?.ensureContext(
            &scratch!.primaryCtx,
            width: &scratch!.primaryWidth,
            height: &scratch!.primaryHeight,
            targetWidth: width,
            targetHeight: height,
            colorSpace: colorSpace,
            clear: true
        ) ?? allocateContext(width: width, height: height),
        let rawData = bufCtx.data else {
            return
        }

        let ptr = rawData.assumingMemoryBound(to: UInt8.self)
        let stride = bufCtx.bytesPerRow
        let scaleD = Double(scale)
        let cyPx = Double(mid) * scaleD

        for bar in row.reversed() {
            let tint = WaveInk.tint(level: bar.value, material: frame.material)
            let baseOpacity = tint.opacity
            let barHeight = bar.height * verticalScale
            let cxPx = Double(bar.centre) * scaleD

            if bar.isLive {
                let glowW = Double(bar.width * Stretch.glowWidthShare) * scaleD
                let glowH = Double(Stretch.glowHeight(bar.height) * verticalScale) * scaleD
                let glowR = min(glowW, glowH) * 0.5
                plotCapsuleAdditive(
                    ptr: ptr,
                    stride: stride,
                    width: width,
                    height: height,
                    cx: cxPx,
                    cy: cyPx,
                    wPx: glowW,
                    hPx: glowH,
                    rPx: glowR,
                    r: tint.red,
                    g: tint.green,
                    b: tint.blue,
                    alpha: baseOpacity * Stretch.glowInk * bar.value
                )
            }

            let wPx = Double(bar.width) * scaleD
            let hPx = Double(barHeight) * scaleD
            let rPx = min(wPx, hPx) * 0.5
            plotCapsuleSourceOverGradient(
                ptr: ptr,
                stride: stride,
                width: width,
                height: height,
                cx: cxPx,
                cy: cyPx,
                wPx: wPx,
                hPx: hPx,
                rPx: rPx,
                r: tint.red,
                g: tint.green,
                b: tint.blue,
                baseAlpha: baseOpacity * bar.ink,
                tipInk: Stretch.tipInk
            )

            let shine = MeterRamp.smoothstep(0.55, 0.90, bar.value)
            if shine > 0 {
                let straight = barHeight - min(bar.width, barHeight)
                if straight > 0 {
                    let specular = MeterRamp.specularBand(level: bar.value, material: frame.material)
                    let bandW = Double(bar.width * 0.5) * scaleD
                    let bandH = Double(straight) * scaleD
                    let bandR = min(bandW, bandH) * 0.5
                    plotCapsuleSourceOver(
                        ptr: ptr,
                        stride: stride,
                        width: width,
                        height: height,
                        cx: cxPx,
                        cy: cyPx,
                        wPx: bandW,
                        hPx: bandH,
                        rPx: bandR,
                        r: specular.red,
                        g: specular.green,
                        b: specular.blue,
                        alpha: bar.ink * shine
                    )
                }
            }
        }

        if let img = bufCtx.makeImage() {
            ctx.saveGState()
            ctx.interpolationQuality = .low
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
    }

    // MARK: - 02 Filament

    private struct FilamentRGB: Sendable {
        let r: Double
        let g: Double
        let b: Double
        let haloPow: Double
        let glowPow: Double
    }

    private enum FilamentColorLUT {
        static let steps = 64
        static let black: [FilamentRGB] = build(material: .black)
        static let glass: [FilamentRGB] = build(material: .glass)

        private static func build(material: HUDMaterial) -> [FilamentRGB] {
            (0...steps).map { idx in
                let heat = Double(idx) / Double(steps)
                let c = HUDWaveform.Filament.components(
                    heat: heat,
                    material: material
                )
                return FilamentRGB(
                    r: c.red,
                    g: c.green,
                    b: c.blue,
                    haloPow: pow(heat, HUDWaveform.Filament.haloExponent),
                    glowPow: pow(heat, HUDWaveform.Filament.glowExponent)
                )
            }
        }

        @inline(__always)
        static func rgb(heat: Double, material: HUDMaterial) -> FilamentRGB {
            let table = material == .black ? black : glass
            let clamped = min(1, max(0, heat))
            let idx = min(steps, max(0, Int((clamped * Double(steps)).rounded())))
            return table[idx]
        }
    }

    @inline(__always)
    private static func plotAdditivePixel(
        ptr: UnsafeMutablePointer<UInt8>,
        offset: Int,
        addB: Int,
        addG: Int,
        addR: Int,
        addA: Int
    ) {
        let nb = Int(ptr[offset]) + addB
        let ng = Int(ptr[offset + 1]) + addG
        let nr = Int(ptr[offset + 2]) + addR
        let na = Int(ptr[offset + 3]) + addA
        ptr[offset] = nb >= 255 ? 255 : UInt8(nb)
        ptr[offset + 1] = ng >= 255 ? 255 : UInt8(ng)
        ptr[offset + 2] = nr >= 255 ? 255 : UInt8(nr)
        ptr[offset + 3] = na >= 255 ? 255 : UInt8(na)
    }

    @inline(__always)
    private static func plotAdditiveSegmentFast(
        ptr: UnsafeMutablePointer<UInt8>,
        stride: Int,
        width: Int,
        height: Int,
        x0: Double,
        y0: Double,
        x1: Double,
        y1: Double,
        r: Double,
        g: Double,
        b: Double,
        alpha: Double
    ) {
        guard alpha > 0.002 else { return }
        let dx = x1 - x0
        let dy = y1 - y0
        let dist = hypot(dx, dy)
        let steps = max(1, Int(ceil(dist)))
        let stepSpacing = dist / Double(steps)
        let scale = alpha * min(1.0, max(0.55, stepSpacing)) * 255.0
        let addR = Int(r * scale)
        let addG = Int(g * scale)
        let addB = Int(b * scale)
        let addA = Int(scale)
        let invSteps = 1.0 / Double(steps)
        let stepX = dx * invSteps
        let stepY = dy * invSteps
        let startStep = dist > 0.1 ? 1 : 0
        var fx = x0
        var fy = y0
        if startStep == 1 {
            fx += stepX
            fy += stepY
        }

        var step = startStep - 1
        while step < steps {
            step += 1
            if fx >= 0, fy >= 0 {
                let ix = Int(fx)
                let iy = Int(fy)
                if ix < width, iy < height {
                    plotAdditivePixel(
                        ptr: ptr,
                        offset: iy * stride + ix * 4,
                        addB: addB,
                        addG: addG,
                        addR: addR,
                        addA: addA
                    )
                }
            }
            fx += stepX
            fy += stepY
        }
    }

    @inline(__always)
    private static func plotAdditiveSegmentPremul(
        ptr: UnsafeMutablePointer<UInt8>,
        stride: Int,
        width: Int,
        height: Int,
        x0: Double,
        y0: Double,
        x1: Double,
        y1: Double,
        premulR: Double,
        premulG: Double,
        premulB: Double,
        alpha: Double
    ) {
        guard alpha > 0.002 else { return }
        let dx = x1 - x0
        let dy = y1 - y0
        let dist = hypot(dx, dy)
        let steps = max(1, Int(ceil(dist / 0.75)))
        let stepSpacing = dist / Double(steps)
        let scale = min(1.0, max(0.55, stepSpacing)) * 255.0
        let scaledR = premulR * scale
        let scaledG = premulG * scale
        let scaledB = premulB * scale
        let scaledA = alpha * scale
        let invSteps = 1.0 / Double(steps)
        let stepX = dx * invSteps
        let stepY = dy * invSteps
        let startStep = dist > 0.1 ? 1 : 0
        var fx = x0 - 0.5
        var fy = y0 - 0.5
        if startStep == 1 {
            fx += stepX
            fy += stepY
        }

        var step = startStep - 1
        while step < steps {
            step += 1
            if fx >= 0, fy >= 0 {
                let ix = Int(fx)
                let iy = Int(fy)
                if ix + 1 < width, iy + 1 < height {
                    let fracX = fx - Double(ix)
                    let fracY = fy - Double(iy)
                    let w00 = (1.0 - fracX) * (1.0 - fracY)
                    let w10 = fracX * (1.0 - fracY)
                    let w01 = (1.0 - fracX) * fracY
                    let w11 = fracX * fracY
                    let row0 = iy * stride + ix * 4
                    let row1 = row0 + stride
                    plotAdditivePixel(
                        ptr: ptr,
                        offset: row0,
                        addB: Int(scaledB * w00),
                        addG: Int(scaledG * w00),
                        addR: Int(scaledR * w00),
                        addA: Int(scaledA * w00)
                    )
                    plotAdditivePixel(
                        ptr: ptr,
                        offset: row0 + 4,
                        addB: Int(scaledB * w10),
                        addG: Int(scaledG * w10),
                        addR: Int(scaledR * w10),
                        addA: Int(scaledA * w10)
                    )
                    plotAdditivePixel(
                        ptr: ptr,
                        offset: row1,
                        addB: Int(scaledB * w01),
                        addG: Int(scaledG * w01),
                        addR: Int(scaledR * w01),
                        addA: Int(scaledA * w01)
                    )
                    plotAdditivePixel(
                        ptr: ptr,
                        offset: row1 + 4,
                        addB: Int(scaledB * w11),
                        addG: Int(scaledG * w11),
                        addR: Int(scaledR * w11),
                        addA: Int(scaledA * w11)
                    )
                    fx += stepX
                    fy += stepY
                    continue
                }
            }

            let ix = Int(floor(fx))
            let iy = Int(floor(fy))
            let fracX = fx - Double(ix)
            let fracY = fy - Double(iy)
            let w00 = (1.0 - fracX) * (1.0 - fracY)
            let w10 = fracX * (1.0 - fracY)
            let w01 = (1.0 - fracX) * fracY
            let w11 = fracX * fracY

            if iy >= 0, iy < height {
                let row0 = iy * stride
                if ix >= 0, ix < width {
                    plotAdditivePixel(
                        ptr: ptr,
                        offset: row0 + ix * 4,
                        addB: Int(scaledB * w00),
                        addG: Int(scaledG * w00),
                        addR: Int(scaledR * w00),
                        addA: Int(scaledA * w00)
                    )
                }
                if ix + 1 >= 0, ix + 1 < width {
                    plotAdditivePixel(
                        ptr: ptr,
                        offset: row0 + (ix + 1) * 4,
                        addB: Int(scaledB * w10),
                        addG: Int(scaledG * w10),
                        addR: Int(scaledR * w10),
                        addA: Int(scaledA * w10)
                    )
                }
            }
            if iy + 1 >= 0, iy + 1 < height {
                let row1 = (iy + 1) * stride
                if ix >= 0, ix < width {
                    plotAdditivePixel(
                        ptr: ptr,
                        offset: row1 + ix * 4,
                        addB: Int(scaledB * w01),
                        addG: Int(scaledG * w01),
                        addR: Int(scaledR * w01),
                        addA: Int(scaledA * w01)
                    )
                }
                if ix + 1 >= 0, ix + 1 < width {
                    plotAdditivePixel(
                        ptr: ptr,
                        offset: row1 + (ix + 1) * 4,
                        addB: Int(scaledB * w11),
                        addG: Int(scaledG * w11),
                        addR: Int(scaledR * w11),
                        addA: Int(scaledA * w11)
                    )
                }
            }
            fx += stepX
            fy += stepY
        }
    }

    private static func convolveAndComposite(
        srcCtx: CGContext,
        dstSlot: inout CGContext?,
        dstWidth: inout Int,
        dstHeight: inout Int,
        vImageTemp: inout [UInt8],
        width: Int,
        height: Int,
        kernel: UInt32,
        targetSize: CGSize,
        into mainContext: CGContext
    ) {
        guard let srcData = srcCtx.data else {
            return
        }
        if dstSlot == nil || dstWidth != width || dstHeight != height {
            guard let created = allocateContext(width: width, height: height) else { return }
            dstSlot = created
            dstWidth = width
            dstHeight = height
        }
        guard let activeDst = dstSlot, let dstData = activeDst.data else {
            return
        }

        var srcBuf = vImage_Buffer(
            data: srcData,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: srcCtx.bytesPerRow
        )
        var dstBuf = vImage_Buffer(
            data: dstData,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: activeDst.bytesPerRow
        )
        var background: [UInt8] = [0, 0, 0, 0]
        let flags = vImage_Flags(kvImageBackgroundColorFill)
        let tempBytes = vImageTentConvolve_ARGB8888(
            &srcBuf,
            &dstBuf,
            nil,
            0,
            0,
            kernel,
            kernel,
            &background,
            flags | vImage_Flags(kvImageGetTempBufferSize)
        )
        if tempBytes > 0 {
            if vImageTemp.count < tempBytes {
                vImageTemp = [UInt8](repeating: 0, count: tempBytes)
            }
            vImageTemp.withUnsafeMutableBytes { raw in
                _ = vImageTentConvolve_ARGB8888(
                    &srcBuf,
                    &dstBuf,
                    raw.baseAddress,
                    0,
                    0,
                    kernel,
                    kernel,
                    &background,
                    flags
                )
            }
        } else {
            _ = vImageTentConvolve_ARGB8888(
                &srcBuf,
                &dstBuf,
                nil,
                0,
                0,
                kernel,
                kernel,
                &background,
                flags
            )
        }

        guard let blurred = activeDst.makeImage() else { return }
        mainContext.saveGState()
        mainContext.setBlendMode(.plusLighter)
        mainContext.interpolationQuality = .low
        mainContext.translateBy(x: 0, y: targetSize.height)
        mainContext.scaleBy(x: 1, y: -1)
        mainContext.draw(blurred, in: CGRect(origin: .zero, size: targetSize))
        mainContext.restoreGState()
    }

    private static func drawFilament(
        _ frame: VisualizerFrame,
        in ctx: CGContext,
        size: CGSize,
        scratch: VisualizerRenderScratch?
    ) {
        let Filament = HUDWaveform.Filament.self
        let bulb = Filament.geometry(for: size)
        let shown = frame.shownReveal
        guard shown > 0, bulb.end - bulb.start > 12 else { return }

        let profile = Filament.heatProfile(
            history: frame.history,
            spectrum: frame.spectrumHistory,
            reveal: shown,
            reduceMotion: frame.reduceMotion
        )
        let meanHeat = Filament.mean(profile)
        let cached = Filament.template(for: bulb, stepsPerTurn: 10)
        let angular = 2 * Double.pi * Filament.shimmerRate * frame.effectiveTime

        var localStrandPoints: [[CGPoint]] = []
        var localStrandHeats: [[Double]] = []
        func populateStrands(
            into strandPoints: inout [[CGPoint]],
            heats strandHeats: inout [[Double]]
        ) {
            if strandPoints.count != cached.strands.count {
                strandPoints = Array(repeating: [], count: cached.strands.count)
                strandHeats = Array(repeating: [], count: cached.strands.count)
            }
            for strandIdx in cached.strands.indices {
                let strandNodes = cached.strands[strandIdx]
                strandPoints[strandIdx].removeAll(keepingCapacity: true)
                strandHeats[strandIdx].removeAll(keepingCapacity: true)
                if strandPoints[strandIdx].capacity < strandNodes.count {
                    strandPoints[strandIdx].reserveCapacity(strandNodes.count)
                    strandHeats[strandIdx].reserveCapacity(strandNodes.count)
                }
                if frame.reduceMotion {
                    for node in strandNodes {
                        strandPoints[strandIdx].append(node.point)
                        strandHeats[strandIdx].append(Filament.heat(at: node.u, in: profile))
                    }
                } else {
                    for node in strandNodes {
                        let nodeHeat = Filament.heat(at: node.u, in: profile)
                        let shiver = Filament.shimmerGain * nodeHeat * sin(angular + node.shimmerPhase)
                        strandPoints[strandIdx].append(CGPoint(x: node.point.x, y: node.point.y + CGFloat(shiver)))
                        strandHeats[strandIdx].append(nodeHeat)
                    }
                }
            }
        }
        if let scratch {
            populateStrands(into: &scratch.strandPoints, heats: &scratch.strandHeats)
        } else {
            populateStrands(into: &localStrandPoints, heats: &localStrandHeats)
        }
        let strandPoints = scratch?.strandPoints ?? localStrandPoints
        let strandHeats = scratch?.strandHeats ?? localStrandHeats

        let activeMaterial = frame.material
        let specular = MeterRamp.stops(for: activeMaterial).specular

        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: size))

        // 1. Ambient wash
        if meanHeat > 0.02 {
            let height = min(Filament.ambientHeight, size.height - 2)
            if height > 0 {
                let box = CGRect(
                    x: size.width / 2 - (bulb.end - bulb.start) * Filament.ambientWidthShare / 2,
                    y: bulb.centreY - height / 2,
                    width: (bulb.end - bulb.start) * Filament.ambientWidthShare,
                    height: height
                )
                let lum = FilamentColorLUT.rgb(heat: meanHeat, material: activeMaterial)
                let startColor = cgColor(
                    red: lum.r,
                    green: lum.g,
                    blue: lum.b,
                    alpha: shown * Filament.ambientInk * pow(meanHeat, Filament.ambientExponent)
                )
                let endColor = cgColor(red: lum.r, green: lum.g, blue: lum.b, alpha: 0)
                if let ambGrad = gradient(colors: [startColor, endColor], locations: [0, 1]) {
                    ctx.saveGState()
                    ctx.setBlendMode(.plusLighter)
                    ctx.concatenate(Filament.stretch(box))
                    let centre = CGPoint(x: box.midX, y: box.midY)
                    ctx.drawRadialGradient(
                        ambGrad,
                        startCenter: centre,
                        startRadius: 0,
                        endCenter: centre,
                        endRadius: box.width / 2,
                        options: []
                    )
                    ctx.restoreGState()
                }
            }
        }

        let halfScale: CGFloat = 0.5
        let wHalf = max(1, Int(ceil(size.width * halfScale)))
        let hHalf = max(1, Int(ceil(size.height * halfScale)))
        let w1 = max(1, Int(ceil(size.width)))
        let h1 = max(1, Int(ceil(size.height)))
        let backingScale = max(1.0, min(2.0, hypot(ctx.ctm.a, ctx.ctm.b)))
        let wHi = max(1, Int(ceil(size.width * backingScale)))
        let hHi = max(1, Int(ceil(size.height * backingScale)))

        guard let haloCtx = scratch?.ensureContext(
            &scratch!.haloCtx,
            width: &scratch!.haloWidth,
            height: &scratch!.haloHeight,
            targetWidth: wHalf,
            targetHeight: hHalf,
            colorSpace: colorSpace,
            clear: true
        ) ?? allocateContext(width: wHalf, height: hHalf),
        let glowCtx = scratch?.ensureContext(
            &scratch!.glowCtx,
            width: &scratch!.glowWidth,
            height: &scratch!.glowHeight,
            targetWidth: w1,
            targetHeight: h1,
            colorSpace: colorSpace,
            clear: true
        ) ?? allocateContext(width: w1, height: h1),
        let wireCtx = scratch?.ensureContext(
            &scratch!.wireCtx,
            width: &scratch!.wireWidth,
            height: &scratch!.wireHeight,
            targetWidth: wHi,
            targetHeight: hHi,
            colorSpace: colorSpace,
            clear: true
        ) ?? allocateContext(width: wHi, height: hHi),
        let haloRaw = haloCtx.data,
        let glowRaw = glowCtx.data,
        let wireRaw = wireCtx.data else {
            ctx.restoreGState()
            return
        }

        let haloPtr = haloRaw.assumingMemoryBound(to: UInt8.self)
        let glowPtr = glowRaw.assumingMemoryBound(to: UInt8.self)
        let wirePtr = wireRaw.assumingMemoryBound(to: UInt8.self)
        let haloStride = haloCtx.bytesPerRow
        let glowStride = glowCtx.bytesPerRow
        let wireStride = wireCtx.bytesPerRow
        let hiScale = Double(backingScale)
        let filamentTable = activeMaterial == .black ? FilamentColorLUT.black : FilamentColorLUT.glass

        filamentTable.withUnsafeBufferPointer { colorBuf in
            for strand in cached.strands.indices {
                let nodes = cached.strands[strand]
                let pts = strandPoints[strand]
                let heats = strandHeats[strand]
                guard nodes.count > 1 else { continue }

                var idx = -1
                while idx < nodes.count - 2 {
                    idx += 1
                    let n0 = nodes[idx]
                    let n1 = nodes[idx + 1]
                    let p0 = pts[idx]
                    let p1 = pts[idx + 1]
                    let segHeat = (heats[idx] + heats[idx + 1]) * 0.5
                    let segEdge = (n0.edge + n1.edge) * 0.5
                    let sideScale = (n0.isFront ? 1.0 : Filament.backInk) * shown
                    let widthScale = n0.isFront ? 1.0 : Double(Filament.backWidthShare)

                    let hIdx = min(FilamentColorLUT.steps, max(0, Int((min(1.0, max(0.0, segHeat)) * 64.0).rounded())))
                    let lum = colorBuf[hIdx]
                    let x0 = Double(p0.x)
                    let y0 = Double(p0.y)
                    let x1 = Double(p1.x)
                    let y1 = Double(p1.y)

                    let haloAlpha = min(
                        1.0,
                        Filament.haloInk * lum.haloPow * sideScale * widthScale * 2.2
                    )
                    if haloAlpha > 0.004 {
                        plotAdditiveSegmentFast(
                            ptr: haloPtr,
                            stride: haloStride,
                            width: wHalf,
                            height: hHalf,
                            x0: x0 * 0.5,
                            y0: y0 * 0.5,
                            x1: x1 * 0.5,
                            y1: y1 * 0.5,
                            r: lum.r,
                            g: lum.g,
                            b: lum.b,
                            alpha: haloAlpha
                        )
                    }

                    let glowAlpha = min(
                        1.0,
                        Filament.glowInk * lum.glowPow
                            * (Filament.glowEdgeFloor + Filament.glowEdgeGain * segEdge)
                            * sideScale * widthScale * 1.4
                    )
                    if glowAlpha > 0.004 {
                        plotAdditiveSegmentFast(
                            ptr: glowPtr,
                            stride: glowStride,
                            width: w1,
                            height: h1,
                            x0: x0,
                            y0: y0,
                            x1: x1,
                            y1: y1,
                            r: lum.r,
                            g: lum.g,
                            b: lum.b,
                            alpha: glowAlpha
                        )
                    }

                    let wHeat = min(1.0, segHeat + Filament.wireEdgeGain * segEdge)
                    let wIdx = min(FilamentColorLUT.steps, max(0, Int((wHeat * 64.0).rounded())))
                    let wireLum = colorBuf[wIdx]
                    let wireAlpha = sideScale * widthScale * 0.85
                    var premulR = wireLum.r * wireAlpha
                    var premulG = wireLum.g * wireAlpha
                    var premulB = wireLum.b * wireAlpha
                    var combinedAlpha = wireAlpha

                    if segHeat > Filament.coreOnset {
                        let coreAlpha = min(
                            1.0,
                            ((segHeat - Filament.coreOnset) / (1.0 - Filament.coreOnset))
                                * (Filament.coreEdgeFloor + Filament.coreEdgeGain * segEdge)
                                * sideScale * widthScale * 0.72
                        )
                        if coreAlpha > 0.004 {
                            premulR += specular.red * coreAlpha
                            premulG += specular.green * coreAlpha
                            premulB += specular.blue * coreAlpha
                            combinedAlpha += coreAlpha
                        }
                    }

                    plotAdditiveSegmentPremul(
                        ptr: wirePtr,
                        stride: wireStride,
                        width: wHi,
                        height: hHi,
                        x0: x0 * hiScale,
                        y0: y0 * hiScale,
                        x1: x1 * hiScale,
                        y1: y1 * hiScale,
                        premulR: premulR,
                        premulG: premulG,
                        premulB: premulB,
                        alpha: combinedAlpha
                    )
                }
            }
        }

        // Specular glints plotted directly into wire buffer
        if meanHeat > 0.02 {
            let glintSpan = max(1e-6, 1.0 - Filament.glintOnset)
            for strand in cached.glintIndices.indices {
                let indices = cached.glintIndices[strand]
                guard !indices.isEmpty else { continue }
                let pts = strandPoints[strand]
                let heats = strandHeats[strand]
                let nodes = cached.strands[strand]
                for index in indices {
                    let nodeHeat = heats[index]
                    guard nodeHeat > Filament.glintOnset else { continue }
                    let glintT = (nodeHeat - Filament.glintOnset) / glintSpan
                    let rPx = Double(Filament.glintRadius + Filament.glintGain * CGFloat(glintT)) * hiScale
                    let ink = min(
                        1.0,
                        Filament.glintInk * pow(glintT, 1.2) * (nodes[index].isFront ? 1.0 : Filament.backInk) * shown
                    )
                    guard ink > 0.004, rPx > 0.2 else { continue }
                    let cx = Double(pts[index].x) * hiScale
                    let cy = Double(pts[index].y) * hiScale
                    let minX = max(0, Int(floor(cx - rPx)))
                    let maxX = min(wHi - 1, Int(ceil(cx + rPx)))
                    let minY = max(0, Int(floor(cy - rPx)))
                    let maxY = min(hHi - 1, Int(ceil(cy + rPx)))
                    guard minX <= maxX, minY <= maxY else { continue }
                    let invR = 1.0 / rPx
                    var py = minY - 1
                    while py < maxY {
                        py += 1
                        let dy = Double(py) + 0.5 - cy
                        let rowOffset = py * wireStride
                        var px = minX - 1
                        while px < maxX {
                            px += 1
                            let dx = Double(px) + 0.5 - cx
                            let dist = hypot(dx, dy)
                            guard dist < rPx else { continue }
                            let falloff = 1.0 - dist * invR
                            let a = ink * falloff * falloff
                            plotAdditivePixel(
                                ptr: wirePtr,
                                offset: rowOffset + px * 4,
                                addB: Int(specular.blue * a * 255.0),
                                addG: Int(specular.green * a * 255.0),
                                addR: Int(specular.red * a * 255.0),
                                addA: Int(a * 255.0)
                            )
                        }
                    }
                }
            }
        }

        let convScratch = scratch ?? VisualizerRenderScratch()
        convolveAndComposite(
            srcCtx: haloCtx,
            dstSlot: &convScratch.haloDstCtx,
            dstWidth: &convScratch.haloDstWidth,
            dstHeight: &convScratch.haloDstHeight,
            vImageTemp: &convScratch.vImageTemp,
            width: wHalf,
            height: hHalf,
            kernel: 7,
            targetSize: size,
            into: ctx
        )
        convolveAndComposite(
            srcCtx: glowCtx,
            dstSlot: &convScratch.glowDstCtx,
            dstWidth: &convScratch.glowDstWidth,
            dstHeight: &convScratch.glowDstHeight,
            vImageTemp: &convScratch.vImageTemp,
            width: w1,
            height: h1,
            kernel: 5,
            targetSize: size,
            into: ctx
        )

        if let wireImg = wireCtx.makeImage() {
            ctx.saveGState()
            ctx.setBlendMode(.plusLighter)
            ctx.interpolationQuality = .low
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(wireImg, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }

        ctx.restoreGState()
    }

    // MARK: - 03 Silk

    private static func drawSilk(
        _ frame: VisualizerFrame,
        in ctx: CGContext,
        size: CGSize,
        scratch: VisualizerRenderScratch?
    ) {
        let Silk = HUDWaveform.Silk.self
        let mid = size.height / 2
        let reach = Silk.reach(forHeight: size.height)
        let controls = Silk.windowControls(history: frame.history, reduceMotion: frame.reduceMotion)
        let inset = min(Silk.inset, size.width / 2)
        let width = size.width - inset * 2
        guard width > 1 else { return }
        let clock = frame.reduceMotion ? 0 : frame.effectiveTime
        let count = Silk.sampleCount
        let last = Double(count - 1)

        let s = scratch ?? VisualizerRenderScratch()
        s.silkEnergies.removeAll(keepingCapacity: true)
        if s.silkEnergies.capacity < count { s.silkEnergies.reserveCapacity(count) }
        for index in 0..<count {
            s.silkEnergies.append(Silk.energy(controls, at: Double(index) / last))
        }
        let framePeak = s.silkEnergies.max() ?? 0
        let fillScale = Silk.fillOpacityScale(for: framePeak)
        let rimScale = Silk.rimOpacityScale(for: framePeak)

        let gradientStart = CGPoint(x: 0, y: mid - reach)
        let gradientEnd = CGPoint(x: 0, y: mid + reach)

        if s.silkTop.capacity < count { s.silkTop.reserveCapacity(count) }
        if s.silkBottom.capacity < count { s.silkBottom.reserveCapacity(count) }
        if s.silkHalfThickness.capacity < count { s.silkHalfThickness.reserveCapacity(count) }

        for ribbon in 0..<Silk.ribbonCount {
            s.silkTop.removeAll(keepingCapacity: true)
            s.silkBottom.removeAll(keepingCapacity: true)
            s.silkHalfThickness.removeAll(keepingCapacity: true)

            for index in 0..<count {
                let u = Double(index) / last
                let taper = Silk.cachedEdges[index]
                let energy = s.silkEnergies[index]
                let x = inset + CGFloat(u) * width
                let centre = mid + Silk.centreOffset(
                    ribbon: ribbon,
                    u: u,
                    energy: energy,
                    reach: reach,
                    time: clock,
                    taper: taper
                )
                let half = Silk.halfThickness(
                    ribbon: ribbon,
                    u: u,
                    energy: energy,
                    reach: reach,
                    time: clock,
                    taper: taper
                )
                s.silkTop.append(CGPoint(x: x, y: centre - half))
                s.silkBottom.append(CGPoint(x: x, y: centre + half))
                s.silkHalfThickness.append(half)
            }

            let band = CGMutablePath()
            band.move(to: s.silkTop[0])
            for point in s.silkTop.dropFirst() { band.addLine(to: point) }
            for point in s.silkBottom.reversed() { band.addLine(to: point) }
            band.closeSubpath()

            let lit = MeterRamp.rgb(
                level: min(Silk.fillStops[ribbon], MeterRamp.bodyPosition),
                material: frame.material
            )
            let shaded = MeterRamp.rgb(level: 0, material: frame.material)
            if let bandGrad = gradient(
                colors: [
                    rampColor(lit, opacity: Silk.topInk[ribbon] * fillScale),
                    rampColor(shaded, opacity: Silk.bottomInk[ribbon] * fillScale),
                ],
                locations: [0, 1]
            ) {
                ctx.saveGState()
                ctx.addPath(band)
                ctx.clip()
                ctx.drawLinearGradient(
                    bandGrad,
                    start: gradientStart,
                    end: gradientEnd,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
                ctx.restoreGState()
            }

            let rimLevel = Silk.rimStops[ribbon]
            let upper = MeterRamp.specularBand(level: rimLevel, material: frame.material)
            let lower = MeterRamp.rgb(level: rimLevel, material: frame.material)
            ctx.saveGState()
            ctx.setLineWidth(Silk.rimWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            for contourIndex in 0..<2 {
                let contour = contourIndex == 0 ? s.silkTop : s.silkBottom
                let path = CGMutablePath()
                var inRun = false
                var runHasMultiple = false
                var runFirst = CGPoint.zero
                for index in 0..<count {
                    if s.silkHalfThickness[index] >= Silk.rimMinimumHalfThickness {
                        if !inRun {
                            inRun = true
                            runHasMultiple = false
                            runFirst = contour[index]
                        } else {
                            if !runHasMultiple {
                                path.move(to: runFirst)
                                runHasMultiple = true
                            }
                            path.addLine(to: contour[index])
                        }
                    } else {
                        inRun = false
                        runHasMultiple = false
                    }
                }
                if !path.isEmpty {
                    let tint = contourIndex == 0 ? upper : lower
                    ctx.setStrokeColor(rampColor(tint, opacity: Silk.rimInk[ribbon] * rimScale))
                    ctx.addPath(path)
                    ctx.strokePath()
                }
            }
            ctx.restoreGState()
        }
    }

    // MARK: - 05 Matrix

    private struct MatrixPremulSample: Sendable {
        let r: Double
        let g: Double
        let b: Double
        let a: Double
    }

    private enum MatrixColorLUT {
        static let buckets = 32
        static let radialSteps = 16
        static let blackLit: [MatrixPremulSample] = build(material: .black, highlight: true)
        static let blackPlain: [MatrixPremulSample] = build(material: .black, highlight: false)
        static let glassLit: [MatrixPremulSample] = build(material: .glass, highlight: true)
        static let glassPlain: [MatrixPremulSample] = build(material: .glass, highlight: false)

        static func table(material: HUDMaterial, highlight: Bool) -> [MatrixPremulSample] {
            switch (material, highlight) {
            case (.black, true): blackLit
            case (.black, false): blackPlain
            case (.glass, true): glassLit
            case (.glass, false): glassPlain
            }
        }

        private static func build(material: HUDMaterial, highlight: Bool) -> [MatrixPremulSample] {
            let floorTint = MeterRamp.rgb(level: 0, material: material)
            let stops = MeterRamp.stops(for: material)
            var flat: [MatrixPremulSample] = []
            flat.reserveCapacity((buckets + 1) * radialSteps)
            for bucket in 0...buckets {
                let display = Double(bucket) / Double(buckets)
                let body = MeterRamp.rgb(level: display, material: material)
                let rim = MeterRamp.mix(body, floorTint, 0.20)
                let specularWeight = highlight
                    ? MeterRamp.smoothstep(HUDWaveform.MatrixLattice.specularOnset, 1, display)
                    : 0
                let die = MeterRamp.mix(body, stops.specular, specularWeight)
                let centerAlpha = 0.85 + 0.15 * display
                let midAlpha = 0.55 + 0.40 * display
                let rimAlpha = 0.92 + 0.08 * display

                for step in 0..<radialSteps {
                    let t = Double(step) / Double(radialSteps - 1)
                    var red: Double
                    var green: Double
                    var blue: Double
                    var alpha: Double
                    if t <= 0.22 {
                        red = die.red
                        green = die.green
                        blue = die.blue
                        alpha = centerAlpha
                    } else if t <= 0.45 {
                        let f = (t - 0.22) / 0.23
                        red = die.red + (body.red - die.red) * f
                        green = die.green + (body.green - die.green) * f
                        blue = die.blue + (body.blue - die.blue) * f
                        alpha = centerAlpha + (midAlpha - centerAlpha) * f
                    } else {
                        let f = (t - 0.45) / 0.55
                        red = body.red + (rim.red - body.red) * f
                        green = body.green + (rim.green - body.green) * f
                        blue = body.blue + (rim.blue - body.blue) * f
                        alpha = midAlpha + (rimAlpha - midAlpha) * f
                    }

                    var pR = red * alpha
                    var pG = green * alpha
                    var pB = blue * alpha
                    var pA = alpha

                    if specularWeight > 0, t <= 0.22 {
                        let oneMinusSpec = 1.0 - specularWeight
                        pR = stops.specular.red * specularWeight + pR * oneMinusSpec
                        pG = stops.specular.green * specularWeight + pG * oneMinusSpec
                        pB = stops.specular.blue * specularWeight + pB * oneMinusSpec
                        pA = specularWeight + pA * oneMinusSpec
                    }
                    flat.append(MatrixPremulSample(r: pR, g: pG, b: pB, a: pA))
                }
            }
            return flat
        }
    }

    private static func drawMatrix(
        _ frame: VisualizerFrame,
        in ctx: CGContext,
        size: CGSize,
        scratch: VisualizerRenderScratch?
    ) {
        let MatrixLattice = HUDWaveform.MatrixLattice.self
        let pitch = MatrixLattice.pitch(forHeight: size.height)
        guard pitch > 0 else { return }

        let scale = max(1.0, min(2.0, hypot(ctx.ctm.a, ctx.ctm.b)))
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        guard let bufCtx = scratch?.ensureContext(
            &scratch!.primaryCtx,
            width: &scratch!.primaryWidth,
            height: &scratch!.primaryHeight,
            targetWidth: width,
            targetHeight: height,
            colorSpace: colorSpace,
            clear: true
        ) ?? allocateContext(width: width, height: height),
        let rawData = bufCtx.data else {
            return
        }

        let ptr = rawData.assumingMemoryBound(to: UInt8.self)
        let stride = bufCtx.bytesPerRow
        let scaleD = Double(scale)
        let floorTint = MeterRamp.rgb(level: 0, material: frame.material)
        let floorOpacity = MeterRamp.tint(level: 0, ceiling: 1, material: frame.material).opacity
        let lut = MatrixColorLUT.table(material: frame.material, highlight: frame.highlight)

        let dots = HUDWaveform.matrixDots(
            in: size,
            history: frame.history,
            spectrumHistory: frame.spectrumHistory,
            phase: frame.phase,
            time: frame.effectiveTime,
            reduceMotion: frame.reduceMotion
        )

        lut.withUnsafeBufferPointer { lutBuf in
            for dot in dots {
                guard dot.edgeFade > 0 else { continue }
                let cx = Double(dot.centre.x) * scaleD
                let cy = Double(dot.centre.y) * scaleD
                let rPx = Double(dot.radius) * scaleD
                guard rPx > 0.05 else { continue }
                let outerR = rPx + 0.5
                let outerR2 = outerR * outerR
                let invR = 15.0 / max(0.001, rPx)

                let minX = max(0, Int(floor(cx - outerR)))
                let maxX = min(width - 1, Int(ceil(cx + outerR)))
                let minY = max(0, Int(floor(cy - outerR)))
                let maxY = min(height - 1, Int(ceil(cy + outerR)))
                guard minX <= maxX, minY <= maxY else { continue }

                let fA = floorOpacity * dot.edgeFade
                let fR = floorTint.red * fA
                let fG = floorTint.green * fA
                let fB = floorTint.blue * fA
                let litAlpha = dot.reveal * dot.edgeFade

                if litAlpha > 0.002 {
                    let clampedDisplay = min(1.0, max(0.0, dot.display))
                    let bucket = min(MatrixColorLUT.buckets, max(0, Int((clampedDisplay * 32.0).rounded())))
                    let bucketBase = bucket * MatrixColorLUT.radialSteps

                    var py = minY - 1
                    while py < maxY {
                        py += 1
                        let dy = Double(py) + 0.5 - cy
                        let dy2 = dy * dy
                        let rowOffset = py * stride
                        var px = minX - 1
                        while px < maxX {
                            px += 1
                            let dx = Double(px) + 0.5 - cx
                            let d2 = dx * dx + dy2
                            guard d2 < outerR2 else { continue }
                            let dist = sqrt(d2)
                            let cov = min(1.0, max(0.0, outerR - dist))
                            let step = min(15, Int(dist * invR))
                            let sample = lutBuf[bucketBase + step]

                            let sR = sample.r * litAlpha
                            let sG = sample.g * litAlpha
                            let sB = sample.b * litAlpha
                            let sA = sample.a * litAlpha
                            let oneMinusSA = 1.0 - sA

                            let outR = (sR + fR * oneMinusSA) * cov * 255.0
                            let outG = (sG + fG * oneMinusSA) * cov * 255.0
                            let outB = (sB + fB * oneMinusSA) * cov * 255.0
                            let outA = (sA + fA * oneMinusSA) * cov * 255.0

                            let offset = rowOffset + px * 4
                            ptr[offset] = UInt8(min(255, max(0, Int(outB + 0.5))))
                            ptr[offset + 1] = UInt8(min(255, max(0, Int(outG + 0.5))))
                            ptr[offset + 2] = UInt8(min(255, max(0, Int(outR + 0.5))))
                            ptr[offset + 3] = UInt8(min(255, max(0, Int(outA + 0.5))))
                        }
                    }
                } else {
                    var py = minY - 1
                    while py < maxY {
                        py += 1
                        let dy = Double(py) + 0.5 - cy
                        let dy2 = dy * dy
                        let rowOffset = py * stride
                        var px = minX - 1
                        while px < maxX {
                            px += 1
                            let dx = Double(px) + 0.5 - cx
                            let d2 = dx * dx + dy2
                            guard d2 < outerR2 else { continue }
                            let cov = min(1.0, max(0.0, outerR - sqrt(d2)))
                            let scaleCov = cov * 255.0
                            let offset = rowOffset + px * 4
                            ptr[offset] = UInt8(min(255, max(0, Int(fB * scaleCov + 0.5))))
                            ptr[offset + 1] = UInt8(min(255, max(0, Int(fG * scaleCov + 0.5))))
                            ptr[offset + 2] = UInt8(min(255, max(0, Int(fR * scaleCov + 0.5))))
                            ptr[offset + 3] = UInt8(min(255, max(0, Int(fA * scaleCov + 0.5))))
                        }
                    }
                }
            }
        }

        if let img = bufCtx.makeImage() {
            ctx.saveGState()
            ctx.interpolationQuality = .low
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
    }

    // MARK: - 06 Halo

    private struct HaloRingFrame {
        let energy: Double
        let orientation: HUDWaveform.Halo.Orientation
        let kick: Double
        let speed: Double
    }

    private static func drawHalo(
        _ frame: VisualizerFrame,
        in ctx: CGContext,
        size: CGSize
    ) {
        let Halo = HUDWaveform.Halo.self
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let source = frame.reduceMotion
            ? VisualizerMath.peakHold(frame.history, ticks: Halo.holdSamples)
            : frame.history
        let clock = frame.reduceMotion ? 0 : frame.time
        let ringFrames = (0..<Halo.ringCount).map { ring -> HaloRingFrame in
            let energy = Halo.ringEnergy(ring, history: source)
            return HaloRingFrame(
                energy: energy,
                orientation: Halo.orientation(
                    ring: ring,
                    time: clock,
                    energy: energy,
                    width: size.width,
                    height: size.height
                ),
                kick: frame.reduceMotion ? 0 : Halo.kick(ring: ring, history: source),
                speed: frame.reduceMotion ? 0 : Halo.angularSpeed(ring: ring, history: source)
            )
        }

        for layer in Halo.layerOrder {
            switch layer {
            case .ringBack(let ring):
                drawHaloRing(
                    frame: frame,
                    in: ctx,
                    ring: ring,
                    front: false,
                    ringFrame: ringFrames[ring],
                    centre: centre,
                    clock: clock
                )
            case .core:
                drawHaloCore(frame: frame, in: ctx, size: size, source: source)
            case .ringFront(let ring):
                drawHaloRing(
                    frame: frame,
                    in: ctx,
                    ring: ring,
                    front: true,
                    ringFrame: ringFrames[ring],
                    centre: centre,
                    clock: clock
                )
            }
        }
    }

    private static func drawHaloCore(
        frame: VisualizerFrame,
        in ctx: CGContext,
        size: CGSize,
        source: [Double]
    ) {
        let Halo = HUDWaveform.Halo.self
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let energy = Halo.coreEnergy(history: source)
        let target = frame.reduceMotion
            ? Halo.coreRadius(energy: energy, time: 0)
            : Halo.elasticCoreRadius(
                history: source,
                time: frame.time,
                hertz: Halo.coreSpringHertz,
                damping: Halo.coreSpringDamping
            )
        let radius = max(0.5, target)

        // Core glow
        let reach = Halo.glowReach * radius
        let ink = Halo.glowInk * (Halo.glowRestShare + (1 - Halo.glowRestShare) * energy)
        let glowTint = MeterRamp.tint(level: energy, ceiling: frame.ceiling, material: frame.material)
        let glowColor = rampColor(glowTint, opacity: ink)
        let glowClear = rampColor(glowTint, opacity: 0)
        if let glowGrad = gradient(
            colors: [glowColor, glowColor, glowClear],
            locations: [0, Halo.glowStart / Halo.glowReach, 1]
        ) {
            ctx.drawRadialGradient(
                glowGrad,
                startCenter: centre,
                startRadius: 0,
                endCenter: centre,
                endRadius: reach,
                options: []
            )
        }

        // Core rays
        let stretch = min(1.35, max(0, (radius - Halo.restCoreRadius) / Halo.coreGain))
        let turn = frame.reduceMotion ? 0 : 2 * Double.pi * frame.time / Halo.rayTurnSeconds
        let rayTint = MeterRamp.tint(level: energy, ceiling: frame.ceiling, material: frame.material)
        let rayColor = rampColor(rayTint, opacity: min(1, Halo.rayInk * frame.ringInkGain), lift: frame.ringLift)
        let rayClear = rampColor(rayTint, opacity: 0, lift: frame.ringLift)
        if let rayGrad = gradient(colors: [rayColor, rayClear], locations: [0, 1]) {
            let inner = Halo.rayInner * radius
            let rayReach = radius * (Halo.rayReach + Halo.rayVoiceReach * stretch)
            let length = rayReach - inner
            for ray in 0..<Halo.rayCount {
                let angle = turn + 2 * Double.pi * Double(ray) / Double(Halo.rayCount)
                let along = CGPoint(x: CGFloat(cos(angle)), y: CGFloat(sin(angle)))
                let across = CGPoint(x: -along.y, y: along.x)
                let start = CGPoint(x: centre.x + along.x * inner, y: centre.y + along.y * inner)
                let span = ray % 2 == 0 ? length : length * Halo.rayAlternate
                let tip = CGPoint(x: start.x + along.x * span, y: start.y + along.y * span)
                let path = CGMutablePath()
                path.move(to: CGPoint(
                    x: start.x + across.x * Halo.rayHalfWidth,
                    y: start.y + across.y * Halo.rayHalfWidth
                ))
                path.addLine(to: CGPoint(
                    x: start.x - across.x * Halo.rayHalfWidth,
                    y: start.y - across.y * Halo.rayHalfWidth
                ))
                path.addLine(to: tip)
                path.closeSubpath()
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                ctx.drawLinearGradient(
                    rayGrad,
                    start: start,
                    end: tip,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
                ctx.restoreGState()
            }
        }

        // Core shine
        let tint = MeterRamp.tint(level: energy, ceiling: frame.ceiling, material: frame.material)
        let colour = rampColor(tint, opacity: tint.opacity)
        let colourClear = rampColor(tint, opacity: 0)
        let ramp = MeterRamp.stops(for: frame.material)
        let apexTint = MeterRamp.rgb(level: MeterRamp.peakPosition, material: frame.material)
        let apex = rampColor(apexTint, opacity: 1)
        let specular = cgColor(
            red: ramp.specular.red,
            green: ramp.specular.green,
            blue: ramp.specular.blue,
            alpha: 1
        )
        let shineColors: [CGColor]
        let shineLocations: [CGFloat]
        if frame.material == .glass {
            let share = Halo.hotCentreShare
            shineColors = [specular, specular, apex, colour, colourClear]
            shineLocations = [0, share, share, 0.75, 1]
        } else {
            shineColors = [specular, apex, colour, colourClear]
            shineLocations = [0, 0.30, 0.70, 1]
        }
        if let shineGrad = gradient(colors: shineColors, locations: shineLocations) {
            ctx.drawRadialGradient(
                shineGrad,
                startCenter: centre,
                startRadius: 0,
                endCenter: centre,
                endRadius: radius,
                options: []
            )
        }
    }

    private static func drawHaloRing(
        frame: VisualizerFrame,
        in ctx: CGContext,
        ring: Int,
        front: Bool,
        ringFrame: HaloRingFrame,
        centre: CGPoint,
        clock: Double
    ) {
        let Halo = HUDWaveform.Halo.self
        let ringTint = MeterRamp.rgb(level: ringFrame.energy, material: frame.material)
        let gain = frame.ringInkGain
        let lift = frame.ringLift
        let trackInk = Halo.trackFloor + Halo.trackGain * ringFrame.energy
        let basis = Halo.RingBasis(orientation: ringFrame.orientation)

        let trackPath = CGMutablePath()
        let start = front ? 0 : Double.pi
        for step in 0...Halo.trackSteps {
            let theta = start + Double.pi * Double(step) / Double(Halo.trackSteps)
            let spot = basis.point(theta: theta, centre: centre).point
            if step == 0 {
                trackPath.move(to: spot)
            } else {
                trackPath.addLine(to: spot)
            }
        }
        ctx.saveGState()
        ctx.setLineWidth(Halo.trackWidth)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(rampColor(
            ringTint,
            opacity: front ? min(1, trackInk * gain) : min(1, trackInk * Halo.backInk * gain),
            lift: lift
        ))
        ctx.addPath(trackPath)
        ctx.strokePath()
        ctx.restoreGState()

        let count = Halo.particleCounts[ring]
        let sign: Double = Halo.revolutions[ring] < 0 ? -1 : 1
        let trailScale = Halo.trailScale(ring: ring, speed: ringFrame.speed)
        let bucketCount = 16
        var trailBuckets = [CGMutablePath?](repeating: nil, count: bucketCount)
        var spotBuckets = [CGMutablePath?](repeating: nil, count: bucketCount)

        func opacityBucket(_ alpha: Double) -> Int? {
            guard alpha > 0.002 else { return nil }
            let clamped = min(1, alpha)
            return min(bucketCount - 1, max(0, Int(sqrt(clamped) * Double(bucketCount))))
        }

        for index in 0..<count {
            let theta = Halo.particleAngle(ring: ring, index: index, kick: ringFrame.kick, time: clock)
            let spot = basis.point(theta: theta, centre: centre)
            guard (spot.depth > 0) == front else { continue }
            let band = Halo.particleBand(ring: ring, index: index, spectrum: frame.spectrumHistory)
            let radius = Halo.particleRadius(band: band, depth: spot.depth)
            let ink = min(1, Halo.particleInk(depth: spot.depth, energy: ringFrame.energy) * gain)

            if !frame.reduceMotion {
                for (ghost, angle) in Halo.trailAngles.enumerated() {
                    guard let idx = opacityBucket(ink * Halo.trailInk[ghost]) else { continue }
                    let trailTheta = theta - sign * angle * trailScale
                    let trail = basis.point(theta: trailTheta, centre: centre)
                    guard (trail.depth > 0) == front else { continue }
                    let trailRadius = radius * CGFloat(Halo.trailRadii[ghost])
                    let rect = CGRect(
                        x: trail.point.x - trailRadius,
                        y: trail.point.y - trailRadius,
                        width: trailRadius * 2,
                        height: trailRadius * 2
                    )
                    if trailBuckets[idx] == nil { trailBuckets[idx] = CGMutablePath() }
                    trailBuckets[idx]?.addEllipse(in: rect)
                }
            }

            if let spotIdx = opacityBucket(ink) {
                let spotRect = CGRect(
                    x: spot.point.x - radius,
                    y: spot.point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                if spotBuckets[spotIdx] == nil { spotBuckets[spotIdx] = CGMutablePath() }
                spotBuckets[spotIdx]?.addEllipse(in: spotRect)
            }
        }

        for idx in 0..<bucketCount {
            if let path = trailBuckets[idx] {
                let u = (Double(idx) + 0.5) / Double(bucketCount)
                ctx.setFillColor(rampColor(ringTint, opacity: u * u, lift: lift))
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
        for idx in 0..<bucketCount {
            if let path = spotBuckets[idx] {
                let u = (Double(idx) + 0.5) / Double(bucketCount)
                ctx.setFillColor(rampColor(ringTint, opacity: u * u, lift: lift))
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
    }
}

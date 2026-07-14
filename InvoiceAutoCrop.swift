import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum OutputMode {
    case both
    case imageOnly
    case pdfOnly
}

struct Options {
    var mode: OutputMode = .both
    var enhance = true
    var deskew = true
    var outputDirectory: URL?
    var inputs: [URL] = []
}

enum CropError: LocalizedError {
    case unreadableImage(URL)
    case renderFailed
    case imageWriteFailed(URL)
    case pdfWriteFailed(URL)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let url):
            return "无法读取图片：\(url.path)"
        case .renderFailed:
            return "图片渲染失败"
        case .imageWriteFailed(let url):
            return "无法保存图片：\(url.path)"
        case .pdfWriteFailed(let url):
            return "无法保存 PDF：\(url.path)"
        }
    }
}

struct DetectionResult {
    let rectangle: VNRectangleObservation?
    let method: String
}

struct DeskewResult {
    let image: CIImage
    let angleDegrees: Double?
}

final class InvoiceProcessor {
    private let context = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false,
    ])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func process(_ inputURL: URL, options: Options) throws -> [URL] {
        guard var image = CIImage(
            contentsOf: inputURL,
            options: [
                .applyOrientationProperty: true,
                .toneMapHDRtoSDR: true,
            ]
        ) else {
            throw CropError.unreadableImage(inputURL)
        }

        // Normalize the coordinate system so Vision and Core Image share the
        // same bottom-left origin and zero-based extent.
        if image.extent.origin != .zero {
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x,
                y: -image.extent.origin.y
            ))
        }

        let detection = try detectDocument(in: image)
        var corrected = image
        var didCorrectPerspective = false
        if let rectangle = detection.rectangle,
           isUsable(rectangle, imageExtent: image.extent) {
            corrected = perspectiveCorrect(image, rectangle: rectangle)
            corrected = trimLongDocumentFringe(corrected)
            didCorrectPerspective = true
        }

        let deskewResult = options.deskew
            ? deskewDocument(corrected, preserveVerticalEdges: didCorrectPerspective)
            : DeskewResult(image: corrected, angleDegrees: nil)
        corrected = deskewResult.image

        if options.enhance {
            corrected = enhanceDocument(corrected)
        }

        guard let cgImage = context.createCGImage(
            corrected,
            from: corrected.extent.integral,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            throw CropError.renderFailed
        }

        let outputDirectory = options.outputDirectory
            ?? inputURL.deletingLastPathComponent()
        let stem = inputURL.deletingPathExtension().lastPathComponent + "_自动裁剪"
        var outputs: [URL] = []

        if options.mode != .pdfOnly {
            let imageURL = uniqueURL(
                directory: outputDirectory,
                stem: stem,
                extension: "jpg"
            )
            try writeJPEG(cgImage, to: imageURL)
            outputs.append(imageURL)
        }

        if options.mode != .imageOnly {
            let pdfURL = uniqueURL(
                directory: outputDirectory,
                stem: stem,
                extension: "pdf"
            )
            try writePDF(cgImage, to: pdfURL)
            outputs.append(pdfURL)
        }

        let cropStatus = detection.rectangle == nil ? "未检测到纸张，保留整图" : detection.method
        let deskewStatus = deskewResult.angleDegrees.map {
            String(format: "二次纠偏 %.2f°", $0)
        } ?? (options.deskew ? "无需二次纠偏" : "已关闭二次纠偏")
        FileHandle.standardError.write(Data(
            "INFO\t\(inputURL.path)\t\(cropStatus)；\(deskewStatus)\n".utf8
        ))
        return outputs
    }

    private func detectDocument(in image: CIImage) throws -> DetectionResult {
        let documentRequest = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([documentRequest])

        if let rectangle = documentRequest.results?.first {
            return DetectionResult(rectangle: rectangle, method: "文档边缘识别")
        }

        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.maximumObservations = 8
        rectangleRequest.minimumConfidence = 0.35
        rectangleRequest.minimumAspectRatio = 0.15
        rectangleRequest.maximumAspectRatio = 1.0
        rectangleRequest.minimumSize = 0.15
        rectangleRequest.quadratureTolerance = 35

        let fallbackHandler = VNImageRequestHandler(ciImage: image, options: [:])
        try fallbackHandler.perform([rectangleRequest])
        let largest = rectangleRequest.results?.max {
            normalizedArea($0) < normalizedArea($1)
        }
        return DetectionResult(rectangle: largest, method: "矩形边缘识别")
    }

    private func isUsable(_ rectangle: VNRectangleObservation, imageExtent: CGRect) -> Bool {
        normalizedArea(rectangle) > 0.08 && imageExtent.width > 32 && imageExtent.height > 32
    }

    private func normalizedArea(_ rectangle: VNRectangleObservation) -> CGFloat {
        let points = [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
        var signedArea = CGFloat.zero
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            signedArea += current.x * next.y - next.x * current.y
        }
        return abs(signedArea) / 2.0
    }

    private func perspectiveCorrect(_ image: CIImage, rectangle: VNRectangleObservation) -> CIImage {
        let width = image.extent.width
        let height = image.extent.height

        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: normalized.x * width, y: normalized.y * height)
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = point(rectangle.topLeft)
        filter.topRight = point(rectangle.topRight)
        filter.bottomLeft = point(rectangle.bottomLeft)
        filter.bottomRight = point(rectangle.bottomRight)

        guard var output = filter.outputImage else { return image }
        if output.extent.origin != .zero {
            output = output.transformed(by: CGAffineTransform(
                translationX: -output.extent.origin.x,
                y: -output.extent.origin.y
            ))
        }
        return output
    }

    /// Long receipts often leave a very narrow strip of the desk or phone UI
    /// along the detected sides. Remove only that interpolation fringe; the
    /// conservative inset stays well inside a receipt's normal blank margin.
    private func trimLongDocumentFringe(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.height / max(extent.width, 1) >= 2.5 else { return image }

        let horizontalInset = min(max(extent.width * 0.018, 2), 16)
        let crop = extent.insetBy(dx: horizontalInset, dy: 0).integral
        guard crop.width > 32, crop.height > 32 else { return image }

        var output = image.cropped(to: crop)
        output = output.transformed(by: CGAffineTransform(
            translationX: -crop.origin.x,
            y: -crop.origin.y
        ))
        return output
    }

    /// Corrects the small residual rotation that may remain after perspective
    /// correction. Invoices usually contain many text baselines and table
    /// rules, so a projection-profile search over horizontal edge pixels gives
    /// a stable angle without OCR or network services.
    private func deskewDocument(
        _ image: CIImage,
        preserveVerticalEdges: Bool
    ) -> DeskewResult {
        guard let angle = estimateDeskewAngle(image) else {
            return DeskewResult(image: image, angleDegrees: nil)
        }

        // Bitmap rows run in the opposite vertical direction to Core Image's
        // Cartesian coordinates, so the estimated value is already the
        // corrective (rather than observed) rotation angle.
        let radians = CGFloat(angle * .pi / 180)
        let transformed: CIImage
        let finalExtent: CGRect
        if preserveVerticalEdges {
            // Perspective correction has already made the paper boundaries a
            // rectangle. Rotating that rectangle again would leave the whole
            // document diagonally placed on a white canvas. A vertical shear
            // instead levels text/table lines while keeping both side edges
            // vertical and preserving the document width.
            let shear = tan(radians)
            let transform = CGAffineTransform(
                a: 1,
                b: shear,
                c: 0,
                d: 1,
                tx: 0,
                ty: -shear * image.extent.midX
            )
            transformed = image.transformed(by: transform)
            let verticalInset = abs(shear) * image.extent.width / 2
            finalExtent = CGRect(
                x: image.extent.minX,
                y: image.extent.minY + verticalInset,
                width: image.extent.width,
                height: image.extent.height - verticalInset * 2
            ).integral
        } else {
            let center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: radians)
                .translatedBy(x: -center.x, y: -center.y)
            transformed = image.transformed(by: transform)
            finalExtent = transformed.extent.integral
        }

        guard finalExtent.width > 32, finalExtent.height > 32 else {
            return DeskewResult(image: image, angleDegrees: nil)
        }
        let outputExtent = finalExtent
        let white = CIImage(color: CIColor.white).cropped(to: outputExtent)
        var output = transformed.composited(over: white).cropped(to: outputExtent)

        if output.extent.origin != .zero {
            output = output.transformed(by: CGAffineTransform(
                translationX: -output.extent.origin.x,
                y: -output.extent.origin.y
            ))
        }
        return DeskewResult(image: output, angleDegrees: angle)
    }

    private func estimateDeskewAngle(_ image: CIImage) -> Double? {
        let longestSide = max(image.extent.width, image.extent.height)
        guard longestSide > 64 else { return nil }

        let scale = min(1, 1200 / longestSide)
        let preview = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let previewExtent = preview.extent.integral
        guard let cgImage = context.createCGImage(
            preview,
            from: previewExtent,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width >= 64, height >= 64 else { return nil }

        var gray = [UInt8](repeating: 0, count: width * height)
        let rendered = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let graySpace = CGColorSpace(name: CGColorSpace.linearGray),
                  let bitmap = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: graySpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            bitmap.interpolationQuality = .medium
            bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        struct EdgePoint {
            let x: Double
            let y: Double
            let weight: Double
        }

        // Keep edges whose vertical gradient dominates. These are primarily
        // horizontal table rules and the upper/lower edges of text strokes.
        let stride = max(1, min(width, height) / 700)
        var points: [EdgePoint] = []
        points.reserveCapacity(60_000)
        for y in Swift.stride(from: 2, to: height - 2, by: stride) {
            for x in Swift.stride(from: 2, to: width - 2, by: stride) {
                let vertical = abs(Int(gray[(y + 1) * width + x]) - Int(gray[(y - 1) * width + x]))
                guard vertical >= 20 else { continue }
                let horizontal = abs(Int(gray[y * width + x + 1]) - Int(gray[y * width + x - 1]))
                guard Double(vertical) >= Double(horizontal) * 0.85 else { continue }
                points.append(EdgePoint(
                    x: Double(x) - Double(width) / 2,
                    y: Double(y) - Double(height) / 2,
                    weight: Double(min(vertical, 96)) / 96
                ))
            }
        }

        // Uniform thinning keeps the search fast without favouring one area.
        if points.count > 90_000 {
            let step = Double(points.count) / 90_000
            points = (0..<90_000).map { points[Int(Double($0) * step)] }
        }
        guard points.count >= 900 else { return nil }

        let maximumAngle = 7.0
        let bucketPadding = Int(ceil(tan(maximumAngle * .pi / 180) * Double(width) / 2)) + 4
        let bucketCount = height + bucketPadding * 2 + 8

        func score(_ angle: Double) -> Double {
            let slope = tan(angle * .pi / 180)
            var buckets = [Float](repeating: 0, count: bucketCount)
            for point in points {
                let projected = point.y - slope * point.x
                let bucket = Int(projected.rounded()) + height / 2 + bucketPadding + 4
                if bucket >= 0 && bucket < bucketCount {
                    buckets[bucket] += Float(point.weight)
                }
            }
            // Squaring rewards angles that concentrate many edge pixels onto
            // the same rows, which is exactly what happens when lines are level.
            return buckets.reduce(0) { $0 + Double($1 * $1) }
        }

        var coarse: [(angle: Double, score: Double)] = []
        var angle = -maximumAngle
        while angle <= maximumAngle + 0.0001 {
            coarse.append((angle, score(angle)))
            angle += 0.10
        }
        guard let coarseBest = coarse.max(by: { $0.score < $1.score }) else { return nil }

        var best = coarseBest
        angle = coarseBest.angle - 0.10
        while angle <= coarseBest.angle + 0.1001 {
            let candidate = (angle, score(angle))
            if candidate.1 > best.score {
                best = candidate
            }
            angle += 0.02
        }

        let zeroScore = score(0)
        let sortedScores = coarse.map(\.score).sorted()
        let medianScore = sortedScores[sortedScores.count / 2]

        // A meaningful correction must be visible, confidently better than
        // zero rotation, and not pinned to the edge of the search interval.
        guard abs(best.angle) >= 0.20,
              abs(best.angle) <= maximumAngle - 0.08,
              best.score >= zeroScore * 1.025,
              best.score >= medianScore * 1.08 else {
            return nil
        }
        return best.angle
    }

    private func enhanceDocument(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let shortestSide = min(extent.width, extent.height)
        let blurRadius = min(max(shortestSide * 0.025, 14), 58)

        // Estimate the paper illumination with a broad blur, then divide the
        // original by that local background. This is the key scanner-like
        // step: shadows and warm/cool lighting are flattened while coloured
        // stamps and handwriting remain coloured.
        let background = image
            .clampedToExtent()
            .applyingGaussianBlur(sigma: blurRadius)
            .cropped(to: extent)

        let divide = CIFilter(name: "CIDivideBlendMode")
        divide?.setValue(background, forKey: kCIInputImageKey)
        divide?.setValue(image, forKey: kCIInputBackgroundImageKey)
        let normalized = divide?.outputImage?.cropped(to: extent) ?? image

        let controls = CIFilter.colorControls()
        controls.inputImage = normalized
        controls.brightness = 0.012
        controls.contrast = 1.18
        controls.saturation = 1.06

        let noiseReduction = CIFilter.noiseReduction()
        noiseReduction.inputImage = controls.outputImage ?? normalized
        noiseReduction.noiseLevel = 0.015
        noiseReduction.sharpness = 0.45

        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = noiseReduction.outputImage ?? controls.outputImage ?? normalized
        sharpen.radius = 1.4
        sharpen.intensity = 0.62
        return sharpen.outputImage ?? noiseReduction.outputImage ?? controls.outputImage ?? normalized
    }

    private func uniqueURL(directory: URL, stem: String, extension ext: String) -> URL {
        let manager = FileManager.default
        var candidate = directory.appendingPathComponent(stem).appendingPathExtension(ext)
        var index = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(stem) \(index)")
                .appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    private func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CropError.imageWriteFailed(url)
        }

        let properties: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: 0.94,
            kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
            kCGImagePropertyOrientation: 1,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw CropError.imageWriteFailed(url)
        }
    }

    private func writePDF(_ image: CGImage, to url: URL) throws {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let portrait = imageHeight >= imageWidth
        var page = portrait
            ? CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
            : CGRect(x: 0, y: 0, width: 841.89, height: 595.28)

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw CropError.pdfWriteFailed(url)
        }

        pdf.beginPDFPage(nil)
        pdf.setFillColor(NSColor.white.cgColor)
        pdf.fill(page)

        let margin: CGFloat = 18
        let available = page.insetBy(dx: margin, dy: margin)
        let scale = min(available.width / imageWidth, available.height / imageHeight)
        let drawSize = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        let drawRect = CGRect(
            x: (page.width - drawSize.width) / 2,
            y: (page.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        pdf.interpolationQuality = .high
        pdf.draw(image, in: drawRect)
        pdf.endPDFPage()
        pdf.closePDF()
    }
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())

    while !arguments.isEmpty {
        let value = arguments.removeFirst()
        switch value {
        case "--image-only":
            options.mode = .imageOnly
        case "--pdf-only":
            options.mode = .pdfOnly
        case "--both":
            options.mode = .both
        case "--no-enhance":
            options.enhance = false
        case "--no-deskew":
            options.deskew = false
        case "--output-dir":
            if !arguments.isEmpty {
                options.outputDirectory = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
            }
        case "--help", "-h":
            print("用法: invoice-autocrop [--both|--image-only|--pdf-only] [--no-enhance] [--no-deskew] 图片...")
            exit(0)
        default:
            options.inputs.append(URL(fileURLWithPath: value))
        }
    }
    return options
}

let options = parseOptions()
guard !options.inputs.isEmpty else {
    FileHandle.standardError.write(Data("ERROR\t没有收到图片文件\n".utf8))
    exit(64)
}

let processor = InvoiceProcessor()
var failures = 0
for input in options.inputs {
    do {
        let outputs = try processor.process(input, options: options)
        for output in outputs {
            print("OUTPUT\t\(output.path)")
        }
    } catch {
        failures += 1
        FileHandle.standardError.write(Data("ERROR\t\(input.path)\t\(error.localizedDescription)\n".utf8))
    }
}
exit(failures == 0 ? 0 : 1)

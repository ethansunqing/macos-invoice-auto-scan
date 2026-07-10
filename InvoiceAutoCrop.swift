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
        if let rectangle = detection.rectangle,
           isUsable(rectangle, imageExtent: image.extent) {
            corrected = perspectiveCorrect(image, rectangle: rectangle)
        }

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
        FileHandle.standardError.write(Data("INFO\t\(inputURL.path)\t\(cropStatus)\n".utf8))
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
        case "--output-dir":
            if !arguments.isEmpty {
                options.outputDirectory = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
            }
        case "--help", "-h":
            print("用法: invoice-autocrop [--both|--image-only|--pdf-only] [--no-enhance] 图片...")
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

import Foundation
import Vision

/// 本地 OCR（系统 Vision 框架，完全离线、不上传图片）。
///
/// 用 macOS 15 的 Swift 版 Vision API：`RecognizeTextRequest` + `ImageRequestHandler`。
/// 识别结果按**几何位置的阅读顺序**重排（先上后下、同高再从左到右），
/// 因为 Vision 的原始返回顺序在多栏截图里并不总是符合人的阅读顺序。
enum OCRService {

    enum OCRError: LocalizedError {
        case unreadable(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "无法读取截图：\(path)"
            case .failed(let reason): return "文字识别失败：\(reason)"
            }
        }
    }

    /// 识别图片中的文字。中英混排，开启语言纠正。
    static func recognizeText(in url: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OCRError.unreadable(url.lastPathComponent)
        }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [
            Locale.Language(identifier: "zh-Hans"),
            Locale.Language(identifier: "en-US")
        ]

        let observations: [RecognizedTextObservation]
        do {
            observations = try await ImageRequestHandler(url).perform(request)
        } catch {
            throw OCRError.failed(error.localizedDescription)
        }

        let lines = observations.compactMap { observation -> (text: String, box: CGRect)? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let normalized = observation.boundingBox
            // Vision 的归一化坐标是「左下原点 + y 向上」，这里保持原样用于排序
            let box = CGRect(x: normalized.origin.x, y: normalized.origin.y,
                             width: normalized.width, height: normalized.height)
            return (text, box)
        }

        // 同一行容差：高度的一个分数，避免同行文字被拆散
        let tolerance: CGFloat = 0.008
        let sorted = lines.sorted { lhs, rhs in
            if abs(lhs.box.midY - rhs.box.midY) > tolerance {
                return lhs.box.midY > rhs.box.midY   // y 大 = 更靠上 = 先读
            }
            return lhs.box.minX < rhs.box.minX
        }

        return sorted.map(\.text).joined(separator: "\n")
    }
}

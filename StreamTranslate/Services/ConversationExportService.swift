import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

enum ConversationExportFormat {
    case html
    case pdf

    var fileExtension: String {
        switch self {
        case .html: "html"
        case .pdf: "pdf"
        }
    }

    var contentType: UTType {
        switch self {
        case .html: .html
        case .pdf: .pdf
        }
    }
}

/// Generates self-contained, printable documents for the two reading surfaces.
/// HTML keeps the mind map responsive; PDF is rendered by WebKit so the same
/// typography and spacing are preserved when the document is shared or printed.
@MainActor
enum ConversationExportService {
    enum ExportError: LocalizedError {
        case noContent
        case unableToCreatePDF

        var errorDescription: String? {
            switch self {
            case .noContent: "当前没有可导出的内容。"
            case .unableToCreatePDF: "PDF 渲染失败，请改用 HTML 导出。"
            }
        }
    }

    static func exportCaptions(_ entries: [CaptionEntry], format: ConversationExportFormat) async throws -> URL {
        guard !entries.isEmpty else { throw ExportError.noContent }
        let html = captionsHTML(entries)
        return try await write(html: html, format: format, suggestedName: "StreamTranslate-字幕记录")
    }

    static func exportMindMap(_ map: ConversationMindMap, format: ConversationExportFormat) async throws -> URL {
        guard map.hasContent else { throw ExportError.noContent }
        let html = mindMapHTML(map)
        return try await write(html: html, format: format, suggestedName: "StreamTranslate-对话脑图")
    }

    static func captionsHTML(_ entries: [CaptionEntry]) -> String {
        let rows = entries.map { entry in
            let original = entry.originalText.htmlEscaped
            let translated = entry.translatedText.htmlEscaped
            let language = entry.sourceLanguage == .chinese ? "中文原文" : "英文原文"
            return """
            <article class="caption">
              <div class="caption-meta"><time>\(timestamp(entry.timestamp))</time><span>\(language)</span></div>
              <p class="original">\(original)</p>
              \(translated.isEmpty ? "" : "<p class=\"translation\">\(translated)</p>")
            </article>
            """
        }.joined(separator: "\n")
        return document(title: "字幕记录", subtitle: "共 \(entries.count) 条字幕", body: "<section class=\"captions\">\(rows)</section>")
    }

    static func mindMapHTML(_ map: ConversationMindMap) -> String {
        let topics = map.topics.filter { $0.branches.contains { !$0.points.isEmpty } }.map { topic in
            let kind = topic.kind == .advertisement ? "广告 / 赞助" : topic.kind.label
            let branches = topic.branches.filter { !$0.points.isEmpty }.map { branch in
                let points = branch.points.map { point in
                    "<li><strong>\(point.text.htmlEscaped)</strong>\(point.detail.isEmpty ? "" : "<span>\(point.detail.htmlEscaped)</span>")</li>"
                }.joined()
                return "<section class=\"branch\"><h3>\(branch.title.htmlEscaped)<em>\(branch.points.count)</em></h3><ul>\(points)</ul></section>"
            }.joined(separator: "\n")
            return "<article class=\"topic\"><div class=\"topic-heading\"><span class=\"topic-kind\">\(kind)</span><h2>\(topic.title.htmlEscaped)</h2></div>\(branches)</article>"
        }.joined(separator: "\n")
        return document(title: "对话脑图", subtitle: "\(map.topics.count) 个主题 · \(map.topics.reduce(0) { $0 + $1.branches.reduce(0) { $0 + $1.points.count } }) 个节点", body: "<section class=\"mind-map\">\(topics)</section>")
    }

    private static func write(html: String, format: ConversationExportFormat, suggestedName: String) async throws -> URL {
        let panel = NSSavePanel()
        panel.title = "导出内容"
        panel.message = format == .html ? "HTML 可在浏览器中缩放和继续分享。" : "PDF 适合打印和固定版式分享。"
        panel.nameFieldStringValue = suggestedName + "." + format.fileExtension
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }

        switch format {
        case .html:
            try Data(html.utf8).write(to: url, options: .atomic)
        case .pdf:
            let data = try await pdfData(from: html)
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    private static func pdfData(from html: String) async throws -> Data {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 900))
        let delegate = PDFNavigationDelegate()
        webView.navigationDelegate = delegate
        return try await withCheckedThrowingContinuation { continuation in
            delegate.retainedWebView = webView
            delegate.finish = { result in
                switch result {
                case .success(let data): continuation.resume(returning: data)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date).htmlEscaped
    }

    private static func document(title: String, subtitle: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title.htmlEscaped)</title>
        <style>
        :root { color-scheme: light; --ink:#172235; --muted:#64748b; --line:#dbe4ef; --blue:#2775c9; --blue-soft:#eaf3ff; --paper:#f6f8fb; }
        * { box-sizing:border-box; }
        @page { size:auto; margin:18mm 16mm; }
        body { margin:0; background:var(--paper); color:var(--ink); font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC","Helvetica Neue",Arial,sans-serif; line-height:1.6; }
        .page { max-width:980px; margin:0 auto; padding:48px 44px 64px; background:white; min-height:100vh; }
        header { border-bottom:2px solid var(--ink); padding-bottom:22px; margin-bottom:28px; }
        h1 { margin:0 0 7px; font-size:30px; letter-spacing:-.02em; }
        .subtitle { color:var(--muted); font-size:13px; }
        .caption { padding:18px 0 20px; border-bottom:1px solid var(--line); break-inside:avoid; }
        .caption-meta { display:flex; gap:12px; color:var(--muted); font-size:12px; margin-bottom:8px; }
        .caption-meta span { color:var(--blue); }
        .caption p { margin:4px 0; font-size:16px; }
        .caption .original { font-weight:560; }
        .caption .translation { color:#2974bc; }
        .topic { padding:22px 24px 20px; margin:0 0 22px; border:1px solid var(--line); border-radius:14px; break-inside:avoid; }
        .topic-heading { display:flex; align-items:center; gap:10px; margin-bottom:16px; }
        .topic-heading h2 { margin:0; font-size:21px; letter-spacing:-.01em; }
        .topic-kind { color:var(--blue); background:var(--blue-soft); border-radius:999px; padding:3px 9px; font-size:11px; white-space:nowrap; }
        .branch { margin:13px 0 0 15px; padding-left:17px; border-left:2px solid #b8d4f2; break-inside:avoid; }
        .branch h3 { margin:0 0 5px; color:#2b6cae; font-size:14px; }
        .branch h3 em { margin-left:8px; color:var(--muted); font-style:normal; font-size:11px; font-weight:400; }
        ul { margin:0; padding-left:20px; }
        li { padding:4px 0; break-inside:avoid; }
        li strong { font-weight:560; }
        li span { display:block; color:var(--muted); font-size:13px; margin-top:1px; }
        footer { margin-top:30px; color:var(--muted); font-size:11px; text-align:center; }
        @media (max-width:700px) { .page { padding:28px 20px 44px; } h1 { font-size:25px; } .topic { padding:18px 16px; } }
        @media print { body { background:white; } .page { max-width:none; padding:0; } }
        </style></head><body><main class="page"><header><h1>\(title.htmlEscaped)</h1><div class="subtitle">\(subtitle.htmlEscaped) · 由 StreamTranslate 导出</div></header>\(body)<footer>StreamTranslate · 导出时间 \(timestamp(.now))</footer></main></body></html>
        """
    }
}

private final class PDFNavigationDelegate: NSObject, WKNavigationDelegate {
    var finish: ((Result<Data, Error>) -> Void)?
    var retainedWebView: WKWebView?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let configuration = WKPDFConfiguration()
        webView.createPDF(configuration: configuration) { [weak self] result in
            self?.finish?(result)
            self?.finish = nil
            self?.retainedWebView = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish?(.failure(error)); finish = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish?(.failure(error)); finish = nil
    }
}

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

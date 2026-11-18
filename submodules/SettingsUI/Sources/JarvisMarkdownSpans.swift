import Foundation

// Models answer in Markdown; a plain text label would show the asterisks and
// backticks literally. This scans the three markers that actually appear in
// answers (bold, inline code, italic) and drops heading hashes, matching the
// Android JarvisAskActivity renderer.
//
// Deliberately not the shared Telegram markdown parser: that one treats any
// "[...]" as the start of a link and drops the bracket when no "(url)" follows,
// which would eat the server-issued "[channel:13:5]" citations.
//
// Foundation-only so the text rules can be exercised without UIKit.

public enum JarvisMarkdownKind: Equatable {
    case bold
    case code
    case italic
}

public struct JarvisMarkdownSpan: Equatable {
    public let text: String
    public let kind: JarvisMarkdownKind?

    public init(text: String, kind: JarvisMarkdownKind?) {
        self.text = text
        self.kind = kind
    }
}

private let jarvisMarkdownBoldPattern = "\\*\\*(.+?)\\*\\*"
private let jarvisMarkdownCodePattern = "`([^`\\n]+)`"
private let jarvisMarkdownItalicPattern = "(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)"
private let jarvisMarkdownHeadingPattern = "(?m)^[ \\t]*#{1,6}[ \\t]+"

public func jarvisMarkdownSpans(_ answer: String) -> [JarvisMarkdownSpan] {
    // Heading markers only add noise once the line is plain text.
    let stripped = answer.replacingOccurrences(of: jarvisMarkdownHeadingPattern, with: "", options: .regularExpression)
    let text = NSMutableString(string: stripped)
    var kinds = [JarvisMarkdownKind?](repeating: nil, count: text.length)

    jarvisApplyMarkdown(jarvisMarkdownBoldPattern, options: [.dotMatchesLineSeparators], kind: .bold, text: text, kinds: &kinds)
    jarvisApplyMarkdown(jarvisMarkdownCodePattern, options: [], kind: .code, text: text, kinds: &kinds)
    jarvisApplyMarkdown(jarvisMarkdownItalicPattern, options: [], kind: .italic, text: text, kinds: &kinds)

    var spans: [JarvisMarkdownSpan] = []
    var index = 0
    while index < text.length {
        var end = index + 1
        while end < text.length && kinds[end] == kinds[index] {
            end += 1
        }
        let range = NSRange(location: index, length: end - index)
        spans.append(JarvisMarkdownSpan(text: text.substring(with: range), kind: kinds[index]))
        index = end
    }
    return spans
}

private func jarvisApplyMarkdown(_ pattern: String, options: NSRegularExpression.Options, kind: JarvisMarkdownKind, text: NSMutableString, kinds: inout [JarvisMarkdownKind?]) {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
    let matches = regex.matches(in: text as String, options: [], range: NSRange(location: 0, length: text.length))
    // Back to front: deleting a later delimiter cannot shift an earlier span.
    for match in matches.reversed() {
        let content = match.range(at: 1)
        guard content.location != NSNotFound, content.length > 0 else { continue }
        for index in content.location ..< (content.location + content.length) {
            kinds[index] = kind
        }
        let suffix = NSRange(
            location: content.location + content.length,
            length: match.range.location + match.range.length - (content.location + content.length)
        )
        let prefix = NSRange(
            location: match.range.location,
            length: content.location - match.range.location
        )
        if suffix.length > 0 {
            text.deleteCharacters(in: suffix)
            kinds.removeSubrange(suffix.location ..< (suffix.location + suffix.length))
        }
        if prefix.length > 0 {
            text.deleteCharacters(in: prefix)
            kinds.removeSubrange(prefix.location ..< (prefix.location + prefix.length))
        }
    }
}

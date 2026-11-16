import Foundation

/// Shared heuristic for deciding whether a paragraph is a chapter heading.
/// PDF outlines, FB2 and Markdown have real structure; RTF and DOCX often only
/// carry styled paragraphs, so a conservative Chinese/English pattern is used
/// to build a useful table of contents without inventing entries.
enum ChapterHeading {
    static func looksLikeHeading(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return false }
        return trimmed.range(
            of: #"^(第[0-9０-９零〇一二三四五六七八九十百千万两]+[章节回卷部篇]|chapter\s+\d+|序章?|前言|后记|尾声|楔子|番外|目录)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

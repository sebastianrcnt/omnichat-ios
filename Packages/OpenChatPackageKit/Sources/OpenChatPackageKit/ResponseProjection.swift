import Foundation

/// Turns an HTTP tool's response body into what the model reads: JSON through `each`/`fields` into compact canonical
/// JSON, anything else as text; both cut to `maxCharacters` with a note. `sources` makes each item a citable source.
public enum ResponseProjection {
    public static let defaultCharacters = 12_000
    public static let maxCharacters = 60_000
    /// A source's content, at most.
    public static let sourceCharacters = 2_000

    public struct Source: Sendable, Equatable {
        public var title: String
        public var url: String
        public var content: String
        public init(title: String, url: String, content: String) { self.title = title; self.url = url; self.content = content }
    }

    public struct Output: Sendable, Equatable {
        public var text: String
        public var sources: [Source]
        public var truncated: Bool
    }

    /// The character limit for a spec (default 12,000, never above 60,000).
    public static func limit(_ spec: PackageTool.ResponseSpec?) -> Int {
        min(max(spec?.maxCharacters ?? defaultCharacters, 1), maxCharacters)
    }

    public static func project(body: Data, spec: PackageTool.ResponseSpec?) throws -> Output {
        let limit = limit(spec)
        guard let spec, spec.each != nil || spec.fields != nil || spec.sources != nil else {
            // No projection: the raw text (JSON comes back compact and sorted, so the same answer reads the same).
            let text = (try? JSONValue.parse(body))?.canonical ?? String(decoding: body, as: UTF8.self)
            return cut(text, limit: limit, sources: [])
        }
        guard let root = try? JSONValue.parse(body) else {
            throw PackageError.invalid("the response is not JSON, so it can't be read with the tool's response fields.")
        }
        var items: [JSONValue]
        var single = true
        if let each = spec.each {
            guard let list = root.pointer(each)?.arrayValue else {
                throw PackageError.invalid("the response has no array at \(each).")
            }
            items = list
            single = false
        } else {
            items = [root]
        }
        if let fields = spec.fields {
            items = items.map { item in .object(fields.mapValues { item.pointer($0) ?? .null }) }
        }
        var sources: [Source] = []
        if let s = spec.sources {
            for item in items {
                let url = render(s.url, item: item).trimmingCharacters(in: .whitespaces)
                let lower = url.lowercased()
                guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { continue }
                let title = render(s.title, item: item)
                let content = s.content.map { render($0, item: item) } ?? item.canonical
                sources.append(Source(title: title.isEmpty ? url : title, url: url, content: String(content.prefix(sourceCharacters))))
            }
        }
        let value: JSONValue = single ? items[0] : .array(items)
        return cut(value.canonical, limit: limit, sources: sources)
    }

    /// `{field}` replaced by the item's field as text (strings as they are, numbers printed, missing as "").
    public static func render(_ template: String, item: JSONValue) -> String {
        (try? URLTemplate.fill(template, encode: false) { key in
            item[key]?.templateText ?? item.pointer(key.hasPrefix("/") ? key : "/" + key)?.templateText ?? ""
        }) ?? template
    }

    static func cut(_ text: String, limit: Int, sources: [Source]) -> Output {
        guard text.count > limit else { return Output(text: text, sources: sources, truncated: false) }
        return Output(text: String(text.prefix(limit)) + "\n\n[Truncated: the result exceeded \(limit) characters.]",
                      sources: sources, truncated: true)
    }
}

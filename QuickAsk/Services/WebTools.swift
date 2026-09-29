import Foundation

struct WebSearchHit: Sendable {
    let title: String
    let url: String
    let snippet: String
}

enum WebTools {
    static func search(_ query: String, limit: Int = 4) async throws -> String {
        let hits = try await duckDuckGoSearch(query, limit: limit)
        if hits.isEmpty {
            return "No results for: \(query)"
        }
        return hits.enumerated().map { i, hit in
            """
            [\(i + 1)] \(hit.title)
            URL: \(hit.url)
            \(hit.snippet)
            """
        }.joined(separator: "\n\n")
    }

    static func fetchURL(_ urlString: String, maxChars: Int = 8000) async throws -> String {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "Invalid URL: \(urlString)"
        }

        // Jina reader returns clean text/markdown of the page.
        let reader = URL(string: "https://r.jina.ai/\(url.absoluteString)")!
        var request = URLRequest(url: reader)
        request.setValue("QuickAsk/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer unused", forHTTPHeaderField: "Authorization") // ignored by free tier
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return try await fetchURLDirect(url, maxChars: maxChars)
        }
        var text = String(data: data, encoding: .utf8) ?? ""
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return try await fetchURLDirect(url, maxChars: maxChars)
        }
        if text.count > maxChars {
            text = String(text.prefix(maxChars)) + "\n…[truncated]"
        }
        return text
    }

    private static func fetchURLDirect(_ url: URL, maxChars: Int) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 QuickAsk/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        var text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        text = stripHTML(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxChars {
            text = String(text.prefix(maxChars)) + "\n…[truncated]"
        }
        return text.isEmpty ? "(empty page)" : text
    }

    private static func duckDuckGoSearch(_ query: String, limit: Int) async throws -> [WebSearchHit] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 QuickAsk/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://html.duckduckgo.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ChatClientError.httpStatus(http.statusCode, "DuckDuckGo search failed")
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        return parseDuckDuckGoHTML(html, limit: limit)
    }

    private static func parseDuckDuckGoHTML(_ html: String, limit: Int) -> [WebSearchHit] {
        // result__a href + text; result__snippet
        let linkPattern = #"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"class="result__snippet"[^>]*>(.*?)</(?:a|td|div)>"#

        guard let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: [.dotMatchesLineSeparators]),
              let snipRegex = try? NSRegularExpression(pattern: snippetPattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }

        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        let linkMatches = linkRegex.matches(in: html, range: full)
        let snipMatches = snipRegex.matches(in: html, range: full)

        var hits: [WebSearchHit] = []
        for (i, match) in linkMatches.prefix(limit).enumerated() {
            guard match.numberOfRanges >= 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }

            var href = String(html[hrefRange])
            href = decodeDDGRedirect(href) ?? href
            let title = stripHTML(String(html[titleRange]))
            var snippet = ""
            if i < snipMatches.count, snipMatches[i].numberOfRanges >= 2,
               let sRange = Range(snipMatches[i].range(at: 1), in: html) {
                snippet = stripHTML(String(html[sRange]))
            }
            if title.isEmpty { continue }
            hits.append(WebSearchHit(title: title, url: href, snippet: snippet))
        }
        return hits
    }

    /// DuckDuckGo wraps outbound links as //duckduckgo.com/l/?uddg=...
    private static func decodeDDGRedirect(_ href: String) -> String? {
        var absolute = href
        if absolute.hasPrefix("//") {
            absolute = "https:" + absolute
        }
        guard let url = URL(string: absolute),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let uddg = items.first(where: { $0.name == "uddg" })?.value,
              let decoded = uddg.removingPercentEncoding else {
            return absolute.hasPrefix("http") ? absolute : nil
        }
        return decoded
    }

    private static func stripHTML(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#x27;", with: "'")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

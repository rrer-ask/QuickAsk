import Foundation

/// Builds search queries and gathers live facts so the model doesn't refuse or invent.
enum LiveContext {
    struct Bundle: Sendable {
        let searchQuery: String
        let text: String
    }

    static func gather(messages: [ChatMessage]) async -> Bundle {
        let searchQuery = expandedSearchQuery(from: messages)
        var sections: [String] = []
        sections.append("Search query used: \(searchQuery)")

        async let searchTask: String = {
            do { return try await WebTools.search(searchQuery, limit: 5) }
            catch { return "(web search failed: \(error.localizedDescription))" }
        }()

        async let weatherTask: String? = weatherBlock(for: messages, searchQuery: searchQuery)
        async let wikiTask: String? = wikipediaBlock(for: searchQuery)

        let search = await searchTask
        sections.append("--- WEB SEARCH ---\n\(search)")

        if let weather = await weatherTask {
            sections.append("--- LIVE WEATHER (wttr.in) ---\n\(weather)\nUse these numbers for weather answers.")
        }
        if let wiki = await wikiTask {
            sections.append("--- WIKIPEDIA ---\n\(wiki)")
        }

        // If search returned weak/empty hits, try an English weather/news phrasing once.
        if search.contains("No results") || searchHitsLookWeak(search) {
            let alt = englishFallbackQuery(searchQuery)
            if alt != searchQuery {
                if let altText = try? await WebTools.search(alt, limit: 4), !altText.contains("No results") {
                    sections.append("--- WEB SEARCH (EN) ---\n\(altText)")
                }
            }
        }

        return Bundle(searchQuery: searchQuery, text: sections.joined(separator: "\n\n"))
    }

    // MARK: Query expansion

    static func expandedSearchQuery(from messages: [ChatMessage]) -> String {
        let users = messages.compactMap { $0.role == "user" ? $0.content?.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            .filter { !$0.isEmpty }
        guard let last = users.last else { return "" }
        if users.count == 1 { return last }

        let prior = users.dropLast().suffix(2)
        let priorText = prior.joined(separator: " ")

        // "а в казани?" after weather → "погода Казань сейчас"
        if let place = followUpPlace(last), isWeatherRelated(priorText) || isWeatherRelated(last) {
            return "погода \(place) сейчас"
        }

        // Short follow-ups inherit previous topic
        if isShortFollowUp(last) {
            return "\(priorText) \(last)"
        }
        return last
    }

    private static func isShortFollowUp(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 40 { return true }
        let lower = t.lowercased()
        let starters = ["а ", "и ", "а что", "а как", "а где", "а в", "а на", "and ", "what about", "how about"]
        return starters.contains { lower.hasPrefix($0) }
    }

    private static func isWeatherRelated(_ text: String) -> Bool {
        let l = text.lowercased()
        let keys = ["погод", "температур", "градус", "осадк", "дожд", "снег", "влажност",
                    "weather", "forecast", "temperature", "humidity", "°c", "°f"]
        return keys.contains { l.contains($0) }
    }

    /// "а в казани?", "а на бали?", "what about Paris?"
    private static func followUpPlace(_ text: String) -> String? {
        let patterns = [
            #"(?i)^а\s+(?:в|во|на)\s+(.+?)(?:\?|$)"#,
            #"(?i)^(?:and|what about|how about)\s+(.+?)(?:\?|$)"#,
            #"(?i)^(?:in|at)\s+(.+?)(?:\?|$)"#
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: text) else { continue }
            var place = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            place = place.trimmingCharacters(in: CharacterSet(charactersIn: "?!.…"))
            if place.count >= 2 { return place }
        }
        return nil
    }

    private static func englishFallbackQuery(_ q: String) -> String {
        var s = q
        let map = [
            "погода": "weather", "сейчас": "now", "температура": "temperature",
            "в ": "in ", "сегодня": "today", "завтра": "tomorrow"
        ]
        for (ru, en) in map {
            s = s.replacingOccurrences(of: ru, with: en, options: .caseInsensitive)
        }
        return s
    }

    private static func searchHitsLookWeak(_ text: String) -> Bool {
        let l = text.lowercased()
        // Typical junk when query was a short follow-up without topic
        let junk = ["аэропорт", "airport", "как правильно", "википедия — портал"]
        let hasWeather = l.contains("погод") || l.contains("weather") || l.contains("°") || l.contains("temp")
        if hasWeather { return false }
        return junk.contains { l.contains($0) }
    }

    // MARK: Weather

    private static func weatherBlock(for messages: [ChatMessage], searchQuery: String) async -> String? {
        let blob = (messages.compactMap(\.content) + [searchQuery]).joined(separator: "\n")
        guard isWeatherRelated(blob) else { return nil }

        let place = weatherPlace(from: searchQuery)
            ?? messages.reversed().compactMap { $0.role == "user" ? followUpPlace($0.content ?? "") : nil }.first
            ?? weatherPlace(from: blob)
            ?? "Moscow"

        return await fetchWttr(place: place)
    }

    private static func weatherPlace(from text: String) -> String? {
        let patterns = [
            #"(?i)(?:погод[аеуы]?|weather|температур[аыеу]?|forecast)\s+(?:в|во|на|in|for)\s+([A-Za-zА-Яа-яЁё\-]{2,}(?:\s+[A-Za-zА-Яа-яЁё\-]{2,})?)"#,
            #"(?i)(?:в|во|in|for)\s+([A-Za-zА-Яа-яЁё\-]{2,}(?:\s+[A-Za-zА-Яа-яЁё\-]{2,})?)\s*(?:сейчас|now|сегодня|today)?\s*[?]?\s*$"#
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: text) else { continue }
            let place = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if place.count >= 2 { return place }
        }
        return nil
    }

    private static func fetchWttr(place: String) async -> String? {
        let encoded = place.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? place
        guard let url = URL(string: "https://wttr.in/\(encoded)?format=j1") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("QuickAsk/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return await fetchWttrPlain(encoded)
            }
            if let summarized = summarizeWttr(data, place: place) {
                return summarized
            }
            return await fetchWttrPlain(encoded)
        } catch {
            return await fetchWttrPlain(encoded)
        }
    }

    private static func fetchWttrPlain(_ encodedPlace: String) async -> String? {
        guard let url = URL(string: "https://wttr.in/\(encodedPlace)?format=%l:+%c+%t+(feels+%f)+humidity+%h+wind+%w") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("QuickAsk/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func summarizeWttr(_ data: Data, place: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = (json["current_condition"] as? [[String: Any]])?.first else { return nil }
        let area = ((json["nearest_area"] as? [[String: Any]])?.first?["areaName"] as? [[String: Any]])?.first?["value"] as? String
        let temp = current["temp_C"] as? String
        let feels = current["FeelsLikeC"] as? String
        let humidity = current["humidity"] as? String
        let wind = current["windspeedKmph"] as? String
        let desc = ((current["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String)
        let obs = current["localObsDateTime"] as? String
        var lines = ["Requested: \(place)"]
        if let area { lines.append("Location: \(area)") }
        if let temp { lines.append("Temperature: \(temp)°C (feels like \(feels ?? temp)°C)") }
        if let desc { lines.append("Conditions: \(desc)") }
        if let humidity { lines.append("Humidity: \(humidity)%") }
        if let wind { lines.append("Wind: \(wind) km/h") }
        if let obs { lines.append("Observed: \(obs)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Wikipedia

    private static func wikipediaBlock(for query: String) async -> String? {
        // Skip pure weather queries — wttr is enough.
        if isWeatherRelated(query), followUpPlace(query) == nil,
           query.lowercased().contains("погод") || query.lowercased().contains("weather") {
            return nil
        }
        let term = query
            .replacingOccurrences(of: #"\?$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2, term.count <= 80 else { return nil }

        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        // Prefer Russian wiki for Cyrillic queries
        let lang = term.unicodeScalars.contains(where: { CharacterSet(charactersIn: "АаБбВвГгДдЕеЁёЖжЗзИиЙйКкЛлМмНнОоПпРрСсТтУуФфХхЦцЧчШшЩщЪъЫыЬьЭэЮюЯя").contains($0) }) ? "ru" : "en"
        guard let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(encoded)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("QuickAsk/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extract = json["extract"] as? String, !extract.isEmpty else { return nil }
        let title = json["title"] as? String ?? term
        return "\(title): \(extract)"
    }
}

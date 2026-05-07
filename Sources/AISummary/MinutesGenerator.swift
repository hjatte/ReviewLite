import Foundation

enum MinutesError: LocalizedError {
    case noAPIKey
    case noTranscript
    case requestFailed(status: Int, body: String)
    case decodingFailed(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key set in Settings."
        case .noTranscript: return "This meeting has no transcript yet."
        case .requestFailed(let s, let b): return "API request failed (\(s)): \(b.prefix(200))"
        case .decodingFailed(let m): return "Could not decode response: \(m)"
        case .other(let m): return m
        }
    }
}

/// Generates structured meeting minutes from a transcript using either Anthropic or OpenAI.
/// Reads the API key from Keychain. Returns Markdown with these sections (each omitted if empty):
///   # Summary, # Key Points, # Decisions / Conclusions, # Action Items, # Open Questions
enum MinutesGenerator {

    static let prompt: String = """
    You are summarising a recorded conversation. The transcript may be noisy, fragmented, or \
    contain speech-to-text errors — that's expected, treat misheard words charitably and infer \
    intent from context. Always produce minutes; if the content is sparse, write shorter \
    sections, but do not refuse and do not ask for a "cleaner transcript".

    Format the output as Markdown with these sections in this order. Omit any section that has \
    no content — do not write "None" or "Not applicable" or leave empty headers.

    # Summary
    A 2-3 sentence overview of what was discussed. Even if the transcript is brief or rough, \
    write a useful summary of the gist.

    # Key Points
    A bullet list of the main topics, themes, or facts discussed.

    # Decisions / Conclusions
    A bullet list of decisions made or conclusions reached, where applicable.

    # Action Items
    A bullet list. If an owner was named, format as "- **[Owner]** Action description". Otherwise \
    "- Action description". Be specific about what is to be done.

    # Open Questions
    A bullet list of unresolved questions or follow-ups.

    Rules:
    - Don't invent attendees, decisions, or action items that aren't supported by the transcript.
    - If the transcript is short, fragmented, or unclear, summarise what you can — phrasing like \
      "The conversation briefly touched on X" or "The speaker mentioned Y" is fine.
    - Never refuse. Never ask for clarification. Never request a corrected transcript. Always \
      output the Markdown sections that have content.
    - Plain factual language; no marketing, filler, or apologies for transcript quality.
    """

    static func generate(transcript: String, using provider: AIProvider) async throws -> String {
        guard let key = KeychainStore.get(provider.keychainKey), !key.isEmpty else {
            throw MinutesError.noAPIKey
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MinutesError.noTranscript }

        switch provider {
        case .anthropic: return try await generateAnthropic(transcript: trimmed, apiKey: key)
        case .openai:    return try await generateOpenAI(transcript: trimmed, apiKey: key)
        }
    }

    // MARK: - Anthropic

    private static func generateAnthropic(transcript: String, apiKey: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": AIProvider.anthropic.defaultModel,
            "max_tokens": 1500,
            "system": prompt,
            "messages": [
                ["role": "user", "content": "Transcript:\n\n\(transcript)"]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MinutesError.other("No HTTP response")
        }
        if http.statusCode >= 400 {
            throw MinutesError.requestFailed(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw MinutesError.decodingFailed("missing content[]")
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw MinutesError.decodingFailed("empty content text") }
        return text
    }

    // MARK: - OpenAI

    private static func generateOpenAI(transcript: String, apiKey: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": AIProvider.openai.defaultModel,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": "Transcript:\n\n\(transcript)"]
            ],
            "temperature": 0.2
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MinutesError.other("No HTTP response")
        }
        if http.statusCode >= 400 {
            throw MinutesError.requestFailed(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else {
            throw MinutesError.decodingFailed("missing choices[0].message.content")
        }
        return content
    }
}

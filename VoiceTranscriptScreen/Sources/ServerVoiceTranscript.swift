import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
import AccountContext
import NaturalLanguage

/// The words of a transcript that has no times of its own, given times that fill the voice message: shared out by the length
/// of each word, with a short pause after every sentence. The text is real, the timing is an approximation.
func approximateVoiceTranscript(text: String, duration: Double) -> VoiceTranscript {
    let rawWords = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if rawWords.isEmpty {
        return VoiceTranscript(segments: [])
    }
    
    // Speech fills the voice message, leaving a short silence at both ends.
    let margin = min(0.3, duration * 0.05)
    let speechStart = margin
    let speechEnd = max(speechStart + 0.5, duration - margin)
    
    let sentenceEnd: Set<Character> = [".", "!", "?", "…"]
    let pauseWeight = 3.0
    var weights: [Double] = []
    var pauses: [Double] = []
    for (index, word) in rawWords.enumerated() {
        weights.append(Double(max(word.count, 2)))
        let endsSentence = word.last.map { sentenceEnd.contains($0) } ?? false
        pauses.append(endsSentence && index != rawWords.count - 1 ? pauseWeight : 0.0)
    }
    let totalWeight = weights.reduce(0.0, +) + pauses.reduce(0.0, +)
    let secondsPerWeight = (speechEnd - speechStart) / max(1.0, totalWeight)
    
    var words: [VoiceTranscriptWord] = []
    var position = speechStart
    for (index, word) in rawWords.enumerated() {
        let end = position + weights[index] * secondsPerWeight
        words.append(VoiceTranscriptWord(text: word, start: position, end: end))
        position = end + pauses[index] * secondsPerWeight
    }
    return VoiceTranscript(segments: voiceTranscriptSegments(words: words))
}

/// The real transcript: the text Telegram makes of the voice message (the same one the transcribe button of a voice message in
/// the chat shows), cut into lines, with times that are only approximate: the server sends no times for words.
///
/// The text is taken from the message when it is already there. Otherwise it is asked for, and the transcript waits until the
/// whole of it has arrived. This provider only reports "unavailable" when the server refuses (not Premium and out of trials, a
/// voice message that is too long, an error), or when it takes too long.
public final class ServerVoiceTranscriptProvider: VoiceTranscriptProvider {
    private let summaryProvider = MockVoiceTranscriptProvider()
    
    public init() {
    }
    
    public func summary() -> VoiceSummary {
        return self.summaryProvider.summary()
    }
    
    public func summary(context: AccountContext, messageId: EngineMessage.Id, transcript: VoiceTranscript) -> Signal<VoiceSummaryState, NoError> {
        if voiceSummaryUsesAI {
            return self.makeSummary(context: context, messageId: messageId, transcript: transcript)
        } else {
            return self.makeFixedSummary(messageId: messageId, transcript: transcript)
        }
    }
    
    public func transcript(context: AccountContext, messageId: EngineMessage.Id, duration: Double) -> Signal<VoiceTranscriptState, NoError> {
        return Signal { subscriber in
            subscriber.putNext(.loading)
            
            var isFinished = false
            let finish: (VoiceTranscriptState) -> Void = { state in
                if isFinished {
                    return
                }
                isFinished = true
                subscriber.putNext(state)
                subscriber.putCompletion()
            }
            
            let requestDisposable = MetaDisposable()
            var didRequest = false
            let messageDisposable = (context.engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
            |> deliverOnMainQueue).start(next: { message in
                guard let message else {
                    finish(.unavailable)
                    return
                }
                let attribute = message._asMessage().attributes.first(where: { $0 is AudioTranscriptionMessageAttribute }) as? AudioTranscriptionMessageAttribute
                if let attribute {
                    if attribute.error != nil {
                        finish(.unavailable)
                        return
                    }
                    if attribute.isPending {
                        // Still being made: the final text arrives as an update of this same attribute.
                        return
                    }
                    let text = attribute.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        finish(.unavailable)
                    } else {
                        finish(.ready(approximateVoiceTranscript(text: text, duration: duration)))
                    }
                    return
                }
                
                if !didRequest {
                    didRequest = true
                    requestDisposable.set((context.engine.messages.transcribeAudio(messageId: messageId)
                    |> deliverOnMainQueue).start(next: { result in
                        // On success the text arrives through the message above.
                        if case .error = result {
                            finish(.unavailable)
                        }
                    }))
                }
            })
            
            // A voice message that never gets its text must not leave the sheet on the skeleton forever.
            let timer = SwiftSignalKit.Timer(timeout: 90.0, repeat: false, completion: {
                finish(.unavailable)
            }, queue: Queue.mainQueue())
            timer.start()
            
            return ActionDisposable {
                messageDisposable.dispose()
                requestDisposable.dispose()
                timer.invalidate()
            }
        }
    }
}

// MARK: - Summary

/// Whether the summary is asked of Telegram's AI. The request is made the way the app's own "compose with AI" does it
/// (`generate`, with the whole instruction and the text in the prompt). When every try fails the tab shows the placeholder
/// summary. See docs/voice-transcript-sheet.md.
// A variable, not a constant, so that the compiler does not flag the branch it switches off as unreachable.
private var voiceSummaryUsesAI = true

/// When the AI gives nothing, show the placeholder summary instead of "not available".
private let voiceSummaryFallsBackToPlaceholder = true

/// How long the skeleton of the summary stays the first time a voice message is opened, when the summary is placeholder text.
private let voiceSummaryFixedDelay = 2.0

/// A prompt of our own is limited in length: the app's own prompt field takes 1000 characters, and a longer prompt is refused
/// by the server (`AICOMPOSE_TONE_INVALID`). The instruction and the text of a request together stay under this many
/// characters, so a long transcript is summarised in parts and the parts are put together.
private let voiceSummaryPromptLimit = 900

/// The most parts a transcript is cut into; a longer one is thinned out, with the parts spread over the whole message.
private let voiceSummaryMaxParts = 6

/// The language the transcript is in, by its English name ("Ukrainian"), or nil when it cannot be told. A model that is only
/// told "the language of the text" answers in English all the same, so the language is named.
private func voiceSummaryLanguageName(of text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let language = recognizer.dominantLanguage, language != .undetermined else {
        return nil
    }
    return Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue)
}

/// The instruction, in the line format that is easy to read back. The answer is read line by line, so a model that adds a
/// sentence of its own, or decorates the lines with bullets and bold, does no harm. The labels stay in English whatever the
/// language of the text is: they are what the answer is read by. It is short on purpose (see `voiceSummaryPromptLimit`).
private func voiceSummaryInstruction(languageName: String?, maxItems: Int) -> String {
    let language = languageName ?? "the language of the transcript"
    return "Summarize this voice message transcript in \(language). Reply with lines only: SUMMARY: one short sentence of at most 20 words. KEY: m:ss | key point (one point per line). TASK: a short task. QUESTION: m:ss | a question. At most \(maxItems) of each, skip a kind if empty. Keep the labels in English."
}

/// `limit` items spread evenly over the list (the first and the last included), or the whole list when it is short.
private func voiceSummarySpread<T>(_ items: [T], limit: Int) -> [T] {
    if items.count <= limit || limit < 2 {
        return items.count <= limit ? items : Array(items.prefix(limit))
    }
    return (0 ..< limit).map { index in
        return items[Int((Double(index) * Double(items.count - 1) / Double(limit - 1)).rounded())]
    }
}

/// The prompts to ask, one for each part of the transcript, each under the limit and each with the instruction in front.
private func voiceSummaryPrompts(lines: [String], languageName: String?) -> [String] {
    let instruction = voiceSummaryInstruction(languageName: languageName, maxItems: 3) + "\n\nTranscript:\n"
    let budget = max(200, voiceSummaryPromptLimit - instruction.count)
    var chunks: [String] = []
    var current = ""
    for line in lines {
        let text = line.count > budget ? String(line.prefix(budget)) : line
        if !current.isEmpty && current.count + 1 + text.count > budget {
            chunks.append(current)
            current = text
        } else {
            current = current.isEmpty ? text : current + "\n" + text
        }
    }
    if !current.isEmpty {
        chunks.append(current)
    }
    return voiceSummarySpread(chunks, limit: voiceSummaryMaxParts).map { instruction + $0 }
}

/// One request to the AI: the text of the answer, or nil. A request the server refused is tried once more after a second, because
/// the same request sometimes goes through.
private func voiceSummaryGenerate(context: AccountContext, prompt: String) -> Signal<String?, NoError> {
    func attempt(_ remaining: Int) -> Signal<String?, NoError> {
        return context.engine.messages.composeAIMessage(text: .empty, mode: .generate(prompt: prompt))
        |> map { result -> String? in
            let text = voiceSummaryAnswerText(result.text).trimmingCharacters(in: .whitespacesAndNewlines)
            #if DEBUG
            print("[VoiceSummary] answer of \(text.count) characters to a prompt of \(prompt.count):\n\(text)")
            #endif
            return text.isEmpty ? nil : text
        }
        |> `catch` { error -> Signal<String?, NoError> in
            #if DEBUG
            print("[VoiceSummary] a request of \(prompt.count) characters failed: \(error), the server said: \(telegramAIComposeLastErrorDescription ?? "nothing")")
            voiceSummaryDebugReason = (voiceSummaryDebugReason.map { $0 + "\n" } ?? "") + "\(error): \(telegramAIComposeLastErrorDescription ?? "nothing")"
            #endif
            if case .generic = error, remaining > 0 {
                return Signal<Void, NoError>.single(Void())
                |> delay(1.0, queue: Queue.mainQueue())
                |> mapToSignal { _ -> Signal<String?, NoError> in
                    return attempt(remaining - 1)
                }
            }
            return .single(nil)
        }
    }
    return attempt(1)
}

/// What the AI answered, as a summary: read by its labels, or, when it did not keep to the format, the text itself as the headline.
private func voiceSummaryFromAnswer(_ text: String) -> VoiceSummary {
    if let summary = parseVoiceSummary(text) {
        return summary
    }
    let firstLine = text.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? text
    return VoiceSummary(headline: firstLine.trimmingCharacters(in: .whitespacesAndNewlines), keyPoints: [], tasks: [], questions: [])
}

/// The summaries of the parts of a transcript, put together into one: the key points in the order they are said (thinned out
/// when there are many), the tasks and questions without repeats, and one headline for all of it.
private func voiceSummaryCombined(context: AccountContext, summaries: [VoiceSummary], languageName: String?) -> Signal<VoiceSummary, NoError> {
    var keyPoints: [VoiceSummary.KeyPoint] = []
    var tasks: [VoiceSummary.Task] = []
    var questions: [VoiceSummary.Question] = []
    for summary in summaries {
        for point in summary.keyPoints where !keyPoints.contains(where: { $0.text.lowercased() == point.text.lowercased() }) {
            keyPoints.append(point)
        }
        for task in summary.tasks where !tasks.contains(where: { $0.text.lowercased() == task.text.lowercased() }) {
            tasks.append(task)
        }
        for question in summary.questions where !questions.contains(where: { $0.text.lowercased() == question.text.lowercased() }) {
            questions.append(question)
        }
    }
    keyPoints.sort { $0.time < $1.time }
    let finalKeyPoints = voiceSummarySpread(keyPoints, limit: 5)
    let finalTasks = Array(tasks.prefix(5))
    let finalQuestions = Array(questions.prefix(3))
    let headlines = summaries.map { $0.headline }.filter { !$0.isEmpty }
    
    if headlines.count <= 1 {
        return .single(VoiceSummary(headline: headlines.first ?? "", keyPoints: finalKeyPoints, tasks: finalTasks, questions: finalQuestions))
    }
    
    // One headline for the whole message, from the headlines of the parts.
    let language = languageName ?? "the language of the notes"
    let prompt = String(("Write one short sentence in \(language) that sums up these notes about one voice message. Reply with: SUMMARY: the sentence.\n\n" + headlines.joined(separator: "\n")).prefix(voiceSummaryPromptLimit))
    return voiceSummaryGenerate(context: context, prompt: prompt)
    |> map { text -> VoiceSummary in
        var headline = headlines[0]
        if let text {
            headline = voiceSummaryFromAnswer(text).headline
            if headline.isEmpty {
                headline = headlines[0]
            }
        }
        return VoiceSummary(headline: headline, keyPoints: finalKeyPoints, tasks: finalTasks, questions: finalQuestions)
    }
}

/// The text of what the AI answered, whatever form it came in (a plain message, or a rich one made of blocks).
private func voiceSummaryAnswerText(_ message: ComposedRichMessage) -> String {
    switch message {
    case let .plain(text, _):
        return text
    case let .rich(instantPage):
        return voiceSummaryBlocksText(instantPage.blocks)
    case .empty:
        return ""
    }
}

private func voiceSummaryBlocksText(_ blocks: [InstantPageBlock]) -> String {
    var lines: [String] = []
    for block in blocks {
        switch block {
        case let .title(text), let .subtitle(text), let .header(text), let .subheader(text), let .paragraph(text), let .footer(text), let .kicker(text):
            lines.append(text.plainText)
        case let .heading(text, _):
            lines.append(text.plainText)
        case let .preformatted(text, _):
            lines.append(text.plainText)
        case let .list(items, _):
            for item in items {
                switch item {
                case let .text(text, _, _):
                    lines.append(text.plainText)
                case let .blocks(blocks, _, _):
                    lines.append(voiceSummaryBlocksText(blocks))
                case .unknown:
                    break
                }
            }
        case let .blockQuote(blocks, _, _):
            lines.append(voiceSummaryBlocksText(blocks))
        default:
            break
        }
    }
    return lines.filter { !$0.isEmpty }.joined(separator: "\n")
}

/// Summaries the AI made, kept for each voice message (in memory and on disk), so reopening the sheet does not ask again and
/// the same text is shown every time. Only real summaries are kept: a placeholder is never stored. Main thread only.
private final class VoiceSummaryCache {
    static let shared = VoiceSummaryCache()
    private var values: [EngineMessage.Id: VoiceSummary] = [:]
    /// The voice messages whose placeholder was already shown, so its skeleton is not shown a second time.
    private var placeholdersShown = Set<EngineMessage.Id>()
    
    private func key(_ id: EngineMessage.Id) -> String {
        return "voiceSummary_\(id.peerId.toInt64())_\(id.namespace)_\(id.id)"
    }
    
    func value(for id: EngineMessage.Id) -> VoiceSummary? {
        if let value = self.values[id] {
            return value
        }
        if let data = UserDefaults.standard.data(forKey: self.key(id)), let value = try? JSONDecoder().decode(VoiceSummary.self, from: data) {
            self.values[id] = value
            return value
        }
        return nil
    }
    
    func set(_ summary: VoiceSummary, for id: EngineMessage.Id) {
        self.values[id] = summary
        if let data = try? JSONEncoder().encode(summary) {
            UserDefaults.standard.set(data, forKey: self.key(id))
        }
    }
    
    func hasShownPlaceholder(for id: EngineMessage.Id) -> Bool {
        return self.placeholdersShown.contains(id)
    }
    
    func markPlaceholderShown(for id: EngineMessage.Id) {
        self.placeholdersShown.insert(id)
    }
}

/// "m:ss", "h:mm:ss", with or without brackets, in seconds.
private func voiceSummaryTime(_ text: String) -> Double? {
    let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]() \t"))
    let parts = cleaned.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
    if parts.isEmpty || parts.contains(where: { $0 == nil }) {
        return nil
    }
    var seconds = 0
    for part in parts {
        seconds = seconds * 60 + (part ?? 0)
    }
    return Double(seconds)
}

/// The key points in one `KEY:` value that holds more than one point, each starting with its own time and a bar. Empty when
/// the value does not have that shape.
private func voiceSummaryKeyPoints(from value: String) -> [VoiceSummary.KeyPoint] {
    guard let regex = try? NSRegularExpression(pattern: "(\\d{1,2}(?::\\d{2}){1,2})\\s*\\|") else {
        return []
    }
    let string = value as NSString
    let matches = regex.matches(in: value, range: NSRange(location: 0, length: string.length))
    if matches.count < 2 {
        return []
    }
    var result: [VoiceSummary.KeyPoint] = []
    for (index, match) in matches.enumerated() {
        let time = voiceSummaryTime(string.substring(with: match.range(at: 1))) ?? 0.0
        let start = match.range.location + match.range.length
        let end = index + 1 < matches.count ? matches[index + 1].range.location : string.length
        let text = string.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            result.append(VoiceSummary.KeyPoint(time: time, text: text))
        }
    }
    return result
}

/// Reads the answer of the model. Returns nil when it holds nothing usable.
func parseVoiceSummary(_ text: String) -> VoiceSummary? {
    var headline = ""
    var keyPoints: [VoiceSummary.KeyPoint] = []
    var tasks: [VoiceSummary.Task] = []
    var questions: [VoiceSummary.Question] = []
    
    // A model sometimes puts several items on one line; each label starts an item of its own.
    let separated = text.replacingOccurrences(of: "\\s+(?=(?:SUMMARY|KEY|TASK|QUESTION):)", with: "\n", options: .regularExpression)
    for rawLine in separated.components(separatedBy: .newlines) {
        var line = rawLine.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = line.first, "-*•–".contains(first) {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        
        func value(after prefix: String) -> String? {
            guard line.uppercased().hasPrefix(prefix) else {
                return nil
            }
            let result = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        }
        
        if let value = value(after: "SUMMARY:") {
            headline = value
        } else if let value = value(after: "KEY:") {
            // "m:ss | the point"; without a time the point points at the start. A model sometimes runs several points
            // together on one line ("0:41 | a. 0:47 | b."), which are told apart by their times.
            let points = voiceSummaryKeyPoints(from: value)
            if points.count > 1 {
                keyPoints.append(contentsOf: points)
            } else if let separator = value.firstIndex(of: "|") {
                let time = voiceSummaryTime(String(value[value.startIndex ..< separator])) ?? 0.0
                let point = String(value[value.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !point.isEmpty {
                    keyPoints.append(VoiceSummary.KeyPoint(time: time, text: point))
                }
            } else {
                keyPoints.append(VoiceSummary.KeyPoint(time: 0.0, text: value))
            }
        } else if let value = value(after: "TASK:") {
            tasks.append(VoiceSummary.Task(text: value, isCompleted: false))
        } else if let value = value(after: "QUESTION:") {
            // "m:ss | the question"; without a time the question points at the start.
            if let separator = value.firstIndex(of: "|"), let time = voiceSummaryTime(String(value[value.startIndex ..< separator])) {
                let text = String(value[value.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    questions.append(VoiceSummary.Question(time: time, text: text))
                }
            } else {
                questions.append(VoiceSummary.Question(time: 0.0, text: value))
            }
        }
    }
    
    if headline.isEmpty && keyPoints.isEmpty && tasks.isEmpty && questions.isEmpty {
        return nil
    }
    return VoiceSummary(headline: headline, keyPoints: keyPoints, tasks: tasks, questions: questions)
}

extension ServerVoiceTranscriptProvider {
    private func summarySeed(messageId: EngineMessage.Id) -> UInt64 {
        return UInt64(bitPattern: Int64(messageId.id)) &* 0x2545F4914F6CDD1D &+ UInt64(bitPattern: messageId.peerId.toInt64())
    }
    
    /// The placeholder summary, as if it were being made: the skeleton for two seconds the first time this voice message is
    /// opened, the summary at once afterwards.
    func makeFixedSummary(messageId: EngineMessage.Id, transcript: VoiceTranscript) -> Signal<VoiceSummaryState, NoError> {
        let summary = voiceRandomSummary(seed: self.summarySeed(messageId: messageId), transcript: transcript)
        if VoiceSummaryCache.shared.hasShownPlaceholder(for: messageId) {
            return .single(.ready(summary))
        }
        return Signal<VoiceSummaryState, NoError>.single(.loading)
        |> then(
            Signal<VoiceSummaryState, NoError>.single(.ready(summary))
            |> delay(voiceSummaryFixedDelay, queue: Queue.mainQueue())
            |> afterNext { _ in
                VoiceSummaryCache.shared.markPlaceholderShown(for: messageId)
            }
        )
    }
    
    func makeSummary(context: AccountContext, messageId: EngineMessage.Id, transcript: VoiceTranscript) -> Signal<VoiceSummaryState, NoError> {
        if let cached = VoiceSummaryCache.shared.value(for: messageId) {
            return .single(.ready(cached))
        }
        // The lines of the transcript the screen shows, with the time of each in front of it. The times the model answers with
        // are therefore the ones the lines carry, and a tap on one seeks to the line.
        let lines = transcript.segments.filter { !$0.text.isEmpty }.map { segment in
            return "[" + formatVoiceTranscriptTime(segment.start) + "] " + segment.text
        }
        if lines.isEmpty {
            #if DEBUG
            voiceSummaryDebugReason = "the transcript has no text"
            #endif
            return .single(.unavailable)
        }
        #if DEBUG
        voiceSummaryDebugReason = nil
        #endif
        
        let seed = self.summarySeed(messageId: messageId)
        let languageName = voiceSummaryLanguageName(of: lines.joined(separator: " "))
        let prompts = voiceSummaryPrompts(lines: lines, languageName: languageName)
        #if DEBUG
        print("[VoiceSummary] \(lines.count) lines of transcript in \(prompts.count) part(s), language: \(languageName ?? "unknown")")
        #endif
        
        // Every part is summarised on its own (each prompt stays under the limit), then the results are put together. Parts the
        // server refused are left out; the summary is made of the others.
        let partRequests: [Signal<VoiceSummary?, NoError>] = prompts.map { prompt in
            return voiceSummaryGenerate(context: context, prompt: prompt)
            |> map { text -> VoiceSummary? in
                return text.map { voiceSummaryFromAnswer($0) }
            }
        }
        
        // When no part gets through, the old way is tried once: the transcript as the text, the instruction as the tone.
        func rewriteFallback() -> Signal<VoiceSummaryState, NoError> {
            let input = lines.joined(separator: "\n")
            let instruction = voiceSummaryInstruction(languageName: languageName, maxItems: 4)
            return context.engine.messages.composeAIMessage(text: .plain(text: input, entities: []), mode: .stylize(emojify: false, style: .prompt(instruction)))
            |> map { result -> VoiceSummaryState in
                let text = voiceSummaryAnswerText(result.text).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    return .unavailable
                }
                return .ready(voiceSummaryFromAnswer(text))
            }
            |> `catch` { _ -> Signal<VoiceSummaryState, NoError> in
                return .single(.unavailable)
            }
        }
        
        let request: Signal<VoiceSummaryState, NoError> = combineLatest(partRequests)
        |> take(1)
        |> mapToSignal { results -> Signal<VoiceSummaryState, NoError> in
            let summaries = results.compactMap { $0 }
            if summaries.isEmpty {
                return rewriteFallback()
            }
            return voiceSummaryCombined(context: context, summaries: summaries, languageName: languageName)
            |> map { summary -> VoiceSummaryState in
                return .ready(summary)
            }
        }
        // A request that never answers must not leave the tab on its skeleton forever.
        |> timeout(90.0, queue: Queue.mainQueue(), alternate: Signal<VoiceSummaryState, NoError>.single(.unavailable) |> afterNext { _ in
            #if DEBUG
            print("[VoiceSummary] no answer in 90 seconds")
            voiceSummaryDebugReason = "no answer in 90 seconds"
            #endif
        })
        |> deliverOnMainQueue
        |> map { state -> VoiceSummaryState in
            if case let .ready(summary) = state {
                // Whatever the model left out is filled from the transcript, so the tab is never half empty.
                let completed = voiceCompletedSummary(summary, transcript: transcript, seed: seed)
                VoiceSummaryCache.shared.set(completed, for: messageId)
                return .ready(completed)
            }
            if voiceSummaryFallsBackToPlaceholder {
                return .ready(voiceRandomSummary(seed: seed, transcript: transcript))
            }
            return state
        }
        
        return Signal<VoiceSummaryState, NoError>.single(.loading)
        |> then(request)
    }
}

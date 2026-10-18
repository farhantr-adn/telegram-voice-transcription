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

/// Whether the summary is asked of Telegram's AI. The first version of the request (`stylize` with our own instruction) was
/// refused by the server with `AICOMPOSE_TONE_INVALID` on every try, so the tab fell back to placeholder text. The request is
/// now made the way the app's own "compose with AI" does it (`generate`, the whole instruction and the transcript in the
/// prompt), with the old way as a second try; when every try fails the tab shows the placeholder summary. See
/// docs/voice-transcript-sheet.md.
// A variable, not a constant, so that the compiler does not flag the branch it switches off as unreachable.
private var voiceSummaryUsesAI = true

/// When the AI gives nothing, show the placeholder summary instead of "not available".
private let voiceSummaryFallsBackToPlaceholder = true

/// How long the skeleton of the summary stays the first time a voice message is opened, when the summary is placeholder text.
private let voiceSummaryFixedDelay = 2.0

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
/// language of the text is: they are what the answer is read by.
private func voiceSummaryInstruction(languageName: String?) -> String {
    let language = languageName.map { "Write the text of every item in \($0), the language of the transcript" } ?? "Write the text of every item in the language of the transcript"
    return "Summarize the voice message transcript below. \(language), but keep the labels in English. Answer with one item per line, exactly in this format: SUMMARY: one short sentence. KEY: m:ss | key point (the time of the line it comes from). TASK: a task for the listener. QUESTION: a question to answer. At most 4 of each; skip a kind if there is nothing for it."
}

private enum VoiceSummaryRequestKind {
    /// The app's "compose with AI": the prompt is the whole request, the transcript included.
    case generate(String)
    /// The text is rewritten by an instruction of our own (what the first version of this screen did).
    case stylize(String)
}

/// What is tried, in order, until one of them answers. The server limits are not known (the app's own prompt field takes 1000
/// characters), so a shorter transcript is tried when the whole one is refused.
private func voiceSummaryRequests(input: String) -> [VoiceSummaryRequestKind] {
    var result: [VoiceSummaryRequestKind] = []
    let languageName = voiceSummaryLanguageName(of: input)
    let instruction = voiceSummaryInstruction(languageName: languageName)
    result.append(.generate(instruction + "\n\nTranscript:\n" + String(input.prefix(3000))))
    if input.count > 600 {
        result.append(.generate(instruction + "\n\nTranscript:\n" + String(input.prefix(600))))
    }
    result.append(.stylize(instruction))
    result.append(.stylize("Summarize in one or two short sentences" + (languageName.map { ", in \($0)." } ?? ", in the language of the text.")))
    return result
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

/// Summaries already made, so reopening the sheet does not ask again. Main thread only.
private final class VoiceSummaryCache {
    static let shared = VoiceSummaryCache()
    private var values: [EngineMessage.Id: VoiceSummary] = [:]
    
    func value(for id: EngineMessage.Id) -> VoiceSummary? {
        return self.values[id]
    }
    
    func set(_ summary: VoiceSummary, for id: EngineMessage.Id) {
        self.values[id] = summary
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

/// Reads the answer of the model. Returns nil when it holds nothing usable.
func parseVoiceSummary(_ text: String) -> VoiceSummary? {
    var headline = ""
    var keyPoints: [VoiceSummary.KeyPoint] = []
    var tasks: [VoiceSummary.Task] = []
    var questions: [String] = []
    
    for rawLine in text.components(separatedBy: .newlines) {
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
            // "m:ss | the point"; without a time the point points at the start.
            if let separator = value.firstIndex(of: "|") {
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
            questions.append(value)
        }
    }
    
    if headline.isEmpty && keyPoints.isEmpty && tasks.isEmpty && questions.isEmpty {
        return nil
    }
    return VoiceSummary(headline: headline, keyPoints: keyPoints, tasks: tasks, questions: questions)
}

extension ServerVoiceTranscriptProvider {
    /// The fixed summary, as if it were being made: the skeleton for two seconds the first time this voice message is opened,
    /// the summary at once afterwards.
    func makeFixedSummary(messageId: EngineMessage.Id, transcript: VoiceTranscript) -> Signal<VoiceSummaryState, NoError> {
        // Placeholder content picked at random for this voice message (the same one every time it is opened).
        let seed = UInt64(bitPattern: Int64(messageId.id)) &* 0x2545F4914F6CDD1D &+ UInt64(bitPattern: messageId.peerId.toInt64())
        let summary = VoiceSummaryCache.shared.value(for: messageId) ?? voiceRandomSummary(seed: seed, transcript: transcript)
        if VoiceSummaryCache.shared.value(for: messageId) != nil {
            return .single(.ready(summary))
        }
        return Signal<VoiceSummaryState, NoError>.single(.loading)
        |> then(
            Signal<VoiceSummaryState, NoError>.single(.ready(summary))
            |> delay(voiceSummaryFixedDelay, queue: Queue.mainQueue())
            |> afterNext { _ in
                VoiceSummaryCache.shared.set(summary, for: messageId)
            }
        )
    }
    
    func makeSummary(context: AccountContext, messageId: EngineMessage.Id, transcript: VoiceTranscript) -> Signal<VoiceSummaryState, NoError> {
        if let cached = VoiceSummaryCache.shared.value(for: messageId) {
            return .single(.ready(cached))
        }
        // The transcript the screen shows, with the time of each line in front of it, is what the model reads. The times it
        // answers with are therefore the ones the lines carry, and a tap on one seeks to the line.
        let input = transcript.segments.map { segment in
            return "[" + formatVoiceTranscriptTime(segment.start) + "] " + segment.text
        }.joined(separator: "\n")
        if input.isEmpty {
            #if DEBUG
            voiceSummaryDebugReason = "the transcript has no text"
            #endif
            return .single(.unavailable)
        }
        #if DEBUG
        voiceSummaryDebugReason = nil
        print("[VoiceSummary] asking for a summary of \(input.count) characters of transcript")
        #endif
        
        let seed = UInt64(bitPattern: Int64(messageId.id)) &* 0x2545F4914F6CDD1D &+ UInt64(bitPattern: messageId.peerId.toInt64())
        let requests = voiceSummaryRequests(input: input)
        
        func ask(_ index: Int) -> Signal<VoiceSummaryState, NoError> {
            let signal: Signal<TelegramAIComposeMessageResult, TelegramAIComposeMessageError>
            switch requests[index] {
            case let .generate(prompt):
                signal = context.engine.messages.composeAIMessage(text: .empty, mode: .generate(prompt: prompt))
            case let .stylize(prompt):
                signal = context.engine.messages.composeAIMessage(text: .plain(text: input, entities: []), mode: .stylize(emojify: false, style: .prompt(prompt)))
            }
            
            // A refused or empty try goes on to the next one. Hitting the free limit is not a reason to try again.
            func next(_ reason: String, retry: Bool) -> Signal<VoiceSummaryState, NoError> {
                #if DEBUG
                print("[VoiceSummary] try \(index) gave nothing: \(reason)")
                voiceSummaryDebugReason = (voiceSummaryDebugReason.map { $0 + "\n" } ?? "") + "try \(index): \(reason)"
                #endif
                if retry && index + 1 < requests.count {
                    return ask(index + 1)
                }
                return .single(.unavailable)
            }
            
            return signal
            |> map { result -> VoiceSummaryState? in
                let text = voiceSummaryAnswerText(result.text).trimmingCharacters(in: .whitespacesAndNewlines)
                #if DEBUG
                print("[VoiceSummary] try \(index), answer of \(text.count) characters:\n\(text)")
                #endif
                if text.isEmpty {
                    return nil
                }
                if let summary = parseVoiceSummary(text) {
                    return .ready(summary)
                }
                // The model did not keep to the format: what it wrote is shown as the headline, rather than nothing.
                return .ready(VoiceSummary(headline: text, keyPoints: [], tasks: [], questions: []))
            }
            |> mapToSignal { state -> Signal<VoiceSummaryState, TelegramAIComposeMessageError> in
                if let state {
                    return .single(state)
                }
                return .fail(.generic)
            }
            |> `catch` { error -> Signal<VoiceSummaryState, NoError> in
                #if DEBUG
                let serverText = telegramAIComposeLastErrorDescription ?? "nothing"
                #else
                let serverText = ""
                #endif
                if case .nonPremiumFlood = error {
                    return next("free limit reached", retry: false)
                }
                return next("\(error), the server said: \(serverText)", retry: true)
            }
        }
        
        let request = ask(0)
        // A request that never answers must not leave the tab on its skeleton forever.
        |> timeout(60.0, queue: Queue.mainQueue(), alternate: Signal<VoiceSummaryState, NoError>.single(.unavailable) |> afterNext { _ in
            #if DEBUG
            print("[VoiceSummary] no answer in 60 seconds")
            voiceSummaryDebugReason = "no answer in 60 seconds"
            #endif
        })
        |> deliverOnMainQueue
        |> map { state -> VoiceSummaryState in
            switch state {
            case let .ready(summary):
                // Whatever the model left out is filled from the transcript, so the tab is never half empty.
                let completed = voiceCompletedSummary(summary, transcript: transcript, seed: seed)
                VoiceSummaryCache.shared.set(completed, for: messageId)
                return .ready(completed)
            default:
                if voiceSummaryFallsBackToPlaceholder {
                    let placeholder = voiceRandomSummary(seed: seed, transcript: transcript)
                    VoiceSummaryCache.shared.set(placeholder, for: messageId)
                    return .ready(placeholder)
                }
                return state
            }
        }
        
        return Signal<VoiceSummaryState, NoError>.single(.loading)
        |> then(request)
    }
}

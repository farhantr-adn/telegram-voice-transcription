import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import LocalAudioTranscription
import ConvertOpusToAAC

/// Turns recognised words into lines: a line ends after sentence punctuation, a pause, or when it gets long.
func voiceTranscriptSegments(words: [VoiceTranscriptWord]) -> [VoiceTranscriptSegment] {
    let maxWordsInLine = 14
    let pause = 0.7
    let sentenceEnd: Set<Character> = [".", "!", "?", "…"]
    
    var segments: [VoiceTranscriptSegment] = []
    var current: [VoiceTranscriptWord] = []
    for (index, word) in words.enumerated() {
        current.append(word)
        
        var endsLine = false
        if let last = word.text.last, sentenceEnd.contains(last) {
            endsLine = true
        }
        if current.count >= maxWordsInLine {
            endsLine = true
        }
        if index + 1 < words.count, words[index + 1].start - word.end > pause {
            endsLine = true
        }
        if endsLine {
            segments.append(VoiceTranscriptSegment(words: current))
            current = []
        }
    }
    if !current.isEmpty {
        segments.append(VoiceTranscriptSegment(words: current))
    }
    return segments
}

/// Recognised transcripts kept on disk, so a voice message is only recognised once.
private enum VoiceTranscriptCache {
    private struct Entry: Codable {
        var texts: [String]
        var starts: [Double]
        var ends: [Double]
    }
    
    private static var directory: String {
        let base = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        return base + "/voice-transcripts"
    }
    
    private static func path(key: String) -> String {
        return self.directory + "/" + key + ".json"
    }
    
    static func load(key: String) -> [VoiceTranscriptWord]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: self.path(key: key))), let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        if entry.texts.count != entry.starts.count || entry.texts.count != entry.ends.count || entry.texts.isEmpty {
            return nil
        }
        var words: [VoiceTranscriptWord] = []
        for i in 0 ..< entry.texts.count {
            words.append(VoiceTranscriptWord(text: entry.texts[i], start: entry.starts[i], end: entry.ends[i]))
        }
        return words
    }
    
    static func store(key: String, words: [VoiceTranscriptWord]) {
        let entry = Entry(texts: words.map(\.text), starts: words.map(\.start), ends: words.map(\.end))
        guard let data = try? JSONEncoder().encode(entry) else {
            return
        }
        let _ = try? FileManager.default.createDirectory(atPath: self.directory, withIntermediateDirectories: true)
        let _ = try? data.write(to: URL(fileURLWithPath: self.path(key: key)), options: .atomic)
    }
}

/// The real transcript: the voice message is recognised on the device and every word keeps the time it is spoken at.
public final class RecognizedVoiceTranscriptProvider: VoiceTranscriptProvider {
    private let summaryProvider = MockVoiceTranscriptProvider()
    
    public init() {
    }
    
    public func summary() -> VoiceSummary {
        return self.summaryProvider.summary()
    }
    
    public func transcript(context: AccountContext, messageId: EngineMessage.Id, duration: Double) -> Signal<VoiceTranscriptState, NoError> {
        let recognition = context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
        |> take(1)
        |> mapToSignal { message -> Signal<VoiceTranscriptState, NoError> in
            guard let message, let file = message.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile else {
                return .single(.unavailable)
            }
            let key = "\(file.fileId.namespace)_\(file.fileId.id)"
            if let cached = VoiceTranscriptCache.load(key: key) {
                return .single(.ready(VoiceTranscript(segments: voiceTranscriptSegments(words: cached))))
            }
            
            return context.engine.resources.data(id: EngineMediaResource.Id(file.resource.id))
            |> filter { data -> Bool in
                return data.isComplete
            }
            |> take(1)
            |> map { data -> String? in
                return data.path
            }
            // A voice message that never finishes downloading must not leave the sheet loading forever.
            |> timeout(30.0, queue: Queue.mainQueue(), alternate: .single(nil))
            |> mapToSignal { path -> Signal<String?, NoError> in
                guard let path else {
                    return .single(nil)
                }
                return convertOpusToAAC(sourcePath: path, allocateTempFile: {
                    return EngineTempBox.shared.tempFile(fileName: "audio.m4a").path
                })
            }
            |> mapToSignal { path -> Signal<[LocallyTimedWord]?, NoError> in
                guard let path else {
                    return .single(nil)
                }
                // The device language first; English as a second guess unless that already is the device language.
                let deviceLocale = Locale.current.identifier
                var locales: [String] = [deviceLocale]
                if Locale(identifier: deviceLocale).languageCode != "en" {
                    locales.append("en-US")
                }
                return transcribeAudioWithTimings(path: path, locales: locales)
            }
            |> map { timedWords -> VoiceTranscriptState in
                guard let timedWords else {
                    return .unavailable
                }
                let words = timedWords.compactMap { word -> VoiceTranscriptWord? in
                    let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        return nil
                    }
                    return VoiceTranscriptWord(text: text, start: word.start, end: max(word.end, word.start))
                }
                if words.isEmpty {
                    return .unavailable
                }
                VoiceTranscriptCache.store(key: key, words: words)
                return .ready(VoiceTranscript(segments: voiceTranscriptSegments(words: words)))
            }
        }
        
        return Signal<VoiceTranscriptState, NoError>.single(.loading)
        |> then(recognition)
    }
}

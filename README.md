# Voice Message Transcript and AI Summary

A redesigned way to work with voice messages in Telegram for iOS: a sheet where the audio and its text move together, with a summary of the key points on a second tab.

![The transcript sheet over a chat](screenshots/sheet-overview.png)

## Why

Long voice messages are hard to work with. A manager dictates a pile of tasks, a friend tells a story, a classmate sends a lecture. Often you need to do more than listen: find the one thing that matters, note down a thought, or answer something that was said.

That is where it gets inconvenient. You replay the message, scrub back and forth, and try to remember where the thing you need was mentioned. When you want to reply to one specific point, you have to explain which one.

Telegram already offers a transcription (for Premium users), and it helps. But the text alone is not enough: finding a phrase, jumping to that moment in the audio, or quoting what was said is still awkward. This project turns the transcription into a tool for working with a voice message, so it can be used like regular text instead of only being listened to from start to finish.

## What it does

Tap the playback panel at the top of a chat while a voice message plays. A sheet opens with two tabs: **Transcript** and **AI Summary**.

![The playback panel at the top of a chat](screenshots/playback-panel.png)

### Transcript

- **Text in sync with the audio.** The line being spoken is highlighted, and so is its current word. There is always exactly one active line. Pauses between words do not leave the text without an active word.
- **Tap to seek.** Tap a word (or the time of a line) and the audio jumps to that moment.

![The line and word being spoken are highlighted](screenshots/transcript-active.png)

- **Synchronize.** If you scroll away from the line being spoken while a message plays, a *Synchronize* button appears and takes you back to it. After a pause, pressing Play scrolls the text smoothly back to the active line.

![The Synchronize button over a scrolled text](screenshots/synchronize.png)

- **Selection.** Select text across several lines with handles on both ends. The menu offers **Quote**, **Copy** and **Translate**.

![A selection across lines with the Quote, Copy and Translate menu](screenshots/selection-menu.png)

- **Quote with a timestamp.** Select a phrase and reply to it. The reply field shows the chosen time and words (for example "0:42 — the deadline moved to Friday"), so you answer a specific moment instead of the whole message.

![The reply field with the quoted time and words](screenshots/reply-quote.png)

- **Search.** Look for a word or a phrase inside this one voice message. Every match is highlighted in the transcript.
- **Skeleton while loading.** A shimmering placeholder is shown until the whole text has arrived. (What if a little dinosaur kept you company while you wait?)

![The skeleton shown while the transcript is loading](screenshots/skeleton.png)

### Player

The bottom of the sheet is a full player:

- a waveform you can scrub,
- elapsed and remaining time,
- playback speed,
- 5 seconds back and forward,
- animated Play/Pause,
- a **⋯** menu: *Reply*, *Copy Transcript*, *Translate Transcript*, *Forward*, and *Next Voice* / *Previous Voice*,
- the time the message was sent.

![The player with the menu open](screenshots/player-menu.png)

### AI Summary

The key points, tasks and questions in one place:

- **Key points** with a time. Tap the time to jump to that moment in the Transcript tab and in the audio. Tap the text to open a menu with **Reply** and **Copy**.
- **Tasks** with checkboxes. Tap anywhere on a task to tick it. The card ends with a counter such as "1 of 3 completed", and a **Copy** button that copies the list with its ticks. The ticks are remembered for each voice message (by the text of the task), so they are still there when the sheet is opened again, also after the app is restarted.
- **Questions** with a time, like the key points. Tap the time to jump to the moment the question is asked. Tap the text to open the menu: **Reply** opens the chat with that question quoted in the reply field (with its time), **Copy** copies it.

![The AI Summary tab: key points, tasks and questions](screenshots/summary.png)

## Limitations

Please read these before trying it.

1. **The text is not tied to the audio by real timestamps.** Telegram's server returns only the *text* of a voice message: no times per word or per line. The times next to the lines and the highlighted word are **computed on the device**. Words get a share of the message's duration proportional to their length, a short pause is added after each sentence, and a small margin is left at the start and at the end. For speech at an even pace this follows closely enough to read along. It drifts when the speaker paused for long, spoke in bursts, or the message is long, and a tap on a word can land a second or two away. Do not read the highlighting as word-accurate. (An on-device speech recogniser, `RecognizedVoiceTranscriptProvider`, can measure real times, but it needs the language chosen in advance and is less accurate than the server's text, so it is not the default.)
2. **AI Summary depends on a server feature that may refuse the request.** The summary is asked of Telegram's AI through the same call the app's own "compose with AI" uses (`messages.composeRichMessageWithAI`, as `generate`), with the instruction and a piece of the transcript in each prompt. A prompt of our own has a length limit (the app's own prompt field takes 1000 characters, and the server refuses a longer one), so a longer transcript is cut into parts of up to about 900 characters, each part is summarised on its own, and the results are put together: key points in the order they are said, tasks and questions without repeats, and one headline made from the headlines of the parts. A request the server refuses is tried once more, and a part that still fails is left out. A real summary is kept for each voice message (also after the app is restarted), so reopening the sheet does not ask the AI again. The prompt names the language of the transcript (detected on the device), so the answer should come in that language; the labels the answer is read by (`SUMMARY:`, `KEY:`, `TASK:`, `QUESTION:`) stay in English. If every attempt fails, the tab shows **placeholder content** instead: each part (headline, key points, tasks, questions) is picked at random from small pools of English sample sentences, seeded by the message so a voice message keeps its summary when it is opened again, and about one task in four starts out ticked. The placeholder is not generated from what was said and is not translated; its key points point at real lines of the transcript, so a tap on one seeks somewhere that exists. When the AI answers but leaves out the key points, they are filled with a few real lines of the transcript at their own times. The whole behaviour is in `ServerVoiceTranscript.swift`: `voiceSummaryUsesAI` switches the AI off, and `voiceSummaryFallsBackToPlaceholder` turns the fallback to placeholder text on or off.
3. **The transcript needs Telegram's transcription.** That means Premium or one of the limited free trials. Without either, the sheet says the transcript is not available. Messages too long for the server are not transcribed.
4. **A quoted moment is shown only to you.** The time and words appear in your reply field; they are not sent. The recipient sees a plain reply to the voice message.

## How it works

| Piece | Where |
| --- | --- |
| The sheet (UI, gestures, selection, search, player) | `Sources/VoiceTranscriptScreen.swift` |
| Models and the provider protocol (`VoiceTranscriptProvider`) | `Sources/VoiceTranscriptData.swift` |
| Telegram's transcription plus the approximate timing (default provider) | `Sources/ServerVoiceTranscript.swift` |
| On-device Apple Speech provider (kept, not the default) | `Sources/VoiceTranscriptRecognition.swift` |

`VoiceTranscriptProvider` is the one place the sheet gets its content from; the default is set in the initialiser of `VoiceTranscriptScreen`. Providers: `ServerVoiceTranscriptProvider` (default), `RecognizedVoiceTranscriptProvider` (measured times, not default) and `RandomVoiceTranscriptProvider` (placeholder for demos).

## Changes outside the module

The sheet touches a few places in the app. These are small and are listed so you can apply them to your own checkout:

| File | Change |
| --- | --- |
| `submodules/TelegramUI/Components/MediaPlaybackHeaderPanelComponent/…` | Tapping the playback panel for a voice message opens the sheet |
| `submodules/AccountContext/Sources/AccountContext.swift` | `makeVoiceTranscriptScreen` |
| `submodules/TelegramUI/Sources/SharedAccountContext.swift` | Implements it |
| `submodules/AccountContext/Sources/VoiceReplyFragment.swift` | New: the time and words of a quoted moment |
| `submodules/ChatInterfaceState/…`, `ChatControllerLoadDisplayNode.swift`, `ChatInterfaceStateAccessoryPanels.swift`, `ChatInputMessageAccessoryPanel.swift` | The reply field shows the quoted moment as a chip |
| `submodules/AccountContext/Sources/ChatController.swift`, `submodules/TelegramUI/Sources/ChatController.swift` | `ChatController.setupReply(toMessageId:)`: Quote and Reply from the sheet set the reply up in the chat that is already open under the sheet, at once, instead of opening the chat again and scrolling to the message |
| `submodules/MediaPlayer/Sources/FFMpegMediaFrameSourceContext.swift` | A seek in an audio-only stream now skips the packets that end before the target. It used to land on the previous seek point, up to a second or more early for a voice message, and the highlight fell on the wrong word |
| `submodules/Media/LocalAudioTranscription/…` | Timed words for the on-device provider |
| `submodules/AccountContext/Sources/SharedMediaPlayer.swift`, `submodules/TelegramUI/Sources/SharedMediaPlayer.swift` | A `setSoundMuted` control action (not used by the current sheet) |
| `submodules/TelegramCore/…/Translate.swift` | Debug-only capture of the server's AI error text |
| `Telegram/Telegram-iOS/en.lproj/Localizable.strings` | 16 new strings with the `VoiceTranscript.` prefix. Other languages show the English text until they are translated |
| `submodules/AccountContext/Sources/AccountContext.swift`, `submodules/TelegramUI/Components/TextProcessingScreen/Sources/TextProcessingScreen.swift` | `TextProcessingScreenMode.translate` gets `displaysInfoButton` (default `true`); the sheet opens Translate without the information button |
| `submodules/TelegramUI/BUILD` | Adds the module as a dependency |

## Trying it

This is a change to the Telegram-iOS source tree, not a standalone app: copy the module and apply the changes above to a checkout of the app, then build it as you normally build the app. Open any chat with a voice message, play it, and tap the playback panel at the top.

A Premium account (or an available free trial) is needed to get a real transcript.

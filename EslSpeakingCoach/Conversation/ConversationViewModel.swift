import Foundation
import Observation
import UIKit

/// ConversationView の状態。VoiceSession のイベントを画面表示用に変換する。
/// セッションは開始のたびに新規作成する（TurnBasedVoiceSession は使い捨て）。
@MainActor
@Observable
final class ConversationViewModel {
    enum DisplayItem: Identifiable {
        case message(ConversationMessage)
        case notice(id: UUID, text: String)
        case metrics(id: UUID, TurnMetrics)

        var id: UUID {
            switch self {
            case .message(let message): return message.id
            case .notice(let id, _): return id
            case .metrics(let id, _): return id
            }
        }
    }

    private(set) var items: [DisplayItem] = []
    private(set) var state: VoiceSessionState = .idle
    private(set) var partialTranscript = ""
    private(set) var micLevel: Float = 0
    /// 受信したレベルイベント数（マイクからバッファが流れているかの診断用）
    private(set) var micLevelEventCount = 0
    private(set) var errorMessage: String?
    /// TTS プロバイダ（採用は Gemini TTS。聞き比べ用に切替可・停止中のみ変更可）
    var ttsProvider: TTSProvider = {
        #if DEBUG
        return DebugLaunchArguments.ttsProviderOverride ?? .gemini
        #else
        return .gemini
        #endif
    }()

    private var session: (any VoiceSession)?
    private var eventTask: Task<Void, Never>?
    private var streamingAssistantID: UUID?
    #if DEBUG
    private var pendingAutoText = DebugLaunchArguments.autoSendText
    #endif

    var isRunning: Bool { session != nil }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard session == nil else { return }
        errorMessage = nil
        items = []
        let keychain = KeychainStore()
        var configuration = TurnBasedVoiceSession.Configuration()
        configuration.ttsProvider = ttsProvider
        let newSession = TurnBasedVoiceSession(
            configuration: configuration,
            claudeKeyProvider: {
                (try? keychain.read(account: KeychainStore.anthropicAPIKeyAccount)) ?? nil
            },
            openAIKeyProvider: {
                (try? keychain.read(account: KeychainStore.openAIAPIKeyAccount)) ?? nil
            },
            geminiKeyProvider: {
                (try? keychain.read(account: KeychainStore.geminiAPIKeyAccount)) ?? nil
            })
        session = newSession
        // 会話中の放置で画面ロック → バックグラウンド遷移して会話が切れるのを防ぐ
        UIApplication.shared.isIdleTimerDisabled = true
        eventTask = Task { [weak self] in
            for await event in newSession.events {
                self?.handle(event)
            }
            // セッション側が止まった（stop / 致命的エラー）
            self?.detachSession()
        }
        Task { await newSession.start() }
    }

    func stop() {
        session?.stop()
        detachSession()
    }

    private func detachSession() {
        UIApplication.shared.isIdleTimerDisabled = false
        session = nil
        eventTask = nil
        state = .idle
        partialTranscript = ""
        micLevel = 0
        micLevelEventCount = 0
    }

    #if DEBUG
    /// シミュレータで STT が使えないときの代替入力。
    func sendTypedText(_ text: String) {
        session?.submitTypedUserTurn(text)
    }
    #endif

    private func handle(_ event: VoiceSessionEvent) {
        switch event {
        case .stateChanged(let newState):
            state = newState
            if newState != .listening {
                partialTranscript = ""
            }
            #if DEBUG
            if newState == .listening, let text = pendingAutoText {
                pendingAutoText = nil
                sendTypedText(text)
            }
            #endif
        case .userPartialTranscript(let text):
            partialTranscript = text
        case .userTurnCommitted(let text):
            items.append(.message(ConversationMessage(role: .user, text: text)))
        case .assistantTextDelta(let delta):
            appendAssistantDelta(delta)
        case .assistantTurnCompleted(let fullText):
            completeAssistantTurn(fullText)
        case .turnMetrics(let metrics):
            items.append(.metrics(id: UUID(), metrics))
        case .micLevel(let level):
            micLevel = level
            micLevelEventCount += 1
        case .info(let text):
            items.append(.notice(id: UUID(), text: text))
        case .failure(let text):
            errorMessage = text
        }
    }

    private func appendAssistantDelta(_ delta: String) {
        if let id = streamingAssistantID,
           let index = items.firstIndex(where: { $0.id == id }),
           case .message(var message) = items[index] {
            message.text += delta
            items[index] = .message(message)
        } else {
            let message = ConversationMessage(role: .assistant, text: delta)
            streamingAssistantID = message.id
            items.append(.message(message))
        }
    }

    private func completeAssistantTurn(_ fullText: String) {
        defer { streamingAssistantID = nil }
        if let id = streamingAssistantID,
           let index = items.firstIndex(where: { $0.id == id }),
           case .message(var message) = items[index] {
            message.text = fullText
            items[index] = .message(message)
        } else {
            items.append(.message(ConversationMessage(role: .assistant, text: fullText)))
        }
    }
}

extension TurnMetrics {
    /// 画面表示用の 1 行サマリ。
    var summaryLine: String {
        func fmt(_ value: Double?) -> String {
            guard let value else { return "-" }
            return String(format: "%.0f", value)
        }
        return "体感 \(fmt(perceivedTotalMs))ms | 無音待ち \(fmt(endpointWaitMs)) | "
            + "STT確定 \(fmt(sttFinalizeMs)) | TTFT \(fmt(ttftMs)) | "
            + "初文 \(fmt(firstSentenceMs)) | 発声 \(fmt(speakStartMs))"
    }
}

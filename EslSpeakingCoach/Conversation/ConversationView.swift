import SwiftUI

/// 音声レイヤ検証の会話画面。エンジン（ターン制+Claude / OpenAI Realtime / Gemini Live）を切り替えて比較する。
/// 状態・ライブ文字起こし・会話ログ・ターンごとのレイテンシ実測値を表示する。
struct ConversationView: View {
    @State private var model = ConversationViewModel()
    #if DEBUG
    @State private var typedText = ""
    #endif

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            transcriptList
            Divider()
            bottomBar
        }
        .navigationTitle("会話（\(model.engine.label)）")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            #if DEBUG
            if DebugLaunchArguments.shouldStartConversation, !model.isRunning {
                model.start()
            }
            #endif
        }
        .onDisappear { model.stop() }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label(stateLabel, systemImage: stateIcon)
                .font(.callout.weight(.medium))
                .foregroundStyle(stateColor)
            Spacer()
            // barge-in しきい値チューニング用に RMS を、マイク疎通診断用にバッファ数を常時表示する
            Text(String(format: "RMS %.3f #%d", model.micLevel, model.micLevelEventCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Gauge(value: min(model.micLevel * 10, 1)) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .frame(width: 80)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.items) { item in
                        itemView(item)
                            .id(item.id)
                    }
                    if !model.partialTranscript.isEmpty {
                        liveTranscriptBubble
                            .id("live")
                    }
                }
                .padding()
            }
            .onChange(of: model.items.count) {
                if let lastID = model.items.last?.id {
                    withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
            .onChange(of: model.partialTranscript) {
                if !model.partialTranscript.isEmpty {
                    proxy.scrollTo("live", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: ConversationViewModel.DisplayItem) -> some View {
        switch item {
        case .message(let message):
            messageBubble(message)
        case .notice(_, let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .metrics(_, let metrics):
            Text(metrics.summaryLine)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func messageBubble(_ message: ConversationMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.role == .user ? Color.accentColor.opacity(0.9) : Color(.systemGray5),
                    in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
            if message.role == .assistant { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var liveTranscriptBubble: some View {
        HStack {
            Spacer(minLength: 40)
            Text(model.partialTranscript)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if !model.isRunning {
                enginePicker
                if model.engine == .turnPipeline {
                    ttsPicker
                }
            }
            #if DEBUG
            if model.isRunning, model.state == .listening {
                HStack {
                    TextField("テキストで送信（デバッグ用）", text: $typedText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit(sendTypedText)
                    Button("送信", action: sendTypedText)
                        .disabled(typedText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            #endif
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                model.toggle()
            } label: {
                Label(model.isRunning ? "会話を終了" : "会話を開始",
                      systemImage: model.isRunning ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRunning ? .red : .accentColor)
        }
        .padding()
    }

    private var enginePicker: some View {
        @Bindable var model = model
        return Picker("音声エンジン", selection: $model.engine) {
            ForEach(VoiceEngine.allCases) { engine in
                Text(engine.label).tag(engine)
            }
        }
        .pickerStyle(.segmented)
    }

    /// ターン制エンジンの TTS 差し替え比較用（Phase 3）。
    private var ttsPicker: some View {
        @Bindable var model = model
        return Picker("TTS", selection: $model.ttsProvider) {
            ForEach(TTSProvider.allCases) { provider in
                Text(provider.label).tag(provider)
            }
        }
        .pickerStyle(.segmented)
    }

    #if DEBUG
    private func sendTypedText() {
        let text = typedText
        typedText = ""
        model.sendTypedText(text)
    }
    #endif

    private var stateLabel: String {
        switch model.state {
        case .idle: return "停止中"
        case .preparing: return "準備中…"
        case .listening: return "聞き取り中"
        case .thinking: return "応答待ち"
        case .speaking: return "発話中"
        case .reconnecting: return "再接続中…"
        case .suspended: return "一時停止中"
        }
    }

    private var stateIcon: String {
        switch model.state {
        case .idle: return "pause.circle"
        case .preparing: return "hourglass"
        case .listening: return "ear"
        case .thinking: return "ellipsis.circle"
        case .speaking: return "speaker.wave.2.fill"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .suspended: return "pause.circle.fill"
        }
    }

    private var stateColor: Color {
        switch model.state {
        case .idle: return .secondary
        case .preparing: return .orange
        case .listening: return .green
        case .thinking: return .orange
        case .speaking: return .blue
        case .reconnecting: return .orange
        case .suspended: return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        ConversationView()
    }
}

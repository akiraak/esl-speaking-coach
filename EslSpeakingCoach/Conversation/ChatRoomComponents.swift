import SwiftUI

// MARK: - タイムラインの行

/// AI メッセージ: 左寄せ・アバター + 名前ラベル付き（LINE のグループトーク準拠）。
struct AIMessageRow: View {
    let message: ChatRoomStore.AIMessage
    /// 読み上げ中はアバター横（名前の隣）に 🔊 を出す
    let isSpeaking: Bool
    /// 翻訳トグル ON のとき吹き出しの下に出す日本語訳
    let translation: ChatRoomStore.TranslationDisplay

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CharacterAvatar(character: message.speaker)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(message.speaker.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ChatTheme.nameLabel)
                    if isSpeaking {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(ChatTheme.accent)
                    }
                }
                Text(message.text)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ChatTheme.aiText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        ChatTheme.aiBubble,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: ChatTheme.bubbleTailRadius,
                            bottomLeadingRadius: ChatTheme.bubbleRadius,
                            bottomTrailingRadius: ChatTheme.bubbleRadius,
                            topTrailingRadius: ChatTheme.bubbleRadius))
                    .shadow(color: ChatTheme.bubbleShadow, radius: 2, y: 1)
                TranslationLine(display: translation, alignment: .leading)
            }
            Spacer(minLength: 48)
        }
    }
}

/// ユーザーメッセージ: 右寄せ・アクセントカラー。自分のアバター・名前は表示しない（LINE 準拠）。
struct UserMessageRow: View {
    let message: ChatRoomStore.UserMessage
    /// 翻訳トグル ON のとき吹き出しの下に出す日本語訳
    let translation: ChatRoomStore.TranslationDisplay

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 3) {
                Text(message.text)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ChatTheme.userText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        ChatTheme.userBubble,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: ChatTheme.bubbleRadius,
                            bottomLeadingRadius: ChatTheme.bubbleRadius,
                            bottomTrailingRadius: ChatTheme.bubbleRadius,
                            topTrailingRadius: ChatTheme.bubbleTailRadius))
                    .shadow(color: ChatTheme.bubbleShadow, radius: 2, y: 1)
                TranslationLine(display: translation, alignment: .trailing)
            }
        }
    }
}

/// 吹き出しの下に添える日本語訳の 1 行（翻訳トグル OFF・生成対象外は何も出さない）。
struct TranslationLine: View {
    let display: ChatRoomStore.TranslationDisplay
    let alignment: HorizontalAlignment

    var body: some View {
        switch display {
        case .hidden:
            EmptyView()
        case .text(let text):
            line(text, color: ChatTheme.systemText)
        case .loading:
            line("翻訳中…", color: ChatTheme.systemText.opacity(0.6))
        case .failed:
            line("翻訳できませんでした", color: ChatTheme.systemText.opacity(0.6))
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            .padding(.horizontal, 4)
            .frame(
                maxWidth: .infinity,
                alignment: alignment == .trailing ? .trailing : .leading)
    }
}

/// 発話中の partial transcript。確定後に通常のユーザーメッセージへ置き換わる。
struct LiveTranscriptRow: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.body.weight(.medium))
                .italic()
                .foregroundStyle(ChatTheme.liveText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    ChatTheme.liveBubble,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: ChatTheme.bubbleRadius,
                        bottomLeadingRadius: ChatTheme.bubbleRadius,
                        bottomTrailingRadius: ChatTheme.bubbleRadius,
                        topTrailingRadius: ChatTheme.bubbleTailRadius))
        }
    }
}

/// LINE 風の「入力中…」インジケータ（応答生成中にタイムライン最下部へ出す）。
struct TypingIndicatorRow: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(ChatTheme.nameLabel)
                    .frame(width: 7, height: 7)
                    .opacity(isAnimating ? 1 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.18),
                        value: isAnimating)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            ChatTheme.aiBubble,
            in: UnevenRoundedRectangle(
                topLeadingRadius: ChatTheme.bubbleTailRadius,
                bottomLeadingRadius: ChatTheme.bubbleRadius,
                bottomTrailingRadius: ChatTheme.bubbleRadius,
                topTrailingRadius: ChatTheme.bubbleRadius))
        .shadow(color: ChatTheme.bubbleShadow, radius: 2, y: 1)
        .padding(.leading, 44)
        .onAppear { isAnimating = true }
    }
}

/// システムメッセージ・セッション区切り。中央寄せのピル。
struct SystemPillRow: View {
    let text: String
    /// セッション区切りは少し強調する
    let emphasized: Bool

    var body: some View {
        Text(text)
            .font(emphasized ? .caption.weight(.bold) : .caption2)
            .foregroundStyle(ChatTheme.systemText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(ChatTheme.systemPill, in: Capsule())
            // エラー通知はここにしか出ないため、長押しで本文をコピーできるようにする
            // （実機で出たエラーを転記するのに必要。読み上げ・入力の邪魔にならない導線）
            .contextMenu {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("コピー", systemImage: "doc.on.doc")
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, emphasized ? 6 : 0)
    }
}

// MARK: - アバター

struct CharacterAvatar: View {
    let character: ChatCharacter

    var body: some View {
        Image(character.avatarImageName)
            .resizable()
            .scaledToFill()
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(.white, lineWidth: 2)
            }
            .shadow(color: ChatTheme.bubbleShadow, radius: 2, y: 1)
    }
}

// MARK: - トピックカード

/// 会話モード: トピック候補 3 件 + 固定候補「話しかける」。選択でセッション開始、🔄 で差し替え、＋で自作入力。
/// 単語モード: 候補を生成しないので、練習する単語の入力ボタンだけを出す。
/// クイズモード: 出題は全部アプリ任せなので、母集団の説明と開始ボタンだけを出す
/// （出題語はカードに出さない。docs/plans/word-quiz-mode.md）。
/// 選択済み・過去のカードはグレーアウトして履歴に残す（タップ無効）。
struct TopicCardView: View {
    let card: ChatRoomStore.TopicCard
    let onSelect: (String) -> Void
    let onRegenerate: () -> Void
    let onCustomTopic: () -> Void
    /// 単語モードのみ: 単語帳（esl.chobi.me）から選ぶシートを開く
    let onWordBook: () -> Void
    /// 単語モードのみ: 未練習の語をランダムに選んで即開始する
    let onRandomWord: () -> Void
    /// クイズモードのみ: 出題語を選んで即開始する
    var onStartQuiz: () -> Void = {}
    /// ランダム出題の取得中（3 ボタンとも無効化して二重タップを防ぐ）
    var isRandomWordLoading = false
    /// 単語モードのみ: 単語帳の集計（総数・未練習数）。nil なら行ごと出さない
    /// （取得失敗・シークレット未設定・使用済みカード。docs/plans/word-card-counts.md）
    var wordBookTally: (total: Int, unpracticed: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.mode.topicCardTitle)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(ChatTheme.accent)

            switch card.mode {
            case .word:
                wordBody
            case .quiz:
                quizBody
            case .conversation:
                conversationBody
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ChatTheme.barBackground,
            in: RoundedRectangle(cornerRadius: ChatTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ChatTheme.cardRadius)
                .strokeBorder(ChatTheme.cardBorder, lineWidth: 1)
        }
        .shadow(color: ChatTheme.bubbleShadow, radius: 2, y: 1)
        .opacity(card.isUsed ? 0.55 : 1)
        .allowsHitTesting(!card.isUsed)
    }

    /// 会話モードのカード本体（候補ピル + 生成中行 + 固定候補 + 🔄 / ＋）。
    @ViewBuilder
    private var conversationBody: some View {
        // 生成済み・持ち越しの候補は出せるものから出し、残りの生成を待つ
        // （待たずに選び始められる。docs/plans/topic-card-carry-over.md）
        ForEach(card.candidates, id: \.title) { candidate in
            topicPill(candidate)
        }
        if card.isLoading {
            HStack(spacing: 8) {
                ProgressView()
                Text(card.candidates.isEmpty ? "候補を考え中…" : "もう 1 件を追加中…")
                    .font(.caption)
                    .foregroundStyle(ChatTheme.systemText)
            }
            .padding(.vertical, 4)
        }
        // 固定候補は生成を待たないので、生成中でも常に選べる状態で出す
        topicPill(ChatRoomStore.talkFirstCandidate)
        if let errorText = card.errorText {
            Text(errorText)
                .font(.caption2)
                .foregroundStyle(.red)
        }

        HStack(spacing: 10) {
            Button(action: onRegenerate) {
                Label("他の候補", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(ChatTheme.accent)
            .disabled(card.isUsed || card.isLoading)

            Button(action: onCustomTopic) {
                Label("自分で作る", systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(ChatTheme.accent)
            .disabled(card.isUsed)
        }
    }

    /// 単語モードのカード本体（候補は生成しないので入力ボタンだけ）。
    /// 使用済みのカードには練習した語を残す（履歴を遡ったときに何を練習したか分かる）。
    @ViewBuilder
    private var wordBody: some View {
        // 単語帳の進捗（例: 練習済み 42/185語 22%・未練習 143語）。見出し直下の caption
        if let tally = wordBookTally,
           let label = ChatRoomStore.wordBookTallyLabel(
               total: tally.total, unpracticed: tally.unpracticed) {
            Text(label)
                .font(.caption)
                .foregroundStyle(ChatTheme.systemText)
        }
        if let selectedTitle = card.selectedTitle {
            selectedTitleLabel(selectedTitle)
        } else if card.wordSuggestions.isEmpty {
            Text("練習したい単語や熟語を入力してください（英語）")
                .font(.caption)
                .foregroundStyle(ChatTheme.systemText)
        } else {
            // 前に練習した語（新しい順）。タップで入力アラートを挟まずそのまま始める
            // （docs/plans/vocabulary-continuity.md）
            Text("前に練習した単語（タップでもう一度）")
                .font(.caption)
                .foregroundStyle(ChatTheme.systemText)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: 8, alignment: .leading)],
                alignment: .leading, spacing: 8
            ) {
                ForEach(card.wordSuggestions, id: \.self) { word in
                    wordPill(word)
                }
            }
        }

        HStack(spacing: 10) {
            Button(action: onCustomTopic) {
                Label("単語を入力", systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(ChatTheme.accent)
            .disabled(card.isUsed || isRandomWordLoading)

            Button(action: onWordBook) {
                Label("単語帳から選ぶ", systemImage: "books.vertical")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(ChatTheme.accent)
            .disabled(card.isUsed || isRandomWordLoading)
        }

        // 上の 2 つと同列の導線だが、3 つ並べると横幅が足りないので 2 行目に置く
        Button(action: onRandomWord) {
            HStack(spacing: 6) {
                if isRandomWordLoading {
                    ProgressView()
                        .controlSize(.mini)
                    Text("単語帳から選んでいます…")
                } else {
                    Label(
                        ChatRoomStore.randomWordButtonTitle(
                            unpracticed: wordBookTally?.unpracticed),
                        systemImage: "dice")
                }
            }
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(ChatTheme.accent)
        .disabled(card.isUsed || isRandomWordLoading)
    }

    /// クイズモードのカード本体（母集団の説明 + 開始ボタンだけ。出題語は始まる前に見せない）。
    /// 使用済みのカードには出題した語の連結（`selectedTitle`）を残す（単語カードと同じ流儀）。
    @ViewBuilder
    private var quizBody: some View {
        if let selectedTitle = card.selectedTitle {
            selectedTitleLabel(selectedTitle)
        } else if card.quizPoolCount == 0 {
            Text("先に単語モードで練習してください")
                .font(.caption)
                .foregroundStyle(ChatTheme.systemText)
        } else {
            Text("練習済み \(card.quizPoolCount)語からランダムに最大\(ChatRoomStore.quizWordCount)語を出題")
                .font(.caption)
                .foregroundStyle(ChatTheme.systemText)
        }

        Button(action: onStartQuiz) {
            Label("クイズを始める", systemImage: "play.fill")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(ChatTheme.accent)
        .disabled(card.isUsed || card.quizPoolCount == 0)
    }

    /// 使用済みカードに残す「このカードから始めたもの」（練習語 / 出題語の連結）。
    private func selectedTitleLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ChatTheme.topicPillSelectedText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ChatTheme.topicPillSelected,
                in: RoundedRectangle(cornerRadius: 16))
    }

    /// 前に練習した語のピル（フックが無いぶんトピック候補より小さく、折り返して並べる）。
    private func wordPill(_ word: String) -> some View {
        Button {
            onSelect(word)
        } label: {
            Text(word)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ChatTheme.aiText)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ChatTheme.topicPill, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func topicPill(_ candidate: TopicCandidate) -> some View {
        let isSelected = card.selectedTitle == candidate.title
        return Button {
            onSelect(candidate.title)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(
                        isSelected ? ChatTheme.topicPillSelectedText : ChatTheme.aiText)
                Text(candidate.hook)
                    .font(.caption2)
                    .foregroundStyle(ChatTheme.systemText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? ChatTheme.topicPillSelected : ChatTheme.topicPill,
                in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - フィードバックカード

/// セッション終了時に投稿されるフィードバック（docs/specs/session-feedback.md）。
/// 生成中表示で即投稿され、生成完了で内容に置き換わる。失敗時はリトライ可。
struct FeedbackCardView: View {
    let card: ChatRoomStore.FeedbackCard
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("📝 Session Feedback")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(ChatTheme.accent)
            Text(card.topicTitle)
                .font(.caption)
                .foregroundStyle(ChatTheme.nameLabel)

            if card.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Chobi がフィードバックを書いています…")
                        .font(.caption)
                        .foregroundStyle(ChatTheme.systemText)
                }
                .padding(.vertical, 8)
            } else if let feedback = card.feedback {
                feedbackBody(feedback)
            } else if let errorText = card.errorText {
                Text(errorText)
                    .font(.caption2)
                    .foregroundStyle(.red)
                Button(action: onRetry) {
                    Label("もう一度生成", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(ChatTheme.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ChatTheme.barBackground,
            in: RoundedRectangle(cornerRadius: ChatTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ChatTheme.cardRadius)
                .strokeBorder(ChatTheme.cardBorder, lineWidth: 1)
        }
        .shadow(color: ChatTheme.bubbleShadow, radius: 2, y: 1)
    }

    @ViewBuilder
    private func feedbackBody(_ feedback: SessionFeedback) -> some View {
        Text(feedback.summary)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(ChatTheme.aiText)

        if !feedback.corrections.isEmpty {
            sectionHeader("直したい表現")
            ForEach(Array(feedback.corrections.enumerated()), id: \.offset) { _, correction in
                VStack(alignment: .leading, spacing: 3) {
                    correctionLine(mark: "✗", text: correction.original, color: ChatTheme.liveText)
                    correctionLine(mark: "✓", text: correction.improved, color: ChatTheme.feedbackGood)
                    Text(correction.note)
                        .font(.caption2)
                        .foregroundStyle(ChatTheme.systemText)
                        .padding(.leading, 18)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ChatTheme.topicPill, in: RoundedRectangle(cornerRadius: 12))
            }
        }

        if !feedback.tryPhrases.isEmpty {
            sectionHeader("使ってみたい表現")
            ForEach(Array(feedback.tryPhrases.enumerated()), id: \.offset) { _, tryPhrase in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tryPhrase.phrase)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ChatTheme.aiText)
                    Text(tryPhrase.meaning)
                        .font(.caption2)
                        .foregroundStyle(ChatTheme.systemText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ChatTheme.topicPill, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(ChatTheme.nameLabel)
            .padding(.top, 2)
    }

    private func correctionLine(mark: String, text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mark)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(ChatTheme.aiText)
        }
    }
}

// MARK: - タイムライン下端の固定バー

/// タイムライン下端に固定表示するバー。スクロールには乗せない（会話が追記されても位置が動かない）。
/// 翻訳トグルは常時表示（過去ログを遡って読むときにも使う）、終了ボタンはセッション中のみ。
struct TimelineBottomBar: View {
    let isTranslationVisible: Bool
    let isSessionActive: Bool
    /// 終了ボタンの文言の出し分け（`PracticeMode.endSessionButtonTitle`）
    var practiceMode: PracticeMode = .conversation
    let onToggleTranslation: () -> Void
    let onEndSession: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleTranslation) {
                Text("翻訳")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isTranslationVisible ? ChatTheme.userText : ChatTheme.aiText)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(
                        isTranslationVisible ? AnyShapeStyle(ChatTheme.accent)
                            : AnyShapeStyle(ChatTheme.barBackground),
                        in: RoundedRectangle(cornerRadius: ChatTheme.cardRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: ChatTheme.cardRadius)
                            .strokeBorder(
                                isTranslationVisible ? .clear : ChatTheme.cardBorder, lineWidth: 1)
                    }
                    .shadow(color: ChatTheme.bubbleShadow, radius: 6, y: 2)
            }
            .accessibilityLabel(isTranslationVisible ? "翻訳を隠す" : "翻訳を表示")

            if isSessionActive {
                Button(action: onEndSession) {
                    Label(practiceMode.endSessionButtonTitle, systemImage: "flag.checkered")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(ChatTheme.userText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            ChatTheme.accent,
                            in: RoundedRectangle(cornerRadius: ChatTheme.cardRadius))
                        .shadow(color: ChatTheme.bubbleShadow, radius: 6, y: 2)
                }
            } else {
                // セッション外は翻訳ボタンだけ。中央寄せにせず左端に置く
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - 入力バー

/// LINE 風入力バー。マイクボタンで音声モードへ変形し、キーボードボタンでテキストモードへ戻る。
struct ChatInputBar: View {
    let store: ChatRoomStore
    @Binding var draftText: String
    let onSend: () -> Void

    var body: some View {
        Group {
            if store.canResumeAfterFailure {
                resumeBar
            } else if !store.isSessionActive {
                idleBar
            } else if store.inputMode == .voice {
                voiceBar
            } else {
                textBar
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ChatTheme.barBackground
                .shadow(color: ChatTheme.bubbleShadow, radius: 3, y: -1)
                .ignoresSafeArea(edges: .bottom))
    }

    /// セッション未開始（トピック選択・単語入力・クイズ開始待ち）。
    private var idleBar: some View {
        Text(store.practiceMode.idlePrompt)
            .font(.footnote)
            .foregroundStyle(ChatTheme.systemText)
            .frame(maxWidth: .infinity, minHeight: 36)
    }

    /// 致命的エラーでセッションが落ちたときの再開導線。
    private var resumeBar: some View {
        Button {
            store.resumeSessionAfterFailure()
        } label: {
            Label("会話を再開する", systemImage: "arrow.clockwise.circle.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(ChatTheme.accent)
    }

    private var textBar: some View {
        HStack(spacing: 10) {
            Button {
                store.setInputMode(.voice)
            } label: {
                Image(systemName: "mic.fill")
                    .font(.title3)
                    .foregroundStyle(ChatTheme.accent)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            TextField("メッセージを入力", text: $draftText, axis: .vertical)
                .font(.body)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(ChatTheme.inputField, in: RoundedRectangle(cornerRadius: 18))
                .onSubmit(onSend)
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? ChatTheme.accent.opacity(0.35) : ChatTheme.accent,
                        in: Circle())
            }
            .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// ハンズフリー連続の音声モード。サーバ VAD でターン検出、読み上げ中の barge-in 可。
    private var voiceBar: some View {
        HStack(spacing: 10) {
            Button {
                store.setInputMode(.text)
            } label: {
                Image(systemName: "keyboard")
                    .font(.title3)
                    .foregroundStyle(ChatTheme.accent)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            voiceStatus
                .frame(maxWidth: .infinity, minHeight: 36)
            Button {
                store.toggleVoicePause()
            } label: {
                Image(systemName: store.isVoicePaused ? "play.fill" : "pause.fill")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(ChatTheme.accent, in: Circle())
            }
        }
    }

    @ViewBuilder
    private var voiceStatus: some View {
        if store.isVoicePaused {
            Text("聞き取りを一時停止中")
                .font(.footnote)
                .foregroundStyle(ChatTheme.systemText)
        } else {
            switch store.voiceState {
            case .reconnecting:
                Label("再接続中…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(ChatTheme.systemText)
            case .suspended:
                Text("一時停止中")
                    .font(.footnote)
                    .foregroundStyle(ChatTheme.systemText)
            case .preparing:
                Label("接続中…", systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(ChatTheme.systemText)
            default:
                // 聞き取り中は波形アニメーション、応答待ち・読み上げ中は停止・薄色
                HStack(spacing: 8) {
                    Circle()
                        .fill(store.voiceState == .listening ? Color.red : ChatTheme.systemText)
                        .frame(width: 8, height: 8)
                    WaveformView(
                        level: store.micLevel,
                        isActive: store.voiceState == .listening)
                }
            }
        }
    }
}

/// マイクレベル連動の波形アニメーション。
struct WaveformView: View {
    let level: Float
    let isActive: Bool

    private let barCount = 20

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(isActive ? ChatTheme.accent : ChatTheme.accent.opacity(0.3))
                        .frame(width: 3, height: barHeight(index: index, time: time))
                }
            }
            .frame(height: 30, alignment: .center)
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        guard isActive else { return 6 }
        // RMS（実測 0〜0.1 程度）を見た目の振幅へ増幅し、バーごとに位相をずらして波らしく見せる
        let amplitude = CGFloat(min(max(level * 10, 0.08), 1))
        let wave = sin(time * 7 + Double(index) * 0.9) * 0.5 + 0.5
        return 6 + amplitude * wave * 22
    }
}

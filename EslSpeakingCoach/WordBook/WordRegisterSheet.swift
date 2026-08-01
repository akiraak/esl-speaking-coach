import Foundation
import Observation
import SwiftUI

/// 吹き出し長押し →「単語・熟語を登録」で開く登録シートの状態
/// （docs/plans/tap-word-registration.md Phase 2）。
/// 発話全文を単語チップで出し、選択のたびに正規化 API（原形・句全体の提案）を引いて
/// 編集可能な候補フィールドへ反映し、「登録」で word-info API（サーバ側 AI 生成 + 保存）を呼ぶ。
@MainActor
@Observable
final class WordRegisterStore {
    typealias NormalizeClient =
        @MainActor (_ word: String, _ context: String?) async throws -> WordNormalization
    typealias RegisterClient =
        @MainActor (_ word: String, _ context: String?) async throws -> WordRegistrationResult

    /// 正規化 API に渡す文脈の上限。サーバ側クランプ（300 字）より手前で切る
    /// （esl-learning-assistant iOS の切り出し上限 240 字と同値）。
    static let normalizeContextMaxLength = 240
    /// 登録語の上限（サーバの WORD_MAX_LENGTH と同値。超過は 400 になるので手前で弾く）
    static let wordMaxLength = 100

    /// 対象発話の全文（登録 API の context にそのまま渡す）
    let messageText: String
    /// 発話をチップ表示用に分割した語（句読点・引用符を剥がし済み）
    let tokens: [String]
    private(set) var selectedIndices: Set<Int> = []
    /// 登録する語（編集可能。選択が変わるたび選択語 / 正規化提案で置き換わる）
    var candidateText = ""
    /// 正規化の説明（inflected / misspelled / phrase_part の reason。提案が無ければ nil）
    private(set) var suggestionNote: String?
    private(set) var isNormalizing = false
    private(set) var isRegistering = false
    /// 登録結果（登録しました / すでにあります）。エラーとは別に持つ
    private(set) var resultText: String?
    private(set) var errorText: String?
    /// 実行中の正規化（E2E・テストから完了を待つ用）
    private(set) var normalizeTask: Task<Void, Never>?
    /// 直近の正規化結果（register 時に「この候補は正規化済みか」を判定する。
    /// docs/plans/tap-word-registration.md Phase 4）
    private(set) var lastNormalization: WordNormalization?
    /// ストアが最後に設定した候補（これと異なれば = ユーザーが手動編集した）
    private var lastStoreSetCandidate = ""
    /// 選択の連打で古い正規化結果を適用しないための世代カウンタ
    private var normalizeGeneration = 0
    /// テストから 0 にする（実機は連打を 1 リクエストに畳むためのデバウンス）
    var normalizeDebounce: Duration = .milliseconds(350)
    /// 新規登録に成功したとき呼ぶ（単語カードの集計の取り直し用）
    var onRegistered: () -> Void = {}

    private let normalizeClient: NormalizeClient
    private let registerClient: RegisterClient

    init(
        messageText: String,
        normalizeClient: @escaping NormalizeClient = WordRegisterStore.liveNormalize,
        registerClient: @escaping RegisterClient = WordRegisterStore.liveRegister
    ) {
        self.messageText = messageText
        self.tokens = Self.tokens(from: messageText)
        self.normalizeClient = normalizeClient
        self.registerClient = registerClient
    }

    // MARK: - チップ選択

    func toggleToken(at index: Int) {
        guard tokens.indices.contains(index), !isRegistering else { return }
        if selectedIndices.contains(index) {
            selectedIndices.remove(index)
        } else {
            selectedIndices.insert(index)
        }
        resultText = nil
        errorText = nil
        suggestionNote = nil
        setCandidate(Self.phrase(selectedIndices: selectedIndices, tokens: tokens))
        scheduleNormalize()
    }

    func isSelected(_ index: Int) -> Bool {
        selectedIndices.contains(index)
    }

    /// ストア起点の候補更新（手動編集の検知用に控えを残す）。
    private func setCandidate(_ text: String) {
        candidateText = text
        lastStoreSetCandidate = text
    }

    /// 候補フィールドがユーザーの手で編集されているか（編集後は正規化で上書きしない・
    /// register 時の再正規化もしない = 変化形をあえて登録する逃げ道）。
    var isCandidateManuallyEdited: Bool {
        candidateText != lastStoreSetCandidate
    }

    /// 選択のたびに正規化を引き直す（デバウンス付き・最後の選択だけ適用）。
    /// 失敗は提案が出ないだけで登録は止めない（候補には選択語が残っている）。
    private func scheduleNormalize() {
        normalizeGeneration += 1
        let generation = normalizeGeneration
        normalizeTask?.cancel()
        isNormalizing = false
        let word = candidateText
        guard !selectedIndices.isEmpty, !word.isEmpty else {
            normalizeTask = nil
            return
        }
        let context = Self.contextWindow(
            in: messageText,
            around: tokens[selectedIndices.min() ?? 0],
            maxLength: Self.normalizeContextMaxLength)
        normalizeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: normalizeDebounce)
            guard !Task.isCancelled, generation == self.normalizeGeneration else { return }
            self.isNormalizing = true
            defer {
                if generation == self.normalizeGeneration { self.isNormalizing = false }
            }
            do {
                let result = try await self.normalizeClient(word, context)
                guard generation == self.normalizeGeneration else { return }
                self.lastNormalization = result
                // 手動編集後は候補を上書きしない（ユーザーの意図を尊重）
                guard !self.isCandidateManuallyEdited else { return }
                self.applySuggestion(result)
            } catch {
                guard generation == self.normalizeGeneration else { return }
                DiagnosticsLog.record("!! wordRegister: 正規化に失敗 \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 正規化提案の適用（Phase 4: status ではなく lemma の差で判定する）

    /// 提案を候補フィールドへ適用する。サーバ仕様上フレーズの変化形は inflected だが、
    /// 実際の AI 出力は phrase のまま lemma だけ直すことがある（makes sense → make sense）ため、
    /// status ではなく **lemma が入力と違うか**で適用を決める。
    private func applySuggestion(_ result: WordNormalization) {
        guard Self.isCorrection(result) else { return }
        setCandidate(result.lemma)
        suggestionNote = result.reason.isEmpty
            ? "基本形「\(result.lemma)」に直しました"
            : result.reason
    }

    /// 正規化結果が「訂正」か（= lemma が入力とキー比較で異なる）。
    static func isCorrection(_ result: WordNormalization) -> Bool {
        let lemmaKey = ChatRoomStore.normalizedWordKey(result.lemma)
        return !lemmaKey.isEmpty
            && lemmaKey != ChatRoomStore.normalizedWordKey(result.input)
    }

    // MARK: - 登録

    /// 登録する。基本形での登録を保証するため（Phase 4）、手動編集されていない候補は
    /// (a) 実行中の正規化を待ち、(b) まだ正規化が走っていなければ登録前に 1 回実行してから送る。
    /// 変化形から直して登録したときは結果表示に明示する。
    func register() async {
        guard !isRegistering else { return }
        let tappedWordKey = ChatRoomStore.normalizedWordKey(candidateText)
        guard !tappedWordKey.isEmpty else { return }
        isRegistering = true
        resultText = nil
        errorText = nil
        defer { isRegistering = false }

        if isCandidateManuallyEdited {
            // 手動編集はそのまま登録する（進行中の正規化提案で上書きもさせない）
            normalizeGeneration += 1
            normalizeTask?.cancel()
        } else {
            await normalizeTask?.value
            if !isNormalized(ChatRoomStore.normalizedWordKey(candidateText)) {
                await normalizeCandidateBeforeRegister()
            }
        }

        // 表記ゆれの二重登録を防ぐため単語帳の既存キー規則（小文字 + 空白畳み込み）に合わせる
        let word = ChatRoomStore.normalizedWordKey(candidateText)
        guard !word.isEmpty else { return }
        guard word.count <= Self.wordMaxLength else {
            errorText = "登録できるのは \(Self.wordMaxLength) 文字までです"
            return
        }
        do {
            let result = try await registerClient(word, messageText)
            let meaning = result.firstMeaning.map { "（\($0)）" } ?? ""
            // 変化形から直して登録した場合はそれが分かる文にする（makes sense → make sense）
            let correction = word == tappedWordKey
                ? "" : "「\(tappedWordKey)」を基本形「\(word)」に直しました。"
            if result.cached {
                resultText = correction + "「\(word)」はすでに単語帳にあります\(meaning)"
            } else {
                resultText = correction + "「\(word)」を登録しました\(meaning)"
                onRegistered()
            }
            DiagnosticsLog.record("wordRegister: \(result.cached ? "既存" : "新規") \(word)")
        } catch {
            DiagnosticsLog.record("!! wordRegister: 登録に失敗 \(error.localizedDescription)")
            errorText = (error as? WordBookError)?.errorDescription
                ?? "登録に失敗しました: \(error.localizedDescription)"
        }
    }

    /// この候補に対して正規化が済んでいるか（直近結果の input / lemma のどちらかとキー一致）。
    private func isNormalized(_ wordKey: String) -> Bool {
        guard let last = lastNormalization else { return false }
        return wordKey == ChatRoomStore.normalizedWordKey(last.input)
            || wordKey == ChatRoomStore.normalizedWordKey(last.lemma)
    }

    /// 登録直前の正規化（選択時の正規化が失敗していた場合の再挑戦）。
    /// 失敗しても登録は止めない（候補のまま送る）。
    private func normalizeCandidateBeforeRegister() async {
        let word = candidateText
        let firstWord = word.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? word
        let context = Self.contextWindow(
            in: messageText, around: firstWord, maxLength: Self.normalizeContextMaxLength)
        isNormalizing = true
        defer { isNormalizing = false }
        do {
            let result = try await normalizeClient(word, context)
            lastNormalization = result
            applySuggestion(result)
        } catch {
            DiagnosticsLog.record(
                "!! wordRegister: 登録前の正規化に失敗（候補のまま登録）\(error.localizedDescription)")
        }
    }

    // MARK: - 純関数（テスト対象）

    /// 発話をチップ用の語に分割する。空白で切り、両端の記号（引用符・句読点）を剥がす。
    /// 語中のアポストロフィ・ハイフン（don't / co-op）は残す。英字を含まないトークンは落とす。
    static func tokens(from text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            var token = raw
            while let first = token.first, !first.isLetter, !first.isNumber {
                token.removeFirst()
            }
            while let last = token.last, !last.isLetter, !last.isNumber {
                token.removeLast()
            }
            guard token.contains(where: \.isLetter) else { return nil }
            return String(token)
        }
    }

    /// 選択した語を出現順に半角スペースで連結する（離れた語の選択も句候補として許す）。
    static func phrase(selectedIndices: Set<Int>, tokens: [String]) -> String {
        selectedIndices.sorted()
            .filter { tokens.indices.contains($0) }
            .map { tokens[$0] }
            .joined(separator: " ")
    }

    /// 正規化 API に渡す文脈。発話が上限内ならそのまま、長ければ対象語を中心に丸める
    /// （句動詞の構成語は近傍にあるため。語が見つからなければ先頭から切る）。
    static func contextWindow(in text: String, around word: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength, maxLength > 0 else { return trimmed }
        guard !word.isEmpty,
              let range = trimmed.range(of: word)
                  ?? trimmed.range(of: word, options: .caseInsensitive)
        else {
            return String(trimmed.prefix(maxLength))
        }
        let center = trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)
            + word.count / 2
        var start = max(0, center - maxLength / 2)
        start = min(start, trimmed.count - maxLength)
        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: start)
        let endIndex = trimmed.index(startIndex, offsetBy: maxLength)
        return String(trimmed[startIndex..<endIndex])
    }

    // MARK: - 実クライアント（Keychain のシークレットで esl.chobi.me を叩く）

    static func liveNormalize(word: String, context: String?) async throws -> WordNormalization {
        try await WordBookClient().normalizeWord(
            secret: try readSecret(), word: word, context: context)
    }

    static func liveRegister(word: String, context: String?) async throws -> WordRegistrationResult {
        try await WordBookClient().registerWord(
            secret: try readSecret(), word: word, context: context)
    }

    private static func readSecret() throws -> String {
        guard
            let secret = (try? KeychainStore().read(
                account: KeychainStore.wordBookAPISecretAccount)) ?? nil,
            !secret.isEmpty
        else {
            throw WordBookError.missingSecret
        }
        return secret
    }
}

// MARK: - シート本体

/// 吹き出し長押し →「単語・熟語を登録」で開くシート。
struct WordRegisterSheet: View {
    @State private var store: WordRegisterStore
    @Environment(\.dismiss) private var dismiss

    init(messageText: String, onRegistered: @escaping () -> Void = {}) {
        let store = WordRegisterStore(messageText: messageText)
        store.onRegistered = onRegistered
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("登録したい単語をタップ（複数選ぶと熟語になります）")
                        .font(.caption)
                        .foregroundStyle(ChatTheme.systemText)

                    WrapLayout(spacing: 8) {
                        ForEach(Array(store.tokens.enumerated()), id: \.offset) { index, token in
                            tokenChip(token, index: index)
                        }
                    }

                    candidateField
                    registerButton
                    resultLines
                }
                .padding(16)
            }
            .background(ChatTheme.chatBackground)
            .navigationTitle("単語・熟語を登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func tokenChip(_ token: String, index: Int) -> some View {
        let isSelected = store.isSelected(index)
        return Button {
            store.toggleToken(at: index)
        } label: {
            Text(token)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? ChatTheme.topicPillSelectedText : ChatTheme.aiText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isSelected ? ChatTheme.topicPillSelected : ChatTheme.barBackground,
                    in: Capsule())
                .overlay {
                    Capsule().strokeBorder(
                        isSelected ? ChatTheme.accent.opacity(0.5) : ChatTheme.cardBorder,
                        lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private var candidateField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("登録する語（英語）", text: $store.candidateText)
                    .font(.body.weight(.medium))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(ChatTheme.inputField, in: RoundedRectangle(cornerRadius: 14))
                if store.isNormalizing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let note = store.suggestionNote {
                // 正規化の説明（例: 「『picked』は動詞『pick』の過去形です」）
                Text(note)
                    .font(.caption)
                    .foregroundStyle(ChatTheme.systemText)
            }
        }
        .padding(.top, 4)
    }

    private var registerButton: some View {
        Button {
            Task { await store.register() }
        } label: {
            HStack(spacing: 6) {
                if store.isRegistering {
                    ProgressView()
                        .controlSize(.small)
                        .tint(ChatTheme.userText)
                    Text("登録しています…")
                } else {
                    Label("単語帳に登録", systemImage: "plus.circle.fill")
                }
            }
            .font(.subheadline.weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(ChatTheme.accent)
        .disabled(
            store.isRegistering
                || ChatRoomStore.normalizedWordKey(store.candidateText).isEmpty)
    }

    @ViewBuilder
    private var resultLines: some View {
        if let resultText = store.resultText {
            Text(resultText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ChatTheme.feedbackGood)
        }
        if let errorText = store.errorText {
            Text(errorText)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - 折り返しレイアウト

/// チップを行内に詰めて幅が足りなくなったら折り返す（単語チップ用の最小実装）。
struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : max(0, x - spacing)
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    WordRegisterSheet(messageText: "I finally got around to reading the book you recommended!")
}

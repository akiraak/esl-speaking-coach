# チャット欄英語の再読み上げ — 実装プラン

> **状況（2026-08-01）**: Phase 1〜3 実装済み・単体テスト 12 件 + シミュレータ E2E
> （保存 → ファイル再生 / キャッシュ削除 → 再生成 / 新セッション開始で前セッション分の削除）確認済み。
> **残りは実機確認のみ**（出力経路・再読み上げ直後のセッション開始・キャッシュ実サイズ）。
> E2E 用の起動引数 `-replay-latest`（最後の AI 吹き出しをタップした扱い）を追加してある。

## 目的・背景

AI の発話は読み上げが一度流れたら聞き直せない。聞き逃した文・気に入った表現を
**吹き出しタップでもう一度再生**できるようにする。過去セッションの復習
（タイムラインを遡って聞き直す）にも使う。

直前のセッションぶんは TTS 音声をローカルに保存しておき、**即時・無料**で再生する。
ファイルが無いもの（それ以前のセッションなど）は TTS で再生成する。

## 関連プランとの整合（共通決定）

3 つのプラン（[tap-word-registration](archive/tap-word-registration.md)（実装済み） / 本プラン /
[chat-storage-audit](chat-storage-audit.md)）で吹き出しへの操作と保存ポリシーを共有する。
**変更するときは 3 プラン同時に見直すこと。**

1. **吹き出しのジェスチャ体系**
   - **タップ = 再読み上げ**（AI 吹き出しのみ。本プランで実装）
   - **長押し = コンテキストメニュー**（「単語・熟語を登録」「コピー」。tap-word-registration 側）
   - 吹き出し内の語を直接タップ可能にはしない（登録はシート内で選ぶ）
2. **音声ファイルは「直前の 1 セッション」だけローカル保存する**（Caches 配下・
   セッション ID 単位）。再読み上げは保存ファイルがあればそれを再生し、
   無いもの（過去セッション・OS の Caches 掃除・取得中断の未完ファイル）は
   TTS で再生成して**使い捨てる**（再保存しない）。削除は本プランの「削除設計」参照
3. **発話テキスト（`ChatMessageRecord.text`）が唯一の永続情報源**。話者も保存済みなので、
   音声ファイルはいつ消えてもテキスト + `ChatCharacter.speechStyle` から再生成できる

## スコープの決定

- **再生（タップ）はセッション外のみ**（`session == nil && !canResumeAfterFailure`）。
  セッション中は `TurnBasedVoiceSession` が AVAudioSession（playAndRecord / voiceChat）と
  AVAudioEngine を占有しており、別エンジンでの同時再生は入力ゲート・エコーと干渉する。
  セッション中のタップは無視。**保存はセッション中に行う**（読み上げ音声の取得のついで）
- **ユーザー吹き出しは対象外**（そもそも読み上げられておらず音声も存在しない。
  自分の発話をお手本音声で聞く案は将来の拡張として長押しメニュー「読み上げ」で足せる）
- クイズセッションの吹き出しも対象（チャット欄に出ている文言しか読まないので出題語は漏れない）

## 対応方針

### 音声キャッシュの保存（セッション中）

- 保存先: `Caches/UtteranceAudio/<sessionID>/<utteranceID>.wav`
  - **Caches を選ぶ理由**: 再生成できるデータの置き場として意味が合い、
    容量逼迫時に OS が消してくれる（消えても再生成でカバーされる）
  - `<utteranceID>` = 吹き出しの `ChatMessageRecord.id` と同一（タイムラインから直接引ける）
- 形式: **WAV（PCM16 / 24kHz / mono）**。TTS が返すチャンクをそのまま追記できて実装が単純。
  約 2.9MB/分（AI 発話時間あたり）× 1 セッション分のみなので許容。
  実測で気になったら AAC（.m4a、`AVAudioFile` に AAC 設定で書く）へ切り替える余地を残す
- 書き込み: `CloudSentenceSpeaker` の取得ループ（`CloudSentenceSpeaker.swift:117-155`）に
  録音フック（新規 `UtteranceAudioRecorder`）を注入する。文単位チャンクを
  utteranceID ごとのファイルへ追記
  - 書き込み中は `<utteranceID>.part`、**その発話の全文の取得が完了した時点で `.wav` へ rename**。
    取得順は発話単位で直列なので「次の utteranceID の先頭チャンク到着」または
    「endStream 後のキュー読み切り」が完了の合図になる
  - `stopNow` / `shutdown`（中断・セッション停止）時は書きかけの `.part` をそのまま残す
    （= 未完マーカー。再生対象にせず、次回掃除で消える）
- sessionID は `ChatRoomStore` が知っている（`activeSessionID`）ので、
  `TurnBasedVoiceSession.Configuration` 経由で recorder を注入する。
  **エラー再開（`resumeSessionAfterFailure`）は同じ sessionID を引き継ぐ**ので、
  再開後の発話も同じディレクトリに足され、再開前のファイルも生きる

### 削除設計

不変条件: **`UtteranceAudio/` 配下に完結ファイルが存在するのは最新 1 セッション分だけ**。

- **トリガ 1 — 新セッション開始時**（`ChatRoomStore.startSession`）:
  これから使う sessionID **以外**のディレクトリを全削除してから開始する。
  「セッション終了時に消す」にしない理由: 終了直後〜次の開始までの間が
  「直前セッションを聞き直したい」時間帯そのものだから
- **トリガ 2 — アプリ起動時**: 最新セッション（`ChatHistoryStore.recentSessions` の先頭）
  以外のディレクトリと、全ディレクトリ内の `.part` を削除する。
  クラッシュ・強制終了でトリガ 1 を通らなかったぶんの取りこぼし対策
- OS による Caches 掃除は**許容**（消えたら再生成にフォールバック。特別な検知はしない）
- 退けた代替案:
  - **TTL（例: 24 時間で削除）**: 「直前の 1 セッション」という要件と一致しない
    （間が空くと直前セッションなのに消える / 短時間に 2 セッションやると 2 つ残る）
  - **サイズ上限 + LRU**: 1 セッション分しか持たない要件では過剰。上限は要件側で既に効いている
  - **吹き出し個別の手動削除 UI**: 自動で不変条件を保てるので手動管理は不要
- 任意: 管理画面のストレージ表示（chat-storage-audit Phase 1）に「音声キャッシュ」行と
  「今すぐ全削除」ボタンを足す（逃げ道。無くても成立する）

### 再生（タップ時）

1. `Caches/UtteranceAudio/*/<utteranceID>.wav` が**あれば**それを再生
   （即時・無料・オフラインでも可。`.part` は無いものとして扱う）
2. **無ければ** TTS で再生成: テキストを `SentenceChunker` で文分割して
   既存 `CloudSentenceSpeaker` + `StreamingAudioPlayer` の経路で順に再生（初音が速い）。
   再生成した音声は**保存しない**（保存はセッション中のみ、の一本化で削除設計を単純に保つ。
   「最新セッションの欠落ファイルだけ再保存」は必要になったときの拡張とする）

### TTS クライアント生成の共有化（再生成経路の前提整備）

- プロバイダ選択 → `SentenceTTSClient` 生成は現在 `TurnBasedVoiceSession`
  （`TurnBasedVoiceSession.swift:189-200`）に埋まっている。
  `SentenceTTSClientFactory.make(provider:configuration:)` として切り出し、
  セッションと再生成の両方が**同じ既定（Qwen instruct）・同じ voice 写像**を使うようにする
- **注意**: `ChatRoomStore.launchSession` の DEBUG 行
  `ttsProviderOverride ?? .gemini`（`ChatRoomStore.swift:682`）は Qwen 切替（7c95fdb）後も
  残った**既定上書きバグ**（TODO の不具合に登録済み）。ファクトリ化の際に
  「既定は `Configuration` の 1 箇所、DEBUG は override があるときだけ上書き」に正す。
  なお **voice が変わるとキャッシュ音声と再生成音声で声が変わる**ため、
  このバグを直してから保存を有効にする（Gemini 声で溜めたファイルが残らないように）

### 再生エンジン・AVAudioSession

- 新規 `UtteranceReplayer`（@MainActor。`Voice/CloudPipeline/`）: ファイル再生と
  再生成再生の両経路を持つ。ファイル再生は WAV の PCM ペイロードを読んで
  `StreamingAudioPlayer.enqueue(pcm16Data:)` に流す（保存形式 = 再生形式なので変換不要）
- **AVAudioSession はセッションと別プロファイル**: 再生専用なので `.playback` を
  再生開始時に setCategory + setActive、完了 / 停止時に
  `setActive(false, .notifyOthersOnDeactivation)`。マイクを使わないため
  `AudioRoutePolicy`（playAndRecord 用）や `.speaker` オーバーライドは**適用しない**
  （経路は OS の既定ルーティングに任せる）
- `ChatRoomStore.startSession` の冒頭で `replayer.stop()`（再生中にセッションを始めたら止める。
  削除トリガ 1 と同じ場所）

### UI・状態

- `ChatRoomStore` に `replayingUtteranceID: UUID?` を追加。
  `AIMessageRow` の 🔊（`isSpeaking`）を「セッションの読み上げ中 or 再読み上げ中」で点灯させる
- タップ（AI 吹き出し）: 同じ吹き出し再タップ = 停止 / 別の吹き出し = 切り替え
- usage 記録: **再生成時のみ** `UsageStore.record`（sessionID = nil）。ファイル再生は無料なので記録しない
- DashScope キー未設定・取得失敗（再生成時のみ起こる）はタイムラインを汚さず
  一時アラート + `DiagnosticsLog` に記録

## 影響範囲

- `TurnBasedVoiceSession.swift`（クライアント生成のファクトリ抽出・recorder 注入の Configuration 追加）
- `CloudSentenceSpeaker.swift`（録音フック呼び出し。フック未注入なら従来どおり）
- 新規 `SentenceTTSClientFactory.swift` / `UtteranceAudioRecorder.swift` / `UtteranceReplayer.swift`
- `ChatRoomStore.swift`（replayingUtteranceID・タップハンドラ・開始時の停止 + 掃除・起動時掃除）
- `ChatRoomView.swift` / `ChatRoomComponents.swift`（AI 吹き出しの onTapGesture と 🔊 条件。
  長押しメニュー（tap-word-registration）と同じ Text に付けるので導線の食い合いに注意）

## テスト方針

- 単体: ファクトリのプロバイダ分岐 / recorder の完結・未完遷移（.part → rename、stopNow で残る）/
  掃除の対象選別（「残す sessionID」以外を列挙する純関数）/ ファイル優先 → 再生成フォールバック /
  状態遷移（再生・再タップ停止・切り替え・セッション開始で停止）
- シミュレータ: セッション実施 → 終了後にタップで**通信なしに**再生される（ファイル経路）、
  過去セッションの吹き出しで再生成される、次セッション開始で前セッションの音声が消える
- 実機: イヤフォン / Bluetooth / 内蔵スピーカーの各経路、再読み上げ直後のセッション開始
  （.playback → playAndRecord 遷移）、長めのセッションでの音声キャッシュ実サイズ確認

## Phase 分割

- Phase 1: TTS クライアント生成のファクトリ化（既定バグ修正と整合）+ `UtteranceReplayer`
  （再生成経路のみ。キャッシュ無しで動く最小形）
- Phase 2: 音声キャッシュ（`UtteranceAudioRecorder` の保存・.part 完結・
  開始時 / 起動時の削除・ファイル優先再生）
- Phase 3: タップ導線・🔊 表示・停止 / 切り替え・usage 記録 → 実機確認
  （出力経路・セッション遷移・キャッシュ実サイズ・削除の動き）

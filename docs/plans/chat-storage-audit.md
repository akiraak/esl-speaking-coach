# ファイル保存で容量を圧迫していないかチェック — 調査プラン

## 目的・背景

長く使い続ける個人ツールなので、「アプリが端末に何を書いていて、どのくらいの速度で
増えるのか」を一度確定させ、放置してよいものと掃除が要るものを切り分ける。
あわせて管理画面からストレージ使用量を常時確認できるようにする。

## 関連プランとの整合（共通決定）

3 つのプラン（[tap-word-registration](archive/tap-word-registration.md)（実装済み） /
[utterance-replay](archive/utterance-replay.md) / 本プラン）で保存ポリシーを共有する。
**変更するときは 3 プラン同時に見直すこと。**

1. **音声ファイルは「直前の 1 セッション」だけローカル保存する**（Caches 配下・
   セッション ID 単位。utterance-replay で実装）。再読み上げは保存ファイルがあれば
   それを再生し、無いものは TTS で再生成して使い捨てる。削除は
   「次セッション開始時 + アプリ起動時」に最新セッション以外を消す
   （詳細は utterance-replay の「削除設計」）。**上限が要件側で効いている**
   （常に 1 セッション分で頭打ち）ので、本プランでは実サイズの把握と表示だけを行う
2. **端末で無期限に増え続けるのは SwiftData ストア（テキスト）だけ**、を保つ。
   音声キャッシュ・エクスポートなど再生成できるものは上限か掃除を必ず持つ
3. **発話テキスト（`ChatMessageRecord.text`）が唯一の永続情報源**。
   音声はいつ消えても再生成できる（OS の Caches 掃除も許容する設計）

## 現状インベントリ（コードから確定済み。Phase 1 で実測して裏取りする）

書き込み箇所の全数調査（`FileManager` / `write(to:)` の grep）で以下のみ:

| 保存先 | 内容 | 増え方 | 上限 |
| --- | --- | --- | --- |
| Application Support/`default.store`（SwiftData。`AppModelContainer.swift:17`） | セッション・発話（訳込み）・調査ログ・AI 利用量・記憶ノート | セッションごと。**無期限に蓄積** | なし |
| Application Support/`Diagnostics/app.log`（`DiagnosticsLog.swift:110`） | 診断ログ | 追記 | **256KB で切り詰め**（`DiagnosticsLog.swift:15`）→ 問題なし |
| tmp/`esl-sessions-*.json`（`SessionExporter.swift:55`） | 全セッションの JSON エクスポート（DEBUG 管理画面のみ） | 書き出すたび 1 ファイル。**削除していない**（OS の tmp 掃除任せ） | なし |
| Caches/`UtteranceAudio/<sessionID>/`（**utterance-replay で実装済み**） | AI 発話の TTS 音声（WAV・約 2.9MB/分） | セッション中に追記 | **常に最新 1 セッション分**（次セッション開始時 + 起動時に前のを削除。OS の Caches 掃除も許容） |
| UserDefaults / Keychain | モード・トグル・API キー | 定数個 | 問題なし |

- 上記以外に音声ファイルは書いていない（STT はマイク → WebSocket、TTS はストリーミング再生、
  ジングルはメモリ生成）
- アプリバンドル: `docs/plans/assets/` の検証用 wav（約 12MB）は **ターゲット外**
  （`project.yml` の sources は `EslSpeakingCoach/` のみ）なのでバンドルには入らない。
  リポジトリ容量の問題であり端末容量とは無関係（現状 12MB は許容）

### SwiftData ストアの増加要因（実測前の見立て）

- 発話: テキスト + 訳のみで軽い
- `ChatSessionLogRecord`: metrics が**ターンごとに 1 行**、notice / error も蓄積
- `APIUsageRecord`（`UsageStore.swift:75`）: **API 呼び出しごとに 1 行**。
  TTS は文単位リクエストなので 1 セッションで数十行になり、発話より行数が多い可能性がある
- 再読み上げ（utterance-replay）実装後は**再生成した再生 1 回ごと**に usage 行が増える点も織り込む
  （ファイル再生は usage 行を作らない）

## Phase 分割

### Phase 1: 可視化と実測

- 管理画面（`AdminView`）に「ストレージ」行を追加: SwiftData ストア一式
  （default.store + `-wal` / `-shm`）・Diagnostics ログ・tmp のエクスポート残骸・
  音声キャッシュ（`UtteranceAudio/`。utterance-replay Phase 2 で実装済み）の各サイズと合計を表示
  （サイズ集計は URL 列挙の純関数にしてテスト）
- 実機で実測し、レコード件数（セッション / 発話 / ログ / usage 行）と突き合わせて
  **1 セッションあたりの増分**を概算 → 年間増加量を見積もる
  （エクスポート JSON のサイズ ÷ セッション数も近似に使える）
- 音声キャッシュは「長めの 1 セッションで何 MB になるか」を実測する
  （WAV で気になるサイズなら utterance-replay 側の AAC 化オプションを発動する判断材料）

### Phase 2: 実測に基づく判断と掃除

- 見立てどおり「SwiftData が年間でも数十 MB 以下」なら**保持ポリシーは設けない**
  （全履歴保持のまま。会話履歴は資産なので消さない方針を明文化して終了）
- 確定でやる掃除: `SessionExporter` の書き出しファイルを共有完了後に削除、
  または起動時に tmp の `esl-sessions-*.json` を掃除
- 任意: ストレージ表示に音声キャッシュの「今すぐ全削除」ボタン
  （utterance-replay の削除設計の逃げ道。無くても成立する）
- usage / metrics 行が支配的で予想外に重い場合のみ、集計済み古行の間引き
  （例: 90 日より前の usage を月次集計へ畳む）を**別タスク**として起こす

## 影響範囲

- `AdminView.swift`（ストレージ表示の追加）、新規のサイズ集計ヘルパ
- `SessionExporter.swift` または `AdminView`（エクスポート残骸の削除）
- 判断結果しだいで本ドキュメントに結論を追記して archive へ

## テスト方針

- 単体: サイズ集計ヘルパ（ファイル列挙・合計・表示文字列）、tmp 掃除の対象選別
- 実機: 管理画面の表示値が Files / 設定アプリのアプリ容量と矛盾しないこと

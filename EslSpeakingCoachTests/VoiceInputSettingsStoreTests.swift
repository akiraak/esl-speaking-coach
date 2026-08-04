import XCTest
@testable import EslSpeakingCoach

/// 音声入力のしきい値の保存（docs/plans/archive/voice-input-tuning-in-admin.md Phase 1）。
@MainActor
final class VoiceInputSettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "VoiceInputSettingsStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 未設定ならコード側の既定。**画面の既定値がコードの既定と一致していること**
    /// （Float 経由の丸めで 0.01 が 0.009999… になっていないこと込み）。
    func testUnsetParametersUseCodeDefaults() {
        let store = VoiceInputSettingsStore(defaults: defaults)
        XCTAssertEqual(store.value(for: .minimumPeak), 0.01)
        XCTAssertEqual(store.value(for: .snrRatio), 3.0)
        XCTAssertEqual(store.value(for: .silenceDuration), 0.8)
        XCTAssertEqual(store.value(for: .maxSegmentDuration), 60)
        XCTAssertTrue(store.overriddenParameters.isEmpty)
        XCTAssertEqual(store.diagnosticsSummary, "既定")
    }

    /// 既定のままなら、セッションへ渡す構造体もコード既定と完全一致する
    /// （Double ⇄ Float の往復で値がずれない）。
    func testThresholdsMatchCodeDefaultsWhenUnset() {
        let store = VoiceInputSettingsStore(defaults: defaults)
        XCTAssertEqual(store.thresholds(), ClientSpeechEndpointer.Thresholds())
        XCTAssertEqual(store.levelGateThresholds(), SpeechLevelGate.Thresholds())
    }

    /// 変更は別インスタンス（= アプリ再起動）でも残り、他の項目を巻き込まない。
    func testValueSurvivesReload() {
        VoiceInputSettingsStore(defaults: defaults).setValue(0.02, for: .minimumPeak)

        let reloaded = VoiceInputSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.value(for: .minimumPeak), 0.02)
        XCTAssertEqual(reloaded.overriddenParameters, [.minimumPeak])
        XCTAssertEqual(reloaded.value(for: .silenceDuration), 0.8)
        XCTAssertEqual(reloaded.thresholds().minimumPeak, 0.02)
        // 音量 3 項目はレベルゲートにも同じ値が渡る
        XCTAssertEqual(reloaded.levelGateThresholds().minimumPeak, 0.02)
    }

    /// 既定と同じ値は保存しない（あとで既定が変わったら自動で追従させるため）。
    func testChoosingDefaultClearsTheStoredValue() {
        let store = VoiceInputSettingsStore(defaults: defaults)
        let key = VoiceInputSettingsStore.key(for: .silenceDuration)
        store.setValue(1.2, for: .silenceDuration)
        XCTAssertNotNil(defaults.object(forKey: key))

        store.setValue(0.8, for: .silenceDuration)
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertEqual(store.value(for: .silenceDuration), 0.8)
        XCTAssertEqual(store.overriddenCount, 0)
    }

    /// 範囲外の値・刻みからずれた値は読み書きの両方で丸めて収める。
    func testValuesAreClampedAndRounded() {
        let store = VoiceInputSettingsStore(defaults: defaults)
        store.setValue(99, for: .minimumPeak)
        XCTAssertEqual(store.value(for: .minimumPeak), 0.05)
        store.setValue(-1, for: .minimumPeak)
        XCTAssertEqual(store.value(for: .minimumPeak), 0.002)
        // Stepper の加算誤差（0.8 + 0.1 = 0.9000000000000001）が保存値に残らない
        store.setValue(0.9000000000000001, for: .silenceDuration)
        XCTAssertEqual(store.value(for: .silenceDuration), 0.9)

        // 手で書き換えた範囲外の保存値も読み出しで収める
        defaults.set(500.0, forKey: VoiceInputSettingsStore.key(for: .maxSegmentDuration))
        XCTAssertEqual(store.value(for: .maxSegmentDuration), 180)
    }

    func testResetToDefaultsClearsEveryParameter() {
        let store = VoiceInputSettingsStore(defaults: defaults)
        store.setValue(0.02, for: .minimumPeak)
        store.setValue(1.2, for: .silenceDuration)
        XCTAssertEqual(store.overriddenCount, 2)
        XCTAssertTrue(store.diagnosticsSummary.contains("minimumPeak=0.020"), store.diagnosticsSummary)

        store.resetToDefaults()
        XCTAssertEqual(store.overriddenCount, 0)
        XCTAssertEqual(store.thresholds(), ClientSpeechEndpointer.Thresholds())
    }

    /// 保存キーはフィールド名に揃える（変えると既存の設定が黙って既定へ戻る）。
    func testKeysFollowFieldNames() {
        XCTAssertEqual(
            VoiceInputParameter.allCases.map { VoiceInputSettingsStore.key(for: $0) },
            [
                "voiceInput.minimumPeak", "voiceInput.snrRatio", "voiceInput.unconditionalPeak",
                "voiceInput.minimumSpeechDuration", "voiceInput.silenceDuration",
                "voiceInput.lookbackDuration", "voiceInput.maxSegmentDuration",
            ])
    }

    /// 全項目がどちらかのグループにちょうど 1 回だけ現れる（画面から辿れない項目を作らない）。
    func testEveryParameterBelongsToExactlyOneGroup() {
        let listed = VoiceInputParameter.Group.allCases.flatMap(\.parameters)
        XCTAssertEqual(Set(listed), Set(VoiceInputParameter.allCases))
        XCTAssertEqual(listed.count, VoiceInputParameter.allCases.count)
    }

    /// 既定値は範囲の内側にあること（範囲を狭めたときに既定が保存不能になるのを防ぐ）。
    func testDefaultsAreInsideTheirRanges() {
        for parameter in VoiceInputParameter.allCases {
            XCTAssertTrue(
                parameter.range.contains(parameter.defaultValue),
                "\(parameter.rawValue) の既定 \(parameter.defaultValue) が範囲外")
        }
    }

    // MARK: - プリセット

    /// プリセットの値は全部レンジの内側で、刻みにも乗っていること
    /// （画面の Stepper で再現できない値をプリセットが入れない）。
    func testPresetValuesFitTheParameterRangesAndSteps() {
        for preset in VoiceInputPreset.allCases {
            for parameter in VoiceInputParameter.allCases {
                let value = preset.value(for: parameter)
                XCTAssertEqual(
                    value, parameter.clamped(value),
                    "\(preset.rawValue) の \(parameter.rawValue) が範囲外か丸め対象")
                let steps = (value - parameter.range.lowerBound) / parameter.step
                XCTAssertEqual(
                    steps, steps.rounded(), accuracy: 0.0001,
                    "\(preset.rawValue) の \(parameter.rawValue) が刻みに乗っていない")
            }
        }
    }

    /// 適用すると全項目が入り、そのプリセットに一致していると判定される。
    func testApplyingAPresetSetsEveryParameter() {
        let store = VoiceInputSettingsStore(defaults: defaults)
        XCTAssertNil(store.matchingPreset)

        store.apply(.outdoors)
        XCTAssertEqual(store.matchingPreset, .outdoors)
        XCTAssertEqual(store.value(for: .minimumPeak), 0.024)
        XCTAssertEqual(store.value(for: .maxSegmentDuration), 30)
        XCTAssertEqual(store.thresholds().snrRatio, 5.0)
        XCTAssertEqual(store.levelGateThresholds().minimumPeak, 0.024)
        XCTAssertTrue(store.diagnosticsSummary.contains("preset=外・カフェ"), store.diagnosticsSummary)

        // 1 項目でも動かせば一致しなくなる
        store.setValue(0.8, for: .silenceDuration)
        XCTAssertNil(store.matchingPreset)
    }

    /// プリセットの切り替えは前のプリセットの値を残さない。
    func testSwitchingPresetsReplacesEveryValue() {
        let store = VoiceInputSettingsStore(defaults: defaults)
        store.apply(.outdoors)
        store.apply(.quietRoom)
        XCTAssertEqual(store.matchingPreset, .quietRoom)
        for parameter in VoiceInputParameter.allCases {
            XCTAssertEqual(store.value(for: parameter), VoiceInputPreset.quietRoom.value(for: parameter))
        }
    }

    /// **どのプリセットも既定とは一致させない**（既定は「すべて既定に戻す」で戻すもの）。
    /// 一致してしまうと、既定のままの状態でプリセットのチェックが付いて紛らわしい。
    func testNoPresetEqualsTheCodeDefaults() {
        for preset in VoiceInputPreset.allCases {
            let matchesDefaults = VoiceInputParameter.allCases.allSatisfy {
                preset.value(for: $0) == $0.defaultValue
            }
            XCTAssertFalse(matchesDefaults, "\(preset.rawValue) が既定と同じ")
            XCTAssertFalse(preset.differenceSummary.isEmpty)
        }
    }

    /// 既定へ戻したらどのプリセットにも一致しない。
    func testResetClearsThePresetMatch() {
        let store = VoiceInputSettingsStore(defaults: defaults)
        store.apply(.livingNoise)
        store.resetToDefaults()
        XCTAssertNil(store.matchingPreset)
        XCTAssertEqual(store.overriddenCount, 0)
    }

    // MARK: - 直近の実測

    func testMeasurementsAreKeptNewestFirstUpToTheLimit() {
        let store = VoiceInputSettingsStore(defaults: defaults)
        let limit = VoiceInputSettingsStore.measurementLimit
        for index in 0..<(limit + 5) {
            store.record(measurement(transcript: "utterance \(index)"))
        }

        let stored = VoiceInputSettingsStore(defaults: defaults).recentMeasurements
        XCTAssertEqual(stored.count, limit)
        XCTAssertEqual(stored.first?.transcript, "utterance \(limit + 4)")
        XCTAssertEqual(stored.last?.transcript, "utterance 5")
    }

    /// レベル計測なし（nil）でも保存・復元できる。
    func testMeasurementWithoutLevelsRoundTrips() throws {
        let store = VoiceInputSettingsStore(defaults: defaults)
        store.record(SpeechSegmentMeasurement(
            levels: nil, verdict: .accepted, transcript: "hello", measuredAt: Date()))

        let stored = try XCTUnwrap(store.recentMeasurements.first)
        XCTAssertNil(stored.levels)
        XCTAssertEqual(stored.logLine, "STT セグメント 採用: レベル計測なし 「hello」")
    }

    /// 会話ログの 1 行は従来の文面のまま（採否 → 実測値 → 本文）。
    func testLogLineKeepsTheConversationLogFormat() {
        let measurement = SpeechSegmentMeasurement(
            levels: SpeechSegmentLevels(peak: 0.0123, mean: 0.0045, noiseFloor: 0.006, sampleCount: 8),
            verdict: .rejectedNearNoiseFloor, transcript: "thank you", measuredAt: Date())
        XCTAssertEqual(
            measurement.logLine,
            "STT セグメント 暗騒音との差が小さい: "
            + "peak 0.0123 / mean 0.0045 / floor 0.0060 / 比 2.0 / 8 buf 「thank you」")
    }

    func testClearMeasurements() {
        let store = VoiceInputSettingsStore(defaults: defaults)
        store.record(measurement(transcript: "hello"))
        XCTAssertFalse(store.recentMeasurements.isEmpty)
        store.clearMeasurements()
        XCTAssertTrue(store.recentMeasurements.isEmpty)
    }

    private func measurement(transcript: String) -> SpeechSegmentMeasurement {
        SpeechSegmentMeasurement(
            levels: SpeechSegmentLevels(peak: 0.05, mean: 0.02, noiseFloor: 0.005, sampleCount: 12),
            verdict: .accepted, transcript: transcript, measuredAt: Date())
    }
}

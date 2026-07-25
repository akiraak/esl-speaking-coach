import Foundation

/// STT 再接続の試行回数と待ち時間（backoff）を管理する純粋ロジック。
/// 切断のたびに nextDelay() で「次を試して良いか・何秒待つか」を判定し、
/// 接続が確立したら reset() で 1 回目から数え直す。
struct ReconnectPolicy {
    private let maxAttempts: Int
    private let delays: [TimeInterval]
    /// 現在の連続失敗中に消費した試行回数（表示用）。
    private(set) var attempt = 0

    init(maxAttempts: Int = 3, delays: [TimeInterval] = [0.5, 1.0, 2.0]) {
        precondition(maxAttempts > 0 && !delays.isEmpty)
        self.maxAttempts = maxAttempts
        self.delays = delays
    }

    /// 次の再接続を試して良ければ、試行前に待つ秒数を返す。上限に達していたら nil。
    /// delays が試行回数より短い場合は最後の値を繰り返す。
    mutating func nextDelay() -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        let delay = delays[min(attempt, delays.count - 1)]
        attempt += 1
        return delay
    }

    /// 接続が確立したら呼ぶ。次の切断はまた 1 回目から数える。
    mutating func reset() {
        attempt = 0
    }
}

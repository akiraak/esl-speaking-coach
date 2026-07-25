#!/bin/bash
# シミュレータへビルド＆インストール＆起動する。
# .secrets/anthropic-api-key（git 管理外）があれば起動時に Keychain へシードする（DEBUG ビルドのみ有効）。
# 追加の起動引数はそのまま渡せる: ./run-simulator.sh -start-conversation -send-text "Hello coach"
set -euo pipefail
cd "$(dirname "$0")"

SCHEME=EslSpeakingCoach
BUNDLE_ID=com.akiraak.EslSpeakingCoach
SIM_NAME="iPhone 17"
API_KEY_FILE=.secrets/anthropic-api-key

LAUNCH_ARGS=()
if [ -f "$API_KEY_FILE" ]; then
  API_KEY=$(tr -d '[:space:]' < "$API_KEY_FILE")
  if [ -n "$API_KEY" ]; then
    LAUNCH_ARGS+=(-seed-anthropic-key "$API_KEY")
    echo "==> $API_KEY_FILE の API キーを起動時に Keychain へシードします"
  fi
fi

echo "==> Xcode プロジェクトを生成..."
xcodegen generate

echo "==> シミュレータ向けビルド..."
xcodebuild -project EslSpeakingCoach.xcodeproj -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$SIM_NAME" build \
  | grep -E "error|BUILD" || true

APP_PATH=$(xcodebuild -project EslSpeakingCoach.xcodeproj -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$SIM_NAME" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ TARGET_BUILD_DIR =/{d=$2} / WRAPPER_NAME =/{w=$2} END{print d "/" w}')
if [ ! -d "$APP_PATH" ]; then
  echo "エラー: ビルド成果物が見つかりません: $APP_PATH" >&2
  exit 1
fi

# どれかのシミュレータが起動済みならそれを使い、無ければ $SIM_NAME を起動する
if ! xcrun simctl list devices booted | grep -q Booted; then
  echo "==> シミュレータを起動: $SIM_NAME"
  xcrun simctl boot "$SIM_NAME"
  open -a Simulator
fi

echo "==> インストール: $APP_PATH"
xcrun simctl install booted "$APP_PATH"

echo "==> 起動..."
xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch booted "$BUNDLE_ID" \
  ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"} "$@"
echo "==> 完了"

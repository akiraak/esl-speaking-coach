#!/bin/bash
# 実機 iPhone へビルド＆インストール＆起動する（無線接続で可）。
# project.yml が正なので毎回 xcodegen で .xcodeproj を生成し直してからビルドする。
set -euo pipefail
cd "$(dirname "$0")"

SCHEME=EslSpeakingCoach
BUNDLE_ID=com.akiraak.EslSpeakingCoach
API_KEY_FILE=.secrets/anthropic-api-key

# git 管理外のローカルファイルにキーがあれば、起動引数で Keychain へシードする（DEBUG ビルドのみ有効）
LAUNCH_ARGS=()
if [ -f "$API_KEY_FILE" ]; then
  API_KEY=$(tr -d '[:space:]' < "$API_KEY_FILE")
  if [ -n "$API_KEY" ]; then
    LAUNCH_ARGS+=(-seed-anthropic-key "$API_KEY")
    echo "==> $API_KEY_FILE の API キーを起動時に Keychain へシードします"
  fi
fi

echo "==> デバイスを探しています..."
DEVICE_ID=$(xcrun devicectl list devices \
  | grep -i 'available' \
  | grep -Eo '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
  | head -1)
if [ -z "$DEVICE_ID" ]; then
  echo "エラー: 利用可能な iPhone が見つかりません。同じ Wi-Fi にいるか、ロック解除されているか確認してください。" >&2
  xcrun devicectl list devices >&2
  exit 1
fi
echo "==> デバイス: $DEVICE_ID"

echo "==> Xcode プロジェクトを生成..."
xcodegen generate

echo "==> 実機向けビルド..."
xcodebuild -project EslSpeakingCoach.xcodeproj -scheme "$SCHEME" \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build \
  | grep -E "error|BUILD" || true

APP_PATH=$(xcodebuild -project EslSpeakingCoach.xcodeproj -scheme "$SCHEME" \
  -destination 'generic/platform=iOS' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ TARGET_BUILD_DIR =/{d=$2} / WRAPPER_NAME =/{w=$2} END{print d "/" w}')
if [ ! -d "$APP_PATH" ]; then
  echo "エラー: ビルド成果物が見つかりません: $APP_PATH" >&2
  exit 1
fi

echo "==> インストール: $APP_PATH"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "==> 起動..."
# アプリへの起動引数は "--" 以降に置く（devicectl 自身のオプションと区別するため）
xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID" \
  -- ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}
echo "==> 完了"

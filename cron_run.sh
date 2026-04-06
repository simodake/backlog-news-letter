#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# cron用ラッパー: 前営業日～昨日の範囲でニュースレターを生成+通知
# 祝日・土日を考慮し、休み明けはまとめて取得する
# crontab: 3 9 * * 1-5 cd /path/to/backlog-news-letter && ./cron_run.sh
#
# 祝日判定: https://holidays-jp.github.io/api/v1/date.json を使用
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# cron環境ではmiseが初期化されないため明示的にactivate
if [ -x "${HOME}/.local/bin/mise" ]; then
  eval "$("${HOME}/.local/bin/mise" activate bash)"
fi

# --- 祝日データ取得（キャッシュ: 1日1回） ---
CACHE_DIR="${SCRIPT_DIR}/.cache"
mkdir -p "$CACHE_DIR"
HOLIDAYS_CACHE="${CACHE_DIR}/holidays.json"
TODAY=$(date +%Y-%m-%d)

# キャッシュが今日のものでなければ再取得
if [ ! -f "$HOLIDAYS_CACHE" ] || [ "$(date -r "$HOLIDAYS_CACHE" +%Y-%m-%d)" != "$TODAY" ]; then
  curl -sf "https://holidays-jp.github.io/api/v1/date.json" > "$HOLIDAYS_CACHE" 2>/dev/null || true
fi

is_holiday() {
  local d="$1"
  if [ -f "$HOLIDAYS_CACHE" ]; then
    jq -e --arg d "$d" 'has($d)' "$HOLIDAYS_CACHE" >/dev/null 2>&1
  else
    return 1
  fi
}

is_weekend() {
  local dow
  dow=$(date -d "$1" +%u)
  [ "$dow" -ge 6 ]
}

is_off() {
  is_weekend "$1" || is_holiday "$1"
}

# --- 今日が祝日ならスキップ（cronは平日のみだが念のため） ---
if is_off "$TODAY"; then
  echo "本日 ${TODAY} は休日のためスキップします"
  exit 0
fi

# --- 昨日から遡って最後の営業日を探す → START_DATE ---
DATE=$(date -d yesterday +%Y-%m-%d)

# 昨日が休日なら最後の営業日まで遡る
START_DATE="$DATE"
d="$DATE"
while is_off "$d"; do
  d=$(date -d "$d - 1 day" +%Y-%m-%d)
done
START_DATE="$d"

if [ "$START_DATE" != "$DATE" ]; then
  echo "=== 休日分をまとめて取得: ${START_DATE} ~ ${DATE} ==="
fi

ADDITIONAL="${SCRIPT_DIR}/additional.txt"
if [ -f "$ADDITIONAL" ]; then
  "${SCRIPT_DIR}/generate.sh" "$DATE" "$START_DATE" < "$ADDITIONAL"
else
  "${SCRIPT_DIR}/generate.sh" "$DATE" "$START_DATE"
fi
"${SCRIPT_DIR}/notify_slack.sh" "$DATE"

#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Backlog ニュースレター生成スクリプト
# Usage: ./generate.sh PROJECT_KEY YYYY-MM-DD
#        echo "追加情報" | ./generate.sh PROJECT_KEY YYYY-MM-DD
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a; source "${SCRIPT_DIR}/.env"; set +a
fi

# 引数パース
# 形式: [PROJECT_KEY] YYYY-MM-DD [START_DATE]
#   PROJECT_KEY省略時は .env の BACKLOG_PROJECT を使用
#   START_DATE省略時は DATE と同じ（1日分）
PROJECT=""
DATE=""
START_DATE=""

date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
args=()
for arg in "$@"; do
  args+=("$arg")
done

case ${#args[@]} in
  1)
    # YYYY-MM-DD
    DATE="${args[0]}"
    ;;
  2)
    if [[ "${args[0]}" =~ $date_re ]]; then
      # YYYY-MM-DD START_DATE
      DATE="${args[0]}"
      START_DATE="${args[1]}"
    else
      # PROJECT_KEY YYYY-MM-DD
      PROJECT="${args[0]}"
      DATE="${args[1]}"
    fi
    ;;
  3)
    # PROJECT_KEY YYYY-MM-DD START_DATE
    PROJECT="${args[0]}"
    DATE="${args[1]}"
    START_DATE="${args[2]}"
    ;;
  *)
    echo "Usage: $0 [PROJECT_KEY] YYYY-MM-DD [START_DATE]" >&2
    echo "  PROJECT_KEY省略時は .env の BACKLOG_PROJECT を使用" >&2
    echo "  START_DATE指定時はその日からDATEまでの範囲を取得" >&2
    exit 1
    ;;
esac

PROJECT="${PROJECT:-${BACKLOG_PROJECT:-}}"
START_DATE="${START_DATE:-$DATE}"

if [ -z "$PROJECT" ]; then
  echo "エラー: プロジェクトキーが指定されていません" >&2
  echo "  引数で指定するか、.env に BACKLOG_PROJECT を設定してください" >&2
  exit 1
fi

# プロジェクト固有コンテキスト（context/{PROJECT}/）。存在すれば生成プロンプトに注入する。
# service.md    … サービス概要・ユーザー像・用語（全生成フェーズに注入）
# data-notes.md … コメント・変更履歴の読み方の注意（生データを直接読むフェーズのみ注入）
CONTEXT_DIR="${SCRIPT_DIR}/context/${PROJECT}"
SERVICE_CONTEXT=""
DATA_NOTES=""
if [ -f "${CONTEXT_DIR}/service.md" ]; then
  SERVICE_CONTEXT="$(cat "${CONTEXT_DIR}/service.md")"
fi
if [ -f "${CONTEXT_DIR}/data-notes.md" ]; then
  DATA_NOTES="$(cat "${CONTEXT_DIR}/data-notes.md")"
fi

# --- Step 1: 依存チェック ---
missing=0
if ! command -v bee >/dev/null 2>&1; then
  echo "エラー: bee CLI が見つかりません" >&2
  echo "  インストール: https://nulab.github.io/bee/getting-started/installation/" >&2
  missing=1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "エラー: jq が見つかりません" >&2
  echo "  インストール: https://jqlang.github.io/jq/download/" >&2
  missing=1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "エラー: node が見つかりません" >&2
  echo "  ニュースレター生成に Node.js が必要です" >&2
  missing=1
fi
if [ ! -d "${SCRIPT_DIR}/node_modules/@anthropic-ai/claude-agent-sdk" ]; then
  echo "エラー: Claude Agent SDK が未インストールです" >&2
  echo "  インストール: (${SCRIPT_DIR}で) npm install" >&2
  echo "  ※ 認証は Claude Code のログインを継承します。未ログインなら 'claude login' を実行してください" >&2
  missing=1
fi
[ "$missing" -eq 1 ] && exit 1

# --- Step 2: 初期化 ---
if ! [[ "$DATE" =~ $date_re ]]; then
  echo "エラー: 日付は YYYY-MM-DD 形式で指定してください" >&2
  exit 1
fi
if ! [[ "$START_DATE" =~ $date_re ]]; then
  echo "エラー: 開始日は YYYY-MM-DD 形式で指定してください" >&2
  exit 1
fi

OUTPUT_DIR="${SCRIPT_DIR}/${DATE}/backlog"
NEWS_DIR="${SCRIPT_DIR}/${DATE}"
mkdir -p "$OUTPUT_DIR"

# 標準入力から追加情報を読み取り（パイプがあれば）
ADDITIONAL_FILE="${NEWS_DIR}/additional.txt"
if [ ! -t 0 ]; then
  cat > "$ADDITIONAL_FILE"
  if [ ! -s "$ADDITIONAL_FILE" ]; then
    rm -f "$ADDITIONAL_FILE"
  else
    echo "=== 追加情報を読み込みました ==="
  fi
fi

# Backlog APIの日時はUTC。生成プロンプトでは朝会（10:00-10:30）等の時刻を根拠に
# コメントの性質を判断させるため、出力する日時は日本時間のISO形式に揃える。
# jq用: 日時文字列（null可）を +09:00 表記に変換する定義。各フィルタの先頭に連結して使う
JQ_JST='def jst: if . == null then null else (fromdateiso8601 + 32400 | strftime("%Y-%m-%dT%H:%M:%S+09:00")) end;'

# シェル変数用: UTCの日時文字列を +09:00 表記に変換する（空文字はそのまま）
to_jst() {
  [ -n "$1" ] || return 0
  TZ=Asia/Tokyo date -d "$1" +%Y-%m-%dT%H:%M:%S%:z 2>/dev/null || echo "$1"
}

# --- Step 3: issue一覧取得（ページネーション対応） ---
fetch_all_issues() {
  local since="$1" until="$2" project="$3" filter_type="$4"
  local offset=0 count=100 batch
  local all_issues="[]"

  while true; do
    batch=$(bee issue list -p "$project" \
      "--${filter_type}-since" "$since" \
      "--${filter_type}-until" "$until" \
      --json -L "$count" --offset "$offset" 2>/dev/null) || batch="[]"

    local batch_len
    batch_len=$(echo "$batch" | jq 'length')

    if [ "$batch_len" -eq 0 ]; then
      break
    fi

    all_issues=$(echo "$all_issues" "$batch" | jq -s '.[0] + .[1]')
    offset=$((offset + count))

    if [ "$batch_len" -lt "$count" ]; then
      break
    fi
  done

  echo "$all_issues"
}

RANGE_LABEL="${START_DATE}"
[ "$START_DATE" != "$DATE" ] && RANGE_LABEL="${START_DATE} ~ ${DATE}"

echo "=== issue取得中 (updated: ${RANGE_LABEL}) ==="
UPDATED_ISSUES=$(fetch_all_issues "$START_DATE" "$DATE" "$PROJECT" "updated")

echo "=== issue取得中 (created: ${RANGE_LABEL}) ==="
CREATED_ISSUES=$(fetch_all_issues "$START_DATE" "$DATE" "$PROJECT" "created")

ALL_ISSUES=$(echo "$UPDATED_ISSUES" "$CREATED_ISSUES" | jq -s '.[0] + .[1] | unique_by(.issueKey)')
ISSUE_COUNT=$(echo "$ALL_ISSUES" | jq 'length')
echo "=== 対象issue: ${ISSUE_COUNT}件 ==="

if [ "$ISSUE_COUNT" -eq 0 ]; then
  echo "対象issueが0件のため終了します。"
  exit 0
fi

# --- Step 4 & 5: 各issue詳細取得 → カテゴリー別ファイル書き出し ---
declare -A PARENT_CACHE

fetch_parent_info() {
  local parent_id="$1"
  if [ -n "${PARENT_CACHE[$parent_id]+x}" ]; then
    echo "${PARENT_CACHE[$parent_id]}"
    return
  fi
  local parent_json
  parent_json=$(bee api "/api/v2/issues/${parent_id}" --json 2>/dev/null) || parent_json="{}"
  local parent_key parent_summary
  parent_key=$(echo "$parent_json" | jq -r '.issueKey // "不明"')
  parent_summary=$(echo "$parent_json" | jq -r '.summary // "取得失敗"')
  PARENT_CACHE[$parent_id]="${parent_key}: ${parent_summary}"
  echo "${parent_key}: ${parent_summary}"
}

for i in $(seq 0 $((ISSUE_COUNT - 1))); do
  issue=$(echo "$ALL_ISSUES" | jq ".[$i]")

  issue_key=$(echo "$issue" | jq -r '.issueKey')
  summary=$(echo "$issue" | jq -r '.summary')
  status=$(echo "$issue" | jq -r '.status.name')
  assignee=$(echo "$issue" | jq -r '.assignee.name // "未割り当て"')
  parent_id=$(echo "$issue" | jq -r '.parentIssueId // empty')
  category=$(echo "$issue" | jq -r 'if (.category | length) > 0 then .category[0].name else "未分類" end')
  issue_type=$(echo "$issue" | jq -r '.issueType.name // ""')
  priority=$(echo "$issue" | jq -r '.priority.name // ""')
  # 期限日は日付のみのフィールド（APIはT00:00:00Zで返す）なので時刻・TZは付けない
  due_date=$(echo "$issue" | jq -r '.dueDate // "" | .[0:10]')
  created_date=$(to_jst "$(echo "$issue" | jq -r '.created // empty')")
  updated_date=$(to_jst "$(echo "$issue" | jq -r '.updated // empty')")
  # 課題の説明。「なぜやるか・誰の課題か」の根拠になるため冒頭を抜粋して含める
  description=$(echo "$issue" | jq -r '
    (.description // "") as $d |
    if ($d | length) > 800 then $d[0:800] + "…(以下省略)" else $d end')

  # カテゴリーファイルパス（ファイル名不正文字を置換）
  safe_category=$(echo "$category" | tr '/' '_')
  cat_file="${OUTPUT_DIR}/${safe_category}.txt"

  # 親課題情報
  parent_info=""
  if [ -n "$parent_id" ]; then
    parent_info=$(fetch_parent_info "$parent_id")
  fi

  # コメント・変更履歴取得（期間内のみフィルタ）
  all_comments=$(bee api "/api/v2/issues/${issue_key}/comments" \
    -f count=100 -f order=asc --json 2>/dev/null) || all_comments="[]"

  # 期間の絞り込みも日本時間の日付境界で行う（issue一覧の取得条件と基準を揃える）
  comments=$(echo "$all_comments" | jq --arg s "$START_DATE" --arg e "$DATE" "
    ${JQ_JST}
    [.[] | select(.content != null and .content != \"\") |
     (.created | jst) as \$c |
     select(\$c[0:19] >= (\$s + \"T00:00:00\") and \$c[0:19] <= (\$e + \"T23:59:59\")) |
     { author: .createdUser.name, content: .content, created: \$c }]")

  changes=$(echo "$all_comments" | jq --arg s "$START_DATE" --arg e "$DATE" "
    ${JQ_JST}
    [.[] | select(.changeLog | length > 0) |
     (.created | jst) as \$c |
     select(\$c[0:19] >= (\$s + \"T00:00:00\") and \$c[0:19] <= (\$e + \"T23:59:59\")) |
     { author: .createdUser.name, created: \$c,
       changes: [.changeLog[] | select(.field != \"notification\") |
         { field: .field, from: .originalValue, to: .newValue }] } |
     select(.changes | length > 0)]")

  # ファイルに追記
  {
    echo "================================================================"
    echo "課題: ${issue_key}"
    echo "タイトル: ${summary}"
    echo "種別: ${issue_type}"
    echo "ステータス: ${status}"
    echo "優先度: ${priority}"
    echo "担当者: ${assignee}"
    [ -n "$due_date" ] && echo "期限日: ${due_date}"
    [ -n "$parent_info" ] && echo "親課題: ${parent_info}"
    echo "作成日: ${created_date}"
    echo "最終更新: ${updated_date}"
    echo ""

    if [ -n "$description" ]; then
      echo "--- 課題の説明（抜粋） ---"
      echo "$description"
      echo ""
    fi

    change_count=$(echo "$changes" | jq 'length')
    if [ "$change_count" -gt 0 ]; then
      echo "--- この期間の変更履歴 (${change_count}件) ---"
      echo "$changes" | jq -r '.[] | "[\(.created)] \(.author):" + (.changes | map("  \(.field): \(.from // "なし") → \(.to // "なし")") | join("\n"))'
      echo ""
    fi

    comment_count=$(echo "$comments" | jq 'length')
    if [ "$comment_count" -gt 0 ]; then
      echo "--- この期間のコメント (${comment_count}件) ---"
      echo "$comments" | jq -r '.[] | "[\(.created)] \(.author):\n\(.content)\n"'
    fi

    if [ "$change_count" -eq 0 ] && [ "$comment_count" -eq 0 ]; then
      echo "--- この期間の変更・コメント: なし ---"
    fi
    echo ""
  } >> "$cat_file"

  echo "  [${i}/${ISSUE_COUNT}] ${issue_key} → ${safe_category}"
  sleep 0.3
done

# --- Step 6: カテゴリーごとに Claude Agent SDK (npm run gen:category) でニュースレター生成 ---
echo ""
echo "=== ニュースレター生成中 ==="

SPACE_NAME="${BACKLOG_SPACE_NAME:-}"
if [ -z "$SPACE_NAME" ]; then
  echo "警告: BACKLOG_SPACE_NAME が .env に設定されていません。課題リンクが生成できません。" >&2
fi

# 追加情報の生値（プロンプトへの組み込みは各生成アプリ側で行う）
ADDITIONAL_INFO=""
if [ -f "$ADDITIONAL_FILE" ]; then
  ADDITIONAL_INFO="$(cat "$ADDITIONAL_FILE")"
fi

PERIOD_LABEL="$DATE"
if [ "$START_DATE" != "$DATE" ]; then
  PERIOD_LABEL="${START_DATE} ~ ${DATE}"
fi

for txt in "${OUTPUT_DIR}"/*.txt; do
  [ -f "$txt" ] || continue
  cat_name=$(basename "$txt" .txt)
  news_file="${NEWS_DIR}/${cat_name}news.md"

  echo "  生成中: ${cat_name}news.md ..."
  cat "$txt" | CATEGORY_NAME="$cat_name" PERIOD_LABEL="$PERIOD_LABEL" \
    SPACE_NAME="$SPACE_NAME" ADDITIONAL_INFO="$ADDITIONAL_INFO" \
    SERVICE_CONTEXT="$SERVICE_CONTEXT" DATA_NOTES="$DATA_NOTES" \
    npm run --silent gen:category \
    > "$news_file"
done

# --- Step 7: 全体サマリ生成 ---
OVERVIEW_DIR="${NEWS_DIR}/overview"
mkdir -p "$OVERVIEW_DIR"
SUMMARY_FILE="${NEWS_DIR}/news.md"

echo ""
echo "=== 全体サマリ生成中 ==="

# Step 7-1: カテゴリ別ニュースレターを overview に集約
echo "  Step 7-1: カテゴリ別ニュースレターを集約 ..."
: > "${OVERVIEW_DIR}/categories.md"
for news in "${NEWS_DIR}"/*news.md; do
  [ -f "$news" ] || continue
  cat_name=$(basename "$news" news.md)
  echo "## Backlogカテゴリ: ${cat_name}" >> "${OVERVIEW_DIR}/categories.md"
  echo "" >> "${OVERVIEW_DIR}/categories.md"
  cat "$news" >> "${OVERVIEW_DIR}/categories.md"
  echo "" >> "${OVERVIEW_DIR}/categories.md"
done

# Step 7-2: ドラフト生成（リリース情報・ピックアップの選定）
echo "  Step 7-2: 主要イベントのピックアップ ..."
cat "${OVERVIEW_DIR}/categories.md" | PERIOD_LABEL="$PERIOD_LABEL" \
  SPACE_NAME="$SPACE_NAME" ADDITIONAL_INFO="$ADDITIONAL_INFO" \
  SERVICE_CONTEXT="$SERVICE_CONTEXT" \
  npm run --silent gen:draft \
  > "${OVERVIEW_DIR}/draft.md"

# Step 7-3: ドラフトで言及されたチケットの詳細情報を overview に取得
echo "  Step 7-3: ピックアップチケットの詳細取得 ..."
picked_keys=$(grep -oP '[A-Z][A-Z0-9_]+-\d+' "${OVERVIEW_DIR}/draft.md" | sort -u)

for key in $picked_keys; do
  detail_file="${OVERVIEW_DIR}/${key}.md"
  [ -f "$detail_file" ] && continue

  issue_json=$(bee api "/api/v2/issues/${key}" --json 2>/dev/null) || continue

  all_comments=$(bee api "/api/v2/issues/${key}/comments" \
    -f count=100 -f order=asc --json 2>/dev/null) || all_comments="[]"

  {
    echo "# ${key}: $(echo "$issue_json" | jq -r '.summary')"
    echo ""
    echo "- 種別: $(echo "$issue_json" | jq -r '.issueType.name // ""')"
    echo "- ステータス: $(echo "$issue_json" | jq -r '.status.name')"
    echo "- 優先度: $(echo "$issue_json" | jq -r '.priority.name // ""')"
    echo "- 担当者: $(echo "$issue_json" | jq -r '.assignee.name // "未割り当て"')"
    echo "- 期限日: $(echo "$issue_json" | jq -r 'if .dueDate then .dueDate[0:10] else "なし" end')"
    echo "- 作成日: $(to_jst "$(echo "$issue_json" | jq -r '.created')")"
    echo "- 最終更新: $(to_jst "$(echo "$issue_json" | jq -r '.updated')")"
    parent_id=$(echo "$issue_json" | jq -r '.parentIssueId // empty')
    if [ -n "$parent_id" ]; then
      echo "- 親課題: $(fetch_parent_info "$parent_id")"
    fi
    echo ""

    desc=$(echo "$issue_json" | jq -r '.description // ""')
    if [ -n "$desc" ]; then
      echo "## 説明"
      echo "$desc"
      echo ""
    fi

    echo "## 変更履歴"
    echo "$all_comments" | jq -r "
      ${JQ_JST}
      [.[] | select(.changeLog | length > 0) |
       { author: .createdUser.name, created: (.created | jst),
         changes: [.changeLog[] | select(.field != \"notification\") |
           { field: .field, from: .originalValue, to: .newValue }] } |
       select(.changes | length > 0)] |
      if length == 0 then \"なし\"
      else .[] | \"[\(.created)] \(.author)\n\" +
        (.changes | map(\"  \(.field): \(.from // \"なし\") → \(.to // \"なし\")\") | join(\"\n\"))
      end"
    echo ""

    echo "## コメント"
    echo "$all_comments" | jq -r "
      ${JQ_JST}
      [.[] | select(.content != null and .content != \"\")] |
      if length == 0 then \"なし\"
      else .[] | \"[\((.created | jst))] \(.createdUser.name):\n\(.content)\n\"
      end"
  } > "$detail_file"

  echo "    取得: ${key}"
  sleep 0.3
done

# Step 7-4: overview 内の全データから最終版 news.md を生成
echo "  Step 7-4: 最終版 news.md 生成 ..."
cat "${OVERVIEW_DIR}/draft.md" "${OVERVIEW_DIR}"/*_*.md 2>/dev/null | \
  SPACE_NAME="$SPACE_NAME" \
  SERVICE_CONTEXT="$SERVICE_CONTEXT" DATA_NOTES="$DATA_NOTES" \
  npm run --silent gen:summary \
  > "$SUMMARY_FILE"

echo ""
echo "=== 完了 ==="
echo "Backlogデータ: ${OUTPUT_DIR}/"
for f in "${NEWS_DIR}"/*news.md "${SUMMARY_FILE}"; do
  [ -f "$f" ] && echo "ニュースレター: $f"
done

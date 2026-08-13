// 最終版 news.md 生成アプリ（旧 generate.sh Step 7-4 の `claude -p` 相当）。
// stdin: draft.md + ピックアップチケットの詳細情報の連結
// env:   SPACE_NAME, SERVICE_CONTEXT, DATA_NOTES
import { runApp } from './lib/runQuery.mjs';
import { buildContextPrompt } from './lib/contextPrompt.mjs';

const spaceName = process.env.SPACE_NAME ?? '';
const spacePrompt = spaceName ? `SPACE_NAMEは「${spaceName}」です。` : '';
// チケット詳細（全コメント）を直接読むフェーズなので DATA_NOTES も注入する
const contextPrompt = buildContextPrompt({ includeDataNotes: true });

runApp((input) => {
  return `以下はドラフトサマリとピックアップチケットの詳細情報です。これらを基に、全体サマリガイドラインに沿って最終版のニュースレターを生成してください。
【リリース情報】本番リリース済み（「リリース完了」「リリースしました」「本番反映済み」「デプロイ完了」等）のもののみ。「開発完了」「QA完了」「リリース準備完了」等の本番リリース前フェーズ完了はピックアップへ。技術的な変更内容だけでなく、何が良くなるか・期待できるKPI改善にも触れること。
【カテゴリ名】Backlogのカテゴリ名をそのまま使うこと。
【ピックアップ】5項目以内に厳選すること。
ファイル操作は不要です。Markdown本文だけを出力してください。${spacePrompt}${contextPrompt}

${input}`;
});

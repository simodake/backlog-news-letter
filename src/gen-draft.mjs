// 全体サマリのドラフト生成アプリ（旧 generate.sh Step 7-2 の `claude -p` 相当）。
// リリース情報・ピックアップの選定を行う。
// stdin: categories.md（カテゴリ別ニュースレターの集約）
// env:   PERIOD_LABEL, SPACE_NAME, ADDITIONAL_INFO
import { runApp } from './lib/runQuery.mjs';

const periodLabel = process.env.PERIOD_LABEL ?? '';
const spaceName = process.env.SPACE_NAME ?? '';
const additionalInfo = process.env.ADDITIONAL_INFO ?? '';

const spacePrompt = spaceName ? `SPACE_NAMEは「${spaceName}」です。` : '';
const additionalPrompt = additionalInfo
  ? `\n\n## 追加情報（Backlog以外）\n${additionalInfo}`
  : '';

runApp((input) => {
  return `以下は${periodLabel}の各カテゴリーのニュースレターです。これらを基に、全体サマリガイドラインに沿ってドラフトを生成してください。
【リリース情報の判定基準】本番環境にリリース済みのもののみ含めること。「リリース完了」「リリースしました」「リリース済み」「本番反映済み」「本番反映しました」「デプロイ完了」「デプロイしました」等はリリース済み。一方「開発完了」「実装完了」「テスト完了」「QA完了」「リリース準備完了」など本番リリース前のフェーズ完了はリリース情報ではなくピックアップに含めること。
【カテゴリ名】ピックアップのカテゴリ名は入力データの見出しに含まれているBacklogのカテゴリ名をそのまま使うこと。独自に読み替えないこと。
【ピックアップ】5項目以内に厳選すること。
課題キーは必ずそのまま含めてください。ファイル操作は不要です。Markdown本文だけを出力してください。${spacePrompt}${additionalPrompt}

${input}`;
});

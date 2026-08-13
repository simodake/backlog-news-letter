// プロジェクト固有コンテキスト（context/{PROJECT_KEY}/）のプロンプト組み立て。
// generate.sh がファイルを読んで環境変数で渡す:
// - SERVICE_CONTEXT: service.md（サービス概要・ユーザー像・用語）。全フェーズで注入する
// - DATA_NOTES:      data-notes.md（コメント・変更履歴の読み方の注意）。
//                    Backlogの生データを直接読むフェーズ（gen-category / gen-summary）のみ注入する。
//                    gen-draft の入力は生成済みニュースレターなので不要
export function buildContextPrompt({ includeDataNotes = false } = {}) {
  const serviceContext = process.env.SERVICE_CONTEXT ?? '';
  const dataNotes = process.env.DATA_NOTES ?? '';

  let prompt = '';
  if (serviceContext) {
    prompt += `\n\n## サービスコンテキスト\n${serviceContext}`;
  }
  if (includeDataNotes && dataNotes) {
    prompt += `\n\n## 入力データの読み方の注意\n${dataNotes}`;
  }
  return prompt;
}

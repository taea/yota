#!/usr/bin/env ruby
# frozen_string_literal: true

# 「与太話」素朴 SSG — hibi（わしの日々）の build.rb の弟分
#
#   esa/{記事番号}.html.md  →  dist/e{記事番号}/index.html
#   一覧 = dist/index.html（日付降順） / RSS = dist/feed.xml（最新20件）
#
# 荷物は esa の GitHub Webhook が ShipIt 時に押し込んでくる（category: claude code/与太話）
#   - YAML frontmatter: title / category / tags / created_at / updated_at / published / number
#   - published: true を二重ガードで確認（WIP は webhook も来ないが念のため）
#   - slug は e{記事番号}: タイトルを後から直しても URL が動かない
#   - 日付: タイトル末尾の YYYY-MM-DD が最優先。無ければ created_at の営業日（朝4時区切り）
#
# 本文の約束事（/yota スキルの書式）:
#   - 冒頭の引用 = 前口上
#   - **taea:** / **🦀:** / **Claude:** で始まる段落から次の話者までが一人の手番 → 吹き出し
#   - 手番の外にある ## 見出しは地の文に戻る
#
# 使い方: bundle exec ruby build.rb   （ESA_DIR=preview/esa で手元の見本を焼ける）

require "commonmarker"
require "fileutils"
require "date"
require "time"
require "cgi"
require "yaml"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

SITE_TITLE = "カニ秘書との与太話"
SITE_DESC  = "taea とカニ（AI エージェント）が仕事の合間に交わした、役に立たないかもしれない話の蔵出し。"
SITE_URL   = "https://yota.kani.show"
ROOT       = __dir__
ESA_POSTS  = File.expand_path(ENV.fetch("ESA_DIR", "esa"), ROOT)
DIST       = File.join(ROOT, "dist")

MD_OPTS = {
  options: {
    render: { unsafe: true, hardbreaks: true }, # esa と同じく改行はそのまま改行
    extension: { table: true, strikethrough: true, autolink: true, tasklist: true, footnotes: true },
  },
  plugins: { syntax_highlighter: nil },
}.freeze

def md(src) = Commonmarker.to_html(src, **MD_OPTS)
def h(str)  = CGI.escapeHTML(str.to_s)

# --- 話者 ------------------------------------------------------------------

SPEAKERS = {
  "taea"   => :human,
  "🦀"     => :crab,
  "Claude" => :crab,
  "カニ"   => :crab,
}.freeze
SPEAKER_RE = /\A\*\*(#{SPEAKERS.keys.map { Regexp.escape(_1) }.join("|")})\s*[:：]\*\*\s*/

# 本文を「地の文」と「手番」の列に割る
#   [[:prose, md], [:turn, speaker, md], ...]
def split_turns(body)
  blocks = []
  current = [:prose, nil, +""]
  in_fence = false

  flush = lambda do
    blocks << current unless current[2].strip.empty?
  end

  body.each_line do |line|
    in_fence = !in_fence if line.start_with?("```", "~~~")

    if !in_fence && (m = line.match(SPEAKER_RE))
      flush.call
      current = [:turn, m[1], +line.sub(SPEAKER_RE, "")]
    elsif !in_fence && current[0] == :turn && line.match?(/\A(\#{1,2} |(-{3,}|\*{3,}|_{3,})\s*\z)/)
      # 大見出し・区切り線 → 手番はそこまで。地の文に戻る（手番の中の ### はそのまま吹き出しの中）
      flush.call
      current = [:prose, nil, +line]
    else
      current[2] << line
    end
  end
  flush.call
  blocks.flat_map { |b| b[0] == :turn ? peel_note(b) : [b] }
end

# 手番の末尾にある引用 = /yota が書き添えた地の注釈。吹き出しから剥がして「注」にする
def peel_note(turn)
  kind, speaker, src = turn
  paras = src.strip.split(/\n{2,}/)
  notes = []
  notes.unshift(paras.pop) while paras.size > 1 && paras.last.lines.all? { _1.start_with?(">") }
  return [turn] if notes.empty?

  [[kind, speaker, paras.join("\n\n")], [:note, nil, notes.join("\n\n")]]
end

Post = Struct.new(:number, :date, :title, :lede, :body_md, :tags, keyword_init: true) do
  def slug = "e#{number}"
  def path = "/#{slug}/"
  def url  = "#{SITE_URL}#{path}"

  def turns = @turns ||= split_turns(body_md)
  def turn_count = turns.count { _1[0] == :turn }

  def html
    turns.map { |kind, speaker, src|
      next %(<div class="prose">#{md(src)}</div>) if kind == :prose
      next %(<aside class="note"><span class="note-label">注</span><div>#{md(src.gsub(/^>\s?/, ""))}</div></aside>) if kind == :note

      side = SPEAKERS.fetch(speaker)
      avatar = side == :crab ? CRAB_SVG : %(<span class="me">taea</span>)
      <<~HTML
        <div class="turn turn-#{side}">
          <div class="who" aria-label="#{h(speaker)}">#{avatar}</div>
          <div class="bubble">#{md(src)}</div>
        </div>
      HTML
    }.join("\n")
  end

  # 一覧・RSS 用のひと口
  def excerpt
    txt = lede.to_s.gsub(/[*_`]/, "").gsub(/\s+/, " ").strip
    txt.size > 110 ? "#{txt[0, 110]}…" : txt
  end
end

def load_posts
  Dir.glob(File.join(ESA_POSTS, "*.md")).filter_map do |file|
    raw = File.read(file).gsub("\r\n", "\n") # esa は CRLF 混じりで来ることがある
    m = raw.match(/\A---\n(.*?)\n---\n/m)
    next warn("skip (frontmatter なし): #{File.basename(file)}") unless m

    fm = YAML.safe_load(m[1], permitted_classes: [Time, Date])
    next warn("skip (未公開): #{File.basename(file)}") unless fm["published"]
    next warn("skip (記事番号なし): #{File.basename(file)}") unless fm["number"]

    raw_title = fm["title"].to_s.strip
    next if raw_title == "README" # カテゴリの説明書きは与太話じゃねぇ
    date = if (dm = raw_title.match(/(\d{4}-\d{2}-\d{2})/))
             Date.parse(dm[1])
           else
             (Time.parse(fm["created_at"].to_s) - 4 * 3600).to_date
           end
    # 表示タイトルからは末尾の日付と #タグ を落とす（日付は別枠で出す）
    title = raw_title.sub(/(\s+#\S+)+\z/, "").sub(/[:：]\s*\d{4}-\d{2}-\d{2}\s*\z/, "").strip

    body = raw[m[0].size..].strip
    # 冒頭の引用ブロック = 前口上。本文からは抜いて別枠で出す
    lede = nil
    if (lm = body.match(/\A((?:>.*\n?)+)/))
      lede = lm[1].gsub(/^>\s?/, "").strip
      body = body[lm[0].size..].strip
    end
    # 「## 会話ログ」見出しは吹き出しで一目瞭然なので落とす
    body = body.sub(/\A##\s*会話ログ\s*\n/, "").strip

    tags = Array(fm["tags"]).map(&:to_s).reject(&:empty?)
    Post.new(number: fm["number"].to_i, date:, title:, lede:, body_md: body, tags:)
  end
end

# --- 部品 ------------------------------------------------------------------

CRAB_SVG = File.read(File.join(ROOT, "assets", "crab.svg")).strip

def layout(title:, body:, path: "/", description: SITE_DESC, og_type: "website")
  <<~HTML
    <!doctype html>
    <html lang="ja">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{h(title)}</title>
    <meta name="description" content="#{h(description)}">
    <meta property="og:title" content="#{h(title)}">
    <meta property="og:description" content="#{h(description)}">
    <meta property="og:site_name" content="#{SITE_TITLE}">
    <meta property="og:type" content="#{og_type}">
    <meta property="og:url" content="#{SITE_URL}#{path}">
    <meta name="twitter:card" content="summary">
    <link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
    <link rel="alternate" type="application/rss+xml" title="#{SITE_TITLE}" href="/feed.xml">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=DotGothic16&family=BIZ+UDPGothic:wght@400;700&display=swap">
    <link rel="stylesheet" href="/assets/style.css">
    </head>
    <body>
    <header class="noren">
      <div class="wrap">
        <a class="brand" href="/">#{CRAB_SVG}<span>与太話</span></a>
        <nav aria-label="案内">
          <a href="/">一覧</a>
          <a href="https://kani.show/">長屋</a>
          <a href="/feed.xml">RSS</a>
        </nav>
      </div>
    </header>
    <main class="wrap">
    #{body}
    </main>
    <footer>
      <div class="wrap">
        <p class="sns">
          <a href="https://kani.show/">カニ省の長屋</a>
          <a href="https://taea.kani.show/">わしの日々</a>
          <a href="https://bsky.app/profile/kani.show">@kani.show</a>
        </p>
        <p class="credit">書き手: taea と長屋のカニ達<br>esa で ShipIt されたものだけが、ここに並ぶ</p>
      </div>
    </footer>
    </body>
    </html>
  HTML
end

def render_post(post, prev_post, next_post)
  tags = post.tags.map { %(<span class="tag">##{h(_1)}</span>) }.join
  pager = [
    next_post && %(<a class="newer" href="#{next_post.path}"><small>新しい話</small>#{h(next_post.title)}</a>),
    prev_post && %(<a class="older" href="#{prev_post.path}"><small>古い話</small>#{h(prev_post.title)}</a>),
  ].compact.join
  body = <<~HTML
    <article class="yota">
      <header class="yota-head">
        <p class="eyebrow"><time datetime="#{post.date.iso8601}">#{post.date.strftime("%Y.%m.%d")}</time> — 与太 ##{post.number}</p>
        <h1>#{h(post.title)}</h1>
        #{%(<p class="tags">#{tags}</p>) unless tags.empty?}
      </header>
      #{%(<aside class="lede"><span class="lede-label">前口上</span>#{md(post.lede)}</aside>) if post.lede}
      <div class="talk">
    #{post.html}
      </div>
      <p class="fin">おあとがよろしいようで 🦀</p>
    </article>
    <nav class="pager" aria-label="前後の話">#{pager}</nav>
  HTML
  layout(title: "#{post.title} | #{SITE_TITLE}", body:, path: post.path,
         description: post.excerpt.empty? ? SITE_DESC : post.excerpt, og_type: "article")
end

def render_index(posts)
  items = posts.map { |p|
    <<~HTML
      <li>
        <a href="#{p.path}">
          <time datetime="#{p.date.iso8601}">#{p.date.strftime("%Y.%m.%d")}</time>
          <b>#{h(p.title)}</b>
          #{%(<span>#{h(p.excerpt)}</span>) unless p.excerpt.empty?}
          <small>#{p.turn_count.zero? ? "随筆" : "#{p.turn_count} 手"}</small>
        </a>
      </li>
    HTML
  }.join
  body = <<~HTML
    <section class="intro">
      <p class="eyebrow">YOTA.KANI.SHOW — カニ省・与太話係</p>
      <h1>カニ秘書との与太話</h1>
      <p>仕事の合間、朝の支度のついで、寝る前のひとこと。taea と長屋のカニ（AI エージェント）が交わした、脱線と寄り道の記録だ。</p>
    </section>
    <ol class="yota-list">
    #{items}</ol>
  HTML
  layout(title: SITE_TITLE, body:)
end

def render_feed(posts)
  items = posts.first(20).map do |p|
    <<~ITEM
      <item>
        <title>#{h(p.title)}</title>
        <link>#{p.url}</link>
        <guid>#{p.url}</guid>
        <pubDate>#{p.date.to_time.rfc822}</pubDate>
        <description><![CDATA[#{p.lede ? md(p.lede) : ""}#{p.html}]]></description>
      </item>
    ITEM
  end.join
  <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel>
      <title>#{SITE_TITLE}</title>
      <link>#{SITE_URL}</link>
      <description>#{h(SITE_DESC)}</description>
      #{items}
    </channel></rss>
  XML
end

# --- build ---
posts = load_posts.sort_by { [_1.date, _1.number] }.reverse
FileUtils.rm_rf(DIST)
FileUtils.mkdir_p(DIST)

posts.each_with_index do |post, i|
  dir = File.join(DIST, post.slug)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "index.html"), render_post(post, posts[i + 1], i.zero? ? nil : posts[i - 1]))
end

File.write(File.join(DIST, "index.html"), render_index(posts))
File.write(File.join(DIST, "feed.xml"), render_feed(posts))
File.write(File.join(DIST, "404.html"),
           layout(title: "404 | #{SITE_TITLE}",
                  body: %(<section class="intro"><h1>404</h1><p>その与太話はまだ話してないか、お蔵に入っちまったかだ。<a href="/">一覧に戻る</a></p></section>)))
FileUtils.cp_r(File.join(ROOT, "assets"), DIST)

puts "✅ build 完了: 与太話 #{posts.size} 本 → dist/（荷受け口: #{ESA_POSTS.delete_prefix("#{ROOT}/")}）"

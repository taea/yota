#!/usr/bin/env ruby
# frozen_string_literal: true

# 過去の与太話を esa/ に詰め替える（webhook 開通前の Shipped 分の初期投入用）
#
#   夜番の esa 写し（~/.claude/esa-backup/taea/claude code/与太話/*.md）
#     → esa/{記事番号}.html.md（esa GitHub webhook と同じ frontmatter 形）
#
#   - wip: false（Shipped）だけ運ぶ
#   - 先に ~/.claude/scripts/esa-backup.sh で写しを最新にしておくこと
#   - 一度入れたら以後は webhook が上書きしてくれる。再実行しても同じ結果（冪等）
#
# 使い方: ruby tools/backfill.rb [写しのディレクトリ]

require "yaml"
require "fileutils"
require "time"

SRC = ARGV[0] || File.expand_path("~/.claude/esa-backup/taea/claude code/与太話")
DST = File.expand_path("../esa", __dir__)
FileUtils.mkdir_p(DST)

n = 0
Dir[File.join(SRC, "*.md")].sort_by { File.basename(_1).to_i }.each do |file|
  raw = File.read(file)
  m = raw.match(/\A---\n(.*?)\n---\n/m) or next warn("skip (frontmatter なし): #{file}")
  fm = YAML.safe_load(m[1])
  next if fm["wip"]

  front = {
    "title" => fm["title"],
    "category" => fm["category"],
    "tags" => fm["tags"] || [],
    "created_at" => Time.parse(fm["created_at"]).strftime("%Y-%m-%d %H:%M:%S %z"),
    "updated_at" => Time.parse(fm["updated_at"]).strftime("%Y-%m-%d %H:%M:%S %z"),
    "published" => true,
    "number" => fm["number"],
  }
  body = raw[m[0].size..].sub(/\A\n+/, "")
  File.write(File.join(DST, "#{fm["number"]}.html.md"), "#{front.to_yaml}---\n#{body}")
  n += 1
end
puts "📦 #{n} 本を esa/ に詰め替えた（写し: #{SRC}）"

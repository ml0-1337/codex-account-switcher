#!/usr/bin/env ruby

require "cgi"

readme_path = File.expand_path("../README.md", __dir__)
readme = File.read(readme_path, encoding: "UTF-8")
transcript = readme[/```text\n(\$ codex-switch\n.*?)\n```/m, 1]
abort "README.md must contain a codex-switch terminal example" unless transcript

lines = transcript.lines.map(&:chomp)
height = 136 + lines.length * 32
terminal_text = lines.each_with_index.map do |line, index|
  "    <text x=\"56\" y=\"#{116 + index * 32}\">#{CGI.escapeHTML(line)}</text>"
end.join("\n")

puts <<~SVG
  <svg xmlns="http://www.w3.org/2000/svg" width="1120" height="#{height}" viewBox="0 0 1120 #{height}" role="img" aria-labelledby="title description">
    <!-- Generated from README.md by scripts/render-terminal-demo.rb. -->
    <title id="title">codex-switch の操作例</title>
    <desc id="description">架空のアカウント personal@example.com から work@example.com を選ぶ表示例。切り替え後はアプリを手動で再起動します。</desc>
    <defs>
      <linearGradient id="background" x2="1" y2="1">
        <stop stop-color="#243447"/>
        <stop offset="1" stop-color="#0c1421"/>
      </linearGradient>
    </defs>
    <rect width="1120" height="#{height}" rx="20" fill="url(#background)"/>
    <rect x="24" y="30" width="1072" height="#{height - 54}" rx="13" fill="#05090f" fill-opacity="0.4"/>
    <rect x="24" y="24" width="1072" height="#{height - 48}" rx="13" fill="#111821" stroke="#3a4757"/>
    <path d="M24 80H1096" stroke="#2a3543"/>
    <circle cx="52" cy="52" r="6" fill="#ff6057"/>
    <circle cx="74" cy="52" r="6" fill="#febc2e"/>
    <circle cx="96" cy="52" r="6" fill="#28c840"/>
    <text x="560" y="58" text-anchor="middle" fill="#9eabbc" font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-size="17">codex-switch</text>
    <g fill="#e6edf3" font-family="Menlo, Consolas, 'Hiragino Kaku Gothic ProN', 'Noto Sans Mono CJK JP', monospace" font-size="22" xml:space="preserve">
  #{terminal_text}
    </g>
  </svg>
SVG

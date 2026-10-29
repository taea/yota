// yota.kani.show の門番 — Accept: text/markdown で来たエージェントには esa 原文の md を出す
//   /e1100/  →  /e1100/index.md（build.rb が焼いたもの）
//   それ以外の客には今まで通り static assets の HTML
// run_worker_first で "/"・"/index.md"・"/e*" だけここを通る（assets/・feed.xml などは素通し）

const wantsMarkdown = (req) =>
  /\btext\/markdown\b/i.test(req.headers.get("Accept") || "");

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (wantsMarkdown(request) && (request.method === "GET" || request.method === "HEAD")) {
      const mdUrl = new URL(url);
      mdUrl.pathname = url.pathname.replace(/\/?$/, "/") + "index.md";
      const res = await env.ASSETS.fetch(new Request(mdUrl, { method: request.method }));
      if (res.ok) {
        const headers = new Headers(res.headers);
        headers.set("Content-Type", "text/markdown; charset=utf-8");
        headers.set("Vary", "Accept");
        headers.set("Access-Control-Allow-Origin", "*");
        return new Response(res.body, { status: 200, headers });
      }
    }

    const res = await env.ASSETS.fetch(request);
    const headers = new Headers(res.headers);
    headers.append("Vary", "Accept");
    // 本番の assets は .md を charset 無しの text/markdown で出す → ブラウザで化ける
    if (url.pathname.endsWith(".md") && res.ok) {
      headers.set("Content-Type", "text/markdown; charset=utf-8");
    }
    return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
  },
};

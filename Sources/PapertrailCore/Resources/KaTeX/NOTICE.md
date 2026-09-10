# KaTeX 0.18.7

- Upstream: https://github.com/KaTeX/KaTeX/releases/tag/v0.18.7
- Download: https://cdn.jsdelivr.net/npm/katex@0.18.7/dist/katex.min.js
- License: MIT, included as LICENSE
- katex.min.js SHA-256: 10a91b479cd927446ceb60409fb0d72b5d0d05eaf446c9e52fafd64058c84540

Vendored with user approval on 2026-09-10. Papertrail runs renderToString in
JavaScriptCore with output=mathml, trust=false, and bounded expansion/size.
The chat WebView receives static markup, disables page JavaScript, and does
not fetch this file or any fonts, scripts, or styles from the network.

Options: https://katex.org/docs/options
Security: https://katex.org/docs/security

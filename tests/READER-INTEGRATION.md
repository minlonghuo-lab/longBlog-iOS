# Native reader integration

## Project integration

The project's `project.yaml` includes **ImageIO** and bundles the **Reader directory itself**, preserving nested files. Keep sources `[src/*.m]` (already picks up `LBPostReader.m`):

```yaml
frameworks: [UIKit, Foundation, CoreGraphics, QuartzCore, Security, UserNotifications, BackgroundTasks, WebKit, ImageIO]
resources: [resources/*.png, resources/Reader]
```

`ios-dev/scripts/mk.py` copies directory resources recursively into `LongBlogInbox.app/Reader/`. Preserve `Reader/vendor/fonts/`; KaTeX CSS uses relative font URLs. There is no Info.plist font registration requirement (fonts are WebKit-only) and no ATS exception, Swift, CDN script, or new entitlement.

## Source layout

`src/LBContent.m` imports `LBPostReader.h`; article selection instantiates the native reader class. `src/LBPostReader.h/.m`, `resources/Reader/`, and the reader-specific tests implement the feature. Shared list layout remains provided by `LBGlassTable`/`LBLayout.h`.

## Content contract and security

Inspected `src/data/trilium-posts.content.generated.ts`, `trilium-posts.meta.generated.ts`, `math-render.ts`, `sanitize-content.ts`, `posts.ts`, and `docs/trilium-rendering-contract.md`. The actual generated content contains CKEditor `figure.table` with percentage widths and colgroups, `language-text-x-*` code, `.math-tex` with embedded delimiters, `/trilium-assets/` images, and `.include-note-card[data-note-id]` links such as `/blog/2epdE8sgosX8/`. The repository documents the upstream link transformation as deployed automation (`longblog-automation/service/sync_trilium_posts.py`), not a local module; no missing module was invented.

Production template contains no script tags and CSP `script-src 'none'`. Pinned KaTeX and renderer execute as WKUserScripts in the **LongBlogReader isolated content world**. Raw article HTML is passed using `callAsyncJavaScript` arguments, never interpolated into executable source/template. An inert template is parsed and a new tree is built using explicit tag/attribute/style allowlists; scripts, events, frames, arbitrary styles, SVG/MathML from articles and forged controls are discarded. KaTeX-generated SVG/MathML is trusted output with `trust:false`, fresh per-formula macros, and expansion/size limits.

Bridge checks the sending webview, main frame, exact bundled file URL, fixed handler name, 3-key dictionary schema, string types, per-reader random nonce, action allowlist and payload bounds. Interaction requires a trusted DOM event. Copy goes to the clipboard only; post action IDs must match `LBSiteData.shared.posts`. Network navigation in the WKWebView is cancelled. HTTPS links dispatch through the native URL handler; known internal articles push this native reader. Missing internal blog posts show a sync suggestion. Internal reference lookup supports ID/slug, `/blog/`, `data-note-id`, `#root/...`, `/notes/` and `/api/notes/` forms. No credentials or API objects enter JavaScript or logging.

Images are restricted to the configured site's HTTPS origin. Fullscreen native UIScrollView supports pinch/double-tap zoom, close and retry. Ephemeral unauthenticated downloads reject cross-origin redirects, non-image/SVG responses and payloads above **12 MiB**, including unknown-length streaming bodies. ImageIO downsampling decodes only frame 0 at **2560px maximum dimension**. The native image decoder does not create a full-size UIImage from raw data.

## Verification

```sh
npm install --prefix /tmp/lb-reader-tests --no-audit --no-fund jsdom@26.1.0
NODE_PATH=/tmp/lb-reader-tests/node_modules node --test ios/LongBlogInbox/tests/reader.test.cjs
clang -target arm64-apple-ios26.0 \
  -isysroot /root/.ios-sdk/iPhoneOS26.5.sdk \
  -F /root/.ios-sdk/iPhoneOS26.5.sdk/System/Library/SubFrameworks \
  -fobjc-arc -Wall -Wno-unused-parameter -Wno-nullability-completeness \
  -fsyntax-only ios/LongBlogInbox/src/LBPostReader.m ios/LongBlogInbox/src/LBContent.m
```

Both Objective-C files passed with zero warnings/errors. DOM suite: **8 passed, 0 failed**, rendering all **18 actual generated posts**, **76 formulas, 24 tables, 92 code blocks, 96 local-site images, 2 internal article cards**. Tests additionally cover math delimiters/prices/code exclusions, malicious HTML and URL schemes, source-preserving copy, synthetic-event bridge rejection, real card target mapping, oversized/deep HTML and native safeguard assertions.

`build-reader-preview.cjs` generates `reader-preview.html` from real article fragments. Browser inspected at 390x844 in dark appearance: document width exactly 390px; table containers 358px wide with independent scroll widths 421px and 391px; code toolbar and internal card visually render. Browser screenshots: `minis://browser/screenshot_1793759951.jpg` and `minis://browser/screenshot_1793760006.jpg`. This harness intentionally uses page scripts and a recording callback for layout only; **it is not the production native bridge and is not an app runtime screenshot**.

## Limitations / device checks still required

No app installation/runtime test has been performed. Resource/framework integration is in `project.yaml`; final linking and packaging are covered by `tools/build_local.py`. On-device verify isolated-world handshake with production CSP, native navigation/safe area, genuine taps/clipboard, native fullscreen preview, rotation, dark/light changes and retry. Browser automation's synthetic element clicks are intentionally rejected, so they do not verify native clipboard or push navigation.

Inline WebKit images are lazy/async HTTPS loads but do not share the native viewer's 12 MiB byte cap; WebKit controls their decoding/cache. External-origin images, non-HTTPS/mailto/custom-scheme links, article scripts, video/iframes, author SVG and custom article CSS are deliberately unsupported. Mermaid 12.2.0 is bundled as an isolated trusted script and rebuilt into inert data-SVG images; source directives, links/callbacks, user CSS, external resources and in-diagram math are rejected. Failed/oversized diagrams keep copyable source. Animation in native preview shows frame 0. Complex or unsupported LaTeX falls back to source. Article HTML over 4 MiB, >50,000 nodes or depth >100 fails with retry/error UI; formulas beyond limits fall back to text. KaTeX and all font assets total approximately 1.5 MiB locally.

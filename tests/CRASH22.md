# 2.2 crash diagnosis and regression scope

Two user-supplied iOS reports from 2.1 / build 14 have the same main-thread signature:

```
EXC_BREAKPOINT / SIGTRAP
CFGetTypeID
CA::Render::copy_render_array
-[CABasicAnimation _setCARenderAnimation:layer:]
CA::Layer::commit_animations
CA::Transaction::commit / flush
```

The reports contain no application frame identifying the property or animation that supplied the array. They are NOT evidence of an upload failure, JavaScript exception, out-of-memory kill, or proof of one specific UIKit defect. Raw reports are intentionally not included in this repository (device/user identifiers).

The source risk most closely matching the user action was changing `tabBarMinimizeBehavior` AND calling `tabBar.layoutIfNeeded` inside the navigation coordinator's live animation. This also allowed a completion for an old navigation stack to apply policy to a newly selected tab.

2.2 removes forced layout and all minimize mutation from live navigation callbacks; completion/didShow coalesce one next-main-queue reconciliation based on the currently selected stack. A cancelled return retains article-only scroll minimization; a completed return restores the full tab bar. The previous custom finger-progress animation is intentionally not retained: crash safety takes priority, and there is no public API here that guarantees the same minimization animation.

A separate article-image preview state race is corrected by confining NSURLSession mutable state to main, decoding an immutable data copy on a worker queue, and rejecting stale decode results after retry/dismissal.

Offline source/event-order tests and real SDK compilation do not reproduce Core Animation's runtime crash. Device acceptance must include repeated expanded/collapsed article returns, partial/cancelled return, fast tab switch during transition, reduced motion, and no new matching crash report. Version 2.3 supersedes 2.2's HEIC/HEIF preservation policy: new still-photo imports prepare JPEG, and this also needs a real picker/upload check.

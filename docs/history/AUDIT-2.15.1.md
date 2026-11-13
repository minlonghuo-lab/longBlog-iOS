# longBlog iOS 2.15.1（build 49）排查与修复

## 基线和范围

- 2026-11-13 从 GitHub 最新 main `7e71875044d424802b12a3d98f7387685c1c7e67` 拉取，原版本 2.15.0 build 48。
- 修复分支：`fix/native-performance-and-editor-20261113`。
- 只修改 `ios/LongBlogInbox/` 原生项目及其本地 Reader、测试；未修改站点布局、云端文章、后端或真实工作区。
- 未混入之前未合并的本地修复分支。保持玻璃胶囊、卡片、菜单、配色和整体导航；可见调整仅为用户要求的标题级别与代码块。

## 已修复

### 用户反馈

1. **格式面板**：二级标题 `##`、三级标题 `###`、四级标题 `####`，同步修正选中高亮；正文按钮保留。
2. **等宽改为代码块**：空选区、单行和多行选择都插入 fenced code block，不再根据选区自动变成行内代码；不默认标注 Objective-C。围栏自动避开选区已有反引号，保持嵌套 Markdown 内容。行内代码图标保留。
3. **AI 点击路径**：菜单配置检测移到后台读取 Keychain，UI 菜单仍回主线程创建；请求准备和 JSON 序列化移出主线程。结果页展示动画结束后再开始生成。
4. **AI 流式输出**：50ms 合并 delta、最多一个待执行主线程 flush，减少 token 逐个引发的布局和滚动；用户拖动/惯性滚动时不抢滚动。

### 高优先级正确性问题

- **空白行列表闪退**：仅空白字符的段落切换列表时，原逻辑可能把 NSNotFound 传给 substringToIndex。现安全保留缩进。编号列表必须有真实 regex match 才视为已编号，修复首次切换不生效。
- **编辑器发布/下架假成功**：保存文本不负责状态变更。现在先保存文本，再显式 stagePublish/stageUnpublish，检查失败并保留旧状态，不再提前修改内存状态后直接提示成功。
- **AI 自定义指令丢文**：过去可能只将长选区前 3 万字符发送给模型，却替换整个选区。现在超限拒绝替换型请求；全文仅供参考的插入请求仍允许截断参考。
- **SSE 协议和资源上界**：线性扫描新字节，处理跨分片 UTF-8、CR/LF/CRLF、多行 data、EOF 尾部和 DONE。取消在准备、启动、delta 和完成投递各阶段生效；完成最多一次。对响应、事件、长行和输出设硬限制，避免无限内存增长。
- **批量提交可靠性**：统一 articleTask 互斥；PATCH 前持久 pending，重启先只读核验，确认 applied 后恢复，不自动重发；状态损坏、缺失正文/附件、非 UTF-8、暂存变化和无安全远端基线均阻断整批，避免部分上传被提示成功。
- **并发编辑保护**：上传后的本地 apply 复核正文、侧件和附件摘要；变动时保留整批本地内容，记录真实远端基线并返回冲突。不吞掉本地写入、清理和状态保存错误。保留有效 HTML 保真侧件，不盲删未安全认领的文件。
- **元数据漏提交**：语义基线包含标题、摘要、标签等，只忽略保存时钟 updatedAt，避免正文不变时把元数据修改误判成已同步。
- **说说冷启动**：缓存不等于已验证身份；未验证时先进入已有验证刷新路径，补齐云端检查去重和过期回调隔离。
- **缩略图重复解码**：原先下载已缓存、解码也已在后台；本次真正新增的是解码后的图片缓存、重复请求合并、两路并发解码和账号隔离。NSCache 设置 128 项/24MiB 建议限额（不是进程内存硬上限）。
- **卡片徽章**：不再按临时 320pt 宽度永久删除徽章，改为隐藏溢出项并在最终宽度变化时恢复，避免宽屏/旋转后徽章丢失。
- **视频全屏生命周期**：追踪自定义全屏控制器的关闭，退出/销毁时拆除播放器引用；拒绝重复或过期展开，移除展示完成后无条件重新播放。
- **音频会话**：移除 DuckOthers，暂停、结束、打断、拔耳机和拆除时归还会话；按播放器所有权清理远程控制，不让离屏卡片清空另一个播放器的状态；只移除自己的命令 target。
- **阅读器媒体隔离**：私密说说预览不生成 audio/video/source；文章只允许本地能力 URL 或站点同源媒体，阻止第三方媒体预加载请求，保留本地文章媒体播放。

## 验证

### 完整原生回归，干净 main 对照

SDK 重复编译型测试单独去重；不改测试函数的业务断言，真正的全量 SDK 编译由完整 App 构建承担。可执行的 host-C fixtures 正常执行。

| 项目 | main | 修复版 |
|---|---:|---:|
| 发现测试 | 469 | 521 |
| 通过 | 447 | 497 |
| 失败 | 7 | 7 |
| 错误 | 1 | 1 |
| 跳过（含去重 SDK/可选项） | 14 | 16 |

无新增失败/错误。原有失败项保留，不能宣称“全套全绿”：

- test_article_refresh.ArticleRefreshContracts.test_pull_downloads_articles_not_deploy_status
- test_article_ui212.ArticleUI212.test_down_confirmation_finishes_dismissal_before_local_validation
- test_article_ui212.ArticleUI212.test_swipe_completes_immediately_and_reports_async_result
- test_config18.Config18Contracts.test_native_glass_and_self_sizing_card_finish
- test_local_first_ui.LocalFirstUI.test_cache_seed_and_background_poll_do_not_grant_identity
- test_memos_counts_order.CountsOrder.test_count_is_full_snapshot_not_first_thirty
- test_visual17.Visual17Contracts.test_draft_does_not_synthesize_epoch_or_slug
- test_interaction_contracts.InteractionContracts.test_dismissal_freezes_then_commits_latest_snapshot（error）

既有测试中与本次明确改变的实现绑定的断言已同步：标题名称、发布状态切换时序、AI 取消 token、可追踪全屏控制器、可逆徽章布局、带错误检查的批量任务写回。未用注释或死代码迎合旧断言。

### Reader DOM

- 新增 reader-safety2151：4/4，通过真实 jsdom 执行生产 Reader JS。
- article-reader：main 5/9 → 修复版 7/9；修复第三方媒体与私密说说隔离两项。余下两项是既有原生媒体呈现/源码契约不匹配。
- reader-parity：main 与修复版均 10/11；网站 CSS 提取一致性用例仍为原有失败。

### 构建

- 30 个 Objective-C 文件，iPhoneOS26.5.sdk，arm64 iOS26。
- `-Wall -Wextra -Werror`，30 个非空对象文件，链接与打包成功。
- IPA 内 Info.plist 为 2.15.1 / 49，ZIP 校验通过。
- ad-hoc 仅结构校验，分发文件名仍为 unsigned；需要用户自行签名，不能直接安装。

## 仍建议改进，未在本次冒进重构

1. 文章保存、附件导入/持久化、草稿恢复及批量最终落盘仍有同步文件 I/O；File Provider 与大附件下可能造成停顿。下一步应以 Instruments/真机时间点测量为依据，将整条文件事务迁移到统一串行队列，而不是零碎并发移动造成读写竞态。
2. 说说只嗅探最新一条不能保证发现旧记录编辑/删除；后续需支持服务端 revision，或低频完整核验。没有把这个能力描述为“实时严格一致”。
3. 跨进程 File Provider 在最终校验后改写的 TOCTOU 仍存在；需要评估 NSFileCoordinator，不能靠应用内互斥宣称解决外部编辑。
4. 原有基线红测应单独核对契约、建立可靠运行时覆盖。当前许多测试是源码/模型，不等同 UIKit、Foundation 网络或 AVFoundation 端到端运行。

## 真机验收清单

- 第一次/连续打开 AI 菜单；生成中关闭、重开、重试；弱网失败；长结果手动滚动不被拉回。
- 三种标题切换与撤销；空白行编号/任务清单；单行、多行及嵌套围栏代码块。
- 新文章暂存发布、已发布文章暂存下架、失败提示；批量前后手动编辑内容、断网/重启恢复 pending。
- 九宫格来回快速滚动；卡片窄屏到宽屏/旋转后徽章恢复。
- 视频全屏关闭后切页；音频暂停/离页、来电、拔耳机和其它音乐 App 的会话恢复。

本次未安装真机、未测 FPS/卡顿时长、未真实写入 AI/GitHub/Memos 接口。构建和静态/离线测试不能证明设备体验已经完全修复。

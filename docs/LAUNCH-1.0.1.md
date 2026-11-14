# 1.0.1（build 2）启动排查与验证

日期：2026-11-15。基线：独立仓库 main `7a747593b8dc2b84bedf99a822b5a198d57fc2fd`。
用户反馈：启动慢、黑屏，并有概率启动闪退。

## 已确认的源码问题，不等于已取得用户崩溃根因

1. `LBDashboard.viewDidLoad → LBSiteData.refreshAll → refreshPosts → LBMdStore.shared.listArticles` 同步解析目录书签、枚举并读取完整文章。这条主线程路径会延迟首屏，外部文件提供器/大工作区可能放大影响；是否触发 watchdog 必须以设备日志证明。
2. 场景在 `makeKeyAndVisible` 之前同步调用 `LBAPI.configured` / `LBGitHub.configured`，涉及 Keychain 系统服务；并提前创建所有入口的 controller/navigation controller，显式访问导航栏。不能因此断言 UIKit 一定加载了所有根视图。
3. frontmatter 会把 `publish: [true]`、`pinned: []`、`singleSourceVersion: [1]` 解析为数组，后续数值消息有 `unrecognized selector` 条件性崩溃路径。尚未证明用户的文章实际存在这种格式。

## 本轮修改

- 使用只包含纸色背景和活动指示器的启动 controller；在其出现后，在后台查询用于选择默认入口的配置，再在主线程安装 tab。无固定延时，不等待网络。
- 首屏选页保持旧语义：仅配置留言时落在留言，否则仪表盘。冷启动通知会话在过渡期间暂存，消费 scene connection 的通知响应。场景断开后丢弃迟到初始化结果，清理观察者。
- 使用 UITab provider 首次需要时创建并保存导航栈，导航 delegate 仍交给同一个 chrome controller，弱引用避免循环。不访问未选页面的 navigationBar。
- 首页不在 viewDidLoad 启动刷新；首次可见/前台时执行一次初始刷新，周期监控仍只有轻量部署检查。
- 文章统计在专用串行队列扫描。独立只读 store 使用捕获的 bookmark，独立持有安全作用域至扫描结束，不改书签、不创建目录、不触碰编辑/同步单例。主线程只发布结果，校验连接 generation、请求 revision 和当前 bookmark；废弃结果仍完成调用方回调，避免 refreshAll group 挂起。
- 解析器对上述数值字段中的非字符串/数字类型回退为内存中的 0，不自动写盘，不把畸形 publish 数组解释成自动发布。既有正确标量、正文与 HTML 字节处理不变。
- 不改整体五入口样式、文章/说说编辑流程、说说详情原有渲染交接和远端业务写入。

## 验证

### 自动化回归

使用相同 runner 策略对干净 main worktree 与修复版比较，保留所有非 SDK 行为测试。仅跳过重复 SDK 纯编译测试；Node 嵌套调用超时统一放宽到 300 秒，避免 iSH 启动抖动。未启用真实个人笔记或上游站点 opt-in。

| 范围 | 基线 | 修复版 |
| --- | --- | --- |
| Python（含 memos-client 子目录） | 600：573 通过、7 失败、1 错误、19 跳过 | 608：581 通过、7 失败、1 错误、19 跳过 |
| 全部 9 个独立 DOM 测试文件 | 54：52 通过、2 失败 | 54：52 通过、2 失败 |

8 项新增启动源码契约全部通过。没有新增失败 ID。独立复核还发现并修正了书签变化后初始扫描被丢弃但无补扫的问题：只允许当前 generation/revision 的最新请求在书签变化时补扫，旧请求的 completion 仍只执行一次。

四项旧源码形状约束随本轮改动更新：后台独立 store、provider 中设置 delegate、导航构造不要求局部变量名、初始刷新和周期任务分开。没有删除或改写既有基线失败来伪造全绿。

既有 Python 失败：文章下拉同步旧契约；旧发布确认与侧滑文字契约两项；配置页大标题局部契约；留言后台 30/60 秒旧契约；说说快照计数切片契约；阅读日期赋值形状契约。既有 error：interaction test 假设 LBContent 中每个 implementation 都有搜索方法。DOM 两项失败仍是 article-reader 旧媒体节点契约和 reader-parity 原生源码契约。

### 原生编译与打包

从新 clone 的空 build 目录开始，全量串行编译全部 30 个 Objective-C 源文件；没有复制或复用旧工程对象。启用 `-Wall -Wextra -Werror`，链接、结构签名、IPA 打包成功。包内版本 1.0.1 / 2，Bundle ID 保持 `com.huowenlong.longblog.inbox`。

`tests/LaunchMetadataFixtures.m` 直接包含生产实现并严格编译为 arm64 Mach-O 对象；需要 iOS runner 调用 `LBRunLaunchMetadataFixtures()` 才执行 Foundation 断言。本轮未运行该原生 fixture，Python 源码契约/host fixture/DOM 不能替代 UIKit 真机运行。

### 设备取证边界

只读崩溃日志提取在连接 `10.7.0.1:49152` 时被拒绝，尚未进入设备崩溃库，没有取得本次 `.ips`。未安装覆盖、未启动/终止用户 app、未修改证书或配对配置。

因此：未测首帧 P50/P95、总启动耗时、峰值内存或闪退概率；未验证启动过渡是否有视觉闪动；不能声称解决所有黑屏或所有启动闪退。系统进程创建之前的 launch screen 配置仍为原来的 `UILaunchScreen: {}`，轻量启动背景仅覆盖 app 自己建立窗口之后的阶段。

## 遗留候选，不在本轮扩大修改

- 其他配置/请求/身份检查仍有同步 Keychain 读取，不能说“所有钥匙串访问都已异步化”。
- 首页公开说说快照的清洗排序仍在主线程，未做大快照接收上界改造。
- 说说附件下载流在主队列落盘，以及大缓存资源索引的主线程开销，需要单独验证；未选中说说页时不能直接归为本次首屏根因。
- 后台刷新 expiration 的完成标志跨队列风险、磁盘 tagList schema 边界为独立后续项，未顺手重构。

## 真机验收建议

1. 用自己的有效证书签名后覆盖安装，先备份文章/草稿，不要为测试卸载现有 app。
2. 反复彻底退出后冷启动，覆盖无配置、仅留言、全部配置；本地目录/外部文件提供器；离线/慢网；小/大工作区。
3. 检查原先默认入口、五入口首次访问/返回后的状态，以及通过通知从终止状态打开会话。
4. 如仍退出，导出同时间的 `LongBlogInbox*.ips`（包括 watchdog/Jetsam 相关报告），结合版本与触发线程判断，而不是继续凭黑屏症状猜根因。

本地分支：`fix/launch-latency-and-stability-20261115`。不自动推送、PR 或合并。

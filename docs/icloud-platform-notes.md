# 普通 iCloud Drive 目录的平台核对

2026-11-14。供后续 iCloud 接入使用；本轮只查 Apple 原始资料、SDK 和临时类型检查，不实现 App，不接触用户 iCloud 内容、账号或权限。既有 [catalog 契约](publishing-studies.md)与 [Shelf 职责](study-shelf-interface.md)不变。

## 本机 SDK 证据

本机为 Xcode 27.2（27B52），iPhoneOS 与 macOS SDK 均为 27.2。所有工具调用单独指定 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，没有修改全局 `xcode-select`。

下列别名指向实际 SDK 文件，后文给出行号：

| 别名 | 本机原始文件 |
| --- | --- |
| IURL | [iOS NSURL.h](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSURL.h) |
| PICK | [UIDocumentPickerViewController.h](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/UIKit.framework/Headers/UIDocumentPickerViewController.h) |
| COORD | [NSFileCoordinator.h](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSFileCoordinator.h) |
| FM | [NSFileManager.h](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSFileManager.h) |
| META | [NSMetadata.h](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSMetadata.h) |
| OPEN | [macOS NSOpenPanel.h](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Headers/NSOpenPanel.h) |
| PROVIDER | [NSFileProviderManager.h](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/FileProvider.framework/Headers/NSFileProviderManager.h) |

## iPhone / iPad：选择与持久授权

**直接事实。** iOS 13 起，`UIDocumentPickerViewController` 支持选择目录，授权包括递归子目录和之后新增内容。iOS 17 可用 `UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)`；`asCopy: false` 访问原目录，不能用一次复制替代持续研究库关联。`directoryURL` 只是初始显示位置，不是目录授权或 provider 限制。PICK:43–48、72–73；[Apple：目录访问](https://developer.apple.com/documentation/uikit/providing-access-to-directories)。

**直接事实。** Apple 的目录专用示例在取得访问后用 `.minimalBookmark` 保存书签，之后解析书签并检查 `bookmarkDataIsStale`。不要保存路径字符串来替代授权。目录内容读写需要 security-scoped 访问及文件协调；成功取得的访问要配对释放。[Apple：目录访问及书签示例](https://developer.apple.com/documentation/uikit/providing-access-to-directories)。

| 选项 | SDK availability | 本方案含义 |
| --- | --- | --- |
| 创建 `.minimalBookmark` | iOS 可用，IURL:754 | 使用 iOS 目录专用示例的形状 |
| 创建 `.withSecurityScope` | macOS 10.7+、Mac Catalyst 13+；**原生 iOS 不可用**，IURL:758 | 不可照抄进 iPhone/iPad 分支 |
| 创建 `.securityScopeAllowOnlyReadAccess` | 同上，IURL:762 | 不是 iOS 的目录只读开关 |
| 解析 `.withSecurityScope` | macOS 10.7+、Mac Catalyst 13+；**原生 iOS 不可用**，IURL:781 | iOS 解析不用此选项 |
| 解析 `.withoutUI` | iOS 可用，IURL:777 | 可用于非交互恢复；需要重选时由应用显式展示 picker |

**文档差异。** `UIDocumentPickerViewController` 的部分 [overview](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller) 文案仍建议 `.withSecurityScope`，与实际 SDK availability、目录专用示例冲突。Apple DTS 也明确说明 iOS 省略这些 macOS 选项；不能以该 overview 为由使用 iOS 不可编译的选项。[Apple DTS：iOS 书签与平台差异](https://developer.apple.com/forums/thread/772143)。

**直接事实与限制。** stale 表示应更新书签，不等于已经永久失权；解析、取访问、实际读写都可能失败。可访问的 stale URL 可以生成新书签替换旧值；无法恢复访问时需重新选目录。授权仍由用户控制，不能承诺“选过一次永不失效”。[Apple：书签解析参数](https://developer.apple.com/documentation/foundation/url/init(resolvingbookmarkdata:options:relativeto:bookmarkdataisstale:)-3ic6f)、[Apple：目录权限变化](https://developer.apple.com/documentation/uikit/providing-access-to-directories)。

Apple DTS 在 2025 年还记录过目录书签跨卷重新挂载失败、首次枚举意外为空，以及 iOS 上 `startAccessing` 返回值与实际可访问性不完全吻合的案例；本轮未确认这些缺陷在各系统版本的修复状态。**实现推论：** 不把一次空枚举或单独一个 `false` 直接解释成研究被删除/授权永久撤销；保留实际协调访问的错误，交 Shelf 决定重试或重新关联，不在 adapter 写死补偿循环。[Apple DTS：iOS folder bookmarks](https://developer.apple.com/forums/thread/797469)。

书签作为本机授权资料保存，不作为跨设备个人阅读记录；另一设备仍需取得自己的目录授权。这是授权接入建议，不更改研究库或阅读记录格式。

## 内容准备：协调读取，目录存在不等于原件可读

**直接事实。** 普通文件 I/O、存在性检查和枚举都可能因 iCloud Drive 或其他 provider 而长时间阻塞；不能放在主线程。`NSFileCoordinator` 的普通内容读取会等待未下载文件，async `coordinate(with:queue:byAccessor:)` 可使用后台 operation queue。COORD:228–250；[Apple：文件系统性能与协调访问](https://developer.apple.com/documentation/foundation/improving-performance-and-stability-when-accessing-the-file-system)。

**直接事实。** accessor 必须检查协调错误，使用系统交回的 URL（或 intent 更新后的 URL），并在 accessor 内完成对外部文件的读取/复制；不能返回后再派发任务继续使用该外部 URL。`.immediatelyAvailableMetadataOnly` 不等待内容下载，也不允许据此读取完整内容。`cancel()` 可取消等待，已运行的 accessor 则要完成。COORD:31–34、228–250、323–326；[Apple：异步协调方法](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate(with:queue:byaccessor:))。

**直接事实。** `FileManager.startDownloadingUbiquitousItem(at:)` 可请求云端文件或目录下载，返回只表示已开始或无需开始，不是全部字节准备完成。文档没有将此方法限定为 app 自有 ubiquity container；但它也不是所有 File Provider 的通用下载管理器。FM:800–808；[Apple：请求下载](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:))。iCloud 下载状态可用 IURL:681–716 的 `.ubiquitousItemDownloadingStatusKey`；旧 `.ubiquitousItemIsDownloadedKey` 已弃用，新实现应使用 downloading status。

**直接事实。** `NSFileProviderManager` 面向 provider extension 及关联进程；并非严格“只能在 extension 内调用”，但你的普通阅读 App 不是 iCloud provider 的管理进程。查找不属于自己 provider/domain 的文件 identifier 会失败；其 request-download 回调也不等于下载完成，目录请求不递归物化全部孩子。PROVIDER:33–49、133–136、553–571；[Apple：NSFileProviderManager](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager)。消费用户选定目录不需要自建 File Provider extension。

**实现建议。** adapter 在授权及协调访问期间，把请求文件复制到 App 自有 staging；返回本机副本，PDFKit 不持有已经释放授权的外部 URL。Shelf 按既有 catalog → snapshot/resource manifest → 全部声明文件核对，不从目录枚举成功、下载请求被接受或单个状态键推断整包就绪。摘要、来源声明、版本选择及失败重试仍在 Shelf；协调读取也不是整个目录跨 iCloud 的原子事务。

## 发现与前台刷新

**直接事实。** `NSMetadataQueryUbiquitousDocumentsScope/DataScope` 指 app 自有 ubiquity container；不是任意用户选定目录。另有 `AccessibleUbiquitousExternalDocumentsScope`，可找到用户曾通过 picker 打开的 iCloud 外部文档，但不能据此承诺枚举整个任意 File Provider。META:197–202；[Apple：外部文档查询 scope](https://developer.apple.com/documentation/foundation/nsmetadataqueryaccessibleubiquitousexternaldocumentsscope)。`url(forUbiquityContainerIdentifier:)` 同样是 app container 接口，不能替代已选普通目录，FM:822–832。

**直接事实。** file presenter 观察协调访问产生的变化；低层直接读写不保证发 presenter 通知。iOS 自行注册的 presenter 在退后台时应移除，回前台再注册，避免阻塞其他进程。[Apple：NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter)、[Apple：NSFileCoordinator 生命周期](https://developer.apple.com/documentation/foundation/nsfilecoordinator)。

**实现建议。** 首版按已确认要求，在启动、前台 `.active`、主动刷新时重读固定 `catalog.json` 并枚举独立 records 区。可选 presenter/query 只发出“值得刷新”的提示，不能取代全量对账或保证实时通知。Mac 发布工具使用普通文件系统操作，因此不能依赖它必定触发 presenter。`scenePhase` 在 View 中对应该 scene，在 App 中是多 scene 聚合；刷新去重/打开意图由 Shelf 处理。[Apple：ScenePhase](https://developer.apple.com/documentation/swiftui/scenephase)。

## macOS 原生预览的不同之处

**直接事实。** 原生 AppKit 可用 `NSOpenPanel`（`canChooseDirectories=true`、`canChooseFiles=false`、单选），SwiftUI `fileImporter` 也是选项；Mac Catalyst 则使用 UIKit picker。sandboxed macOS 的用户选定文件权限、显式 security-scoped bookmark 与原生 iOS 的 sandbox/选项不同。因为同目录中还要写个人记录，macOS 后续不能给整个根目录只读授权后又期待写 records；研究包只读由 adapter 的写入范围与 Shelf 规则保证。[Apple：macOS App Sandbox 文件访问](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)、OPEN:27–55。

macOS panel 首次交回 URL 时系统已自动开始访问；持久书签恢复的 URL 则需要显式 start/stop。初次选择和后续恢复应各自按平台语义释放访问，不能机械共用同一个计数假设。[Apple：macOS 选择与持久访问](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)。

`NSOpenPanel.canDownloadUbiquitousContents` 控制是否由 panel 尝试准备非本机内容；false 时允许选非本机内容，下载与进度由应用处理。选中目录不是递归下载所有 PDF 的保证。OPEN:51–55；[Apple：panel 下载行为](https://developer.apple.com/documentation/appkit/nsopenpanel/candownloadubiquitouscontents)。

当前 [Mac 预览脚本](../ios/CompanyLens/Tools/build_mac_preview.sh) 生成原生 `.app` 并临时签名，没有传入 sandbox entitlement。预览中直接路径可用不能证明 iOS 或 sandboxed macOS 的持久授权通过；本轮没有修改其签名、权限或运行设置。

## 窄 CloudFolder Interface 建议

以下仅是传输 seam 的形状，不提前采用具体签名。系统 picker 只在 App/Platform 中生成/更新本机书签；Library 定义 Interface，生产 adapter 与脚本化测试 adapter 满足它，不向 Core 引入 UIKit/AppKit。

```text
restoreAccess(bookmarkData) -> AccessUpdate(replacementBookmark?)
list(relativeDirectory) -> [Entry(relativePath, kind)]
copyFile(relativePath, toLocalStagingURL)
replaceOwnRecord(recordRelativePath, contents) -> LocallyAccepted
```

- `restoreAccess` 区分可用、需刷新书签、需重新选择；关联成功不表示联网或全部文件已下载。每次实际操作内部负责 start/stop 及协调生命周期。
- `copyFile` 可读取固定 `catalog.json`、它给出的包路径、清单声明的文件及 records；完成表示 staging 中有完整复制的字节，尚未经 Shelf 验证。原始外部 URL 不泄漏给 Reader。
- `list` 的现有用途是独立 records 区发现；研究版本以 catalog 为准。条目可见性不是云端全局完整性证明，空结果不能直接清空旧记录。
- `replaceOwnRecord` 只允许本设备记录命名范围；没有改写 `packages`/catalog 的能力。协调写入在 provider 本机被接受不等于另一设备已收到，不把返回值命名成全局“已同步”。记录区路径和外壳沿用前置记录任务，不在此另造格式。
- 所有路径需限制在授权根目录内，拒绝路径逃逸；保留权限、缺文件、暂不可物化、取消、空间/配额、协调失败等事实及底层错误。adapter 不选择版本、不校验财务语义、不合并记录、不自主循环重试；Shelf 决定准备顺序、候选保留和重试计划。

## 本轮验证与后续限制

本轮临时类型检查：iOS 17 arm64 的 picker + `.minimalBookmark` + `.withoutUI` 解析退出 0；iOS 17 对两处 `.withSecurityScope` 分别报不可用并退出 1；同样两处在 macOS 14 arm64 退出 0。探针仅在 `/tmp/companylens-bookmark-*.swift`，没有运行权限或网络操作。

这只证明本机 SDK 的符号与 target availability。后续仍需在真实 iPhone/iPad 验证：选目录及跨启动/设备重启恢复、stale/撤权/重新关联、catalog 先到与 PDF 部分到达、离线/物化失败、协调等待取消、前台刷新和真实双设备 records 传递；本机写入确认不能冒充远端同步完成。已准备的本机版本应继续可读，云端变化不得跳动活动 Reader。本轮未安装 App、未访问用户云目录、未验证后台或实时同步。

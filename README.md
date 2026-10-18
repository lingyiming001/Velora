# Velora

Velora 是开发中的 macOS 原生、本地优先知识工作台：用页面与块完成写作，用链接与搜索找回知识，用结构化视图组织项目。当前仓库已有可运行的**早期竖切片**；设计文档描述的是目标方案，尚未全部实现。

## 已实现的早期竖切片

- SwiftUI 主窗口、侧边栏、页面创建/子页面创建/回收箱和标题编辑。
- AppKit `NSTextView` 文本块输入；正文、三级标题、无序/有序列表、待办、折叠、引用、提示、分割线、图片/音视频、文件链接、书签、代码、简单表格、页面目录，共 19 种块；支持分类 `/` 菜单搜索块类型、方向键选择、回车转换与 Esc 关闭；文本块随内容增高，代码块支持预设/自定义语言和折叠（状态本地保存），点击页面末尾提示新增内容，400 ms 空闲自动保存。
- SQLite 本地存储、按标题或正文搜索、浅色/深色/系统外观设置。
- 两项 SQLite 持久化与归档搜索测试。

编辑器仍是验证原型：跨块选区、拖拽排序、附件、导入导出、备份和版本历史尚未实现；不可把当前构建用于重要资料。

## 设置与应用控制

设置包含主题/强调色、编辑字号、存储迁移、备份位置、手动/每日备份、AI 连接、MCP 与语音。
主窗口工具栏或 `⌘J` 打开助手；指令先预览再执行。支持兼容 Chat Completions 的模型服务；密钥存系统钥匙串。
MCP 默认关闭，启用后仅监听本机且默认只读；允许写入后，外部客户端可以操作页面。
语音由系统识别，用户主动录音，默认仅设备识别；首次需要麦克风和语音识别授权。
完整说明、连接配置与已知边界见 [设置与应用控制](docs/Settings-and-Automation.md)。

## 页面整理与回收箱

- 侧边栏按页面树展示，支持展开/折叠、筛选、重命名和新建子页面。
- 将页面拖到另一页面上，使其成为目标页面的子页面；目标高亮并展开。子页面行有移出一级按钮；拖到侧边栏底部可移到顶层。上下排序使用页面菜单的上移/下移。
- 页面菜单提供上移、下移、“移动到…”和移到顶层；移动目标支持搜索，并排除自身及后代。
- 删除页面先进入回收箱；恢复保留同批删除的子页面，先前单独删除的子页面仍留在回收箱。
- 原父页面仍在回收箱时，恢复的页面移到工作区顶层。永久删除与清空回收箱均需确认。
- 旧版本归档页面会出现在回收箱；旧记录没有删除批次，逐页恢复，不推断历史批次。

## 块编辑

- `/` 菜单分为基础块、媒体与链接、进阶块，支持中英文类型名搜索、方向键与回车选择。
- 折叠块以首行为标题，换行输入正文，折叠后保留标题；状态本地保存。
- 图片、音视频、书签和文件块输入 HTTP(S) 链接；音视频需要系统播放器支持的直接资源地址，不支持任意视频网站嵌入或本地文件上传。
- 简单表格首行为表头，可编辑单元格、增加行列、删除末行/末列；内容以 JSON 存入块正文。
- 页面目录自动收集三级标题，点击跳转到对应标题。
- 代码块采用独立卡片，支持行号、轻量词法高亮、复制反馈、语言菜单与折叠；并非完整语言解析器。
- 当前未实现数据库视图、嵌套子块、同步块或公式渲染。

## 产品边界

- 首发对象：重视离线、速度和键盘效率的个人知识工作者。
- MVP：单用户、单设备、页面树、原生块编辑、全文搜索、附件、Markdown 导入导出、本地备份。
- V1.0：数据库及表格/列表/看板/日历视图、模板、双向链接、版本历史。
- V2.0：iCloud 同步、关系属性、AI 功能。团队实时协作另行验证商业需求。

所有版本标签均为**规划假设**，需在发现阶段验证。具体范围见 [产品概览](docs/01-Product-Overview.md) 与 [PRD](docs/02-PRD.md)。

## 文档阅读顺序

1. `docs/01`—`03`：定位、范围、逐模块规格。
2. `docs/04`—`05`：操作流程与 Design System。
3. `docs/06`—`11`：选型、架构、目录、数据、数据库、编辑器。
4. `docs/12`—`15`：质量目标、路线图、测试、发布。

## 代码目录

工程使用一个 App target，按职责组织为 `App/`（入口）、`Domain/`（模型）、`Data/SQLite/`（本地数据）、`Features/`（界面和状态）及 `Tests/`。实际目录和新增文件放置规则见 [项目目录结构](docs/08-Project-Structure.md)。新增 Swift 文件后运行 `scripts/generate_project.rb` 更新工程。

## 在 Xcode 中运行

打开 `Velora.xcodeproj`，选择共享 Scheme **Velora** 和 **My Mac**，按 `⌘R` 运行；`⌘U` 运行测试。

- App target：**Velora**；图标在 `App/Assets.xcassets/AppIcon.appiconset`，General 中选择 AppIcon。
- Info 页管理显示名、版本、分类及麦克风/语音识别用途说明；`App/Info.plist` 保留局域网访问配置。
- `App/Velora.entitlements` 启用 Hardened Runtime 所需的音频输入权限；系统授权仍在主动录音时申请。
- 默认使用本机 ad-hoc 签名（Sign to Run Locally），无需开发者团队；发布时在 Signing & Capabilities 配置自己的团队及分发签名。
- 当前关闭 App Sandbox，以兼容已有自选存储目录、备份及本机 MCP 服务。发布沙盒版本需另行实现安全作用域文件访问。
- 工程生成脚本保留上述配置及 Run/Profile 的 App 可执行文件设置。

## 拟议开发环境

- Xcode 27、Swift、SwiftUI + AppKit，最低 macOS 14（暂定，仍需目标设备验证）。
- SQLite 经轻量封装访问；当前搜索使用参数化 `LIKE`，`FTS5` 是后续性能阶段目标；无网络运行时依赖。
- 工程：`Velora.xcodeproj`。构建：`xcodebuild -project Velora.xcodeproj -scheme Velora -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`。
- 测试：`xcodebuild -project Velora.xcodeproj -scheme Velora -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`。本机 2026-10-13 已通过。
- 工程可用 `scripts/generate_project.rb` 重建，需本机安装 `xcodeproj` Ruby gem。

## 协作与资料

源码与可执行工程保存在本目录；设计文档在本仓库 `docs/` 留有可版本化副本，并在用户指定的 Notion `Velora` 页面下维护阅读副本。修改架构时同时检查 `docs/02`、`07`、`09`、`10`、`11` 的一致性。开发续航入口是 `.agents/STATUS.md`。

## 参考依据

- [Apple Human Interface Guidelines：Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Apple Human Interface Guidelines：Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards/)
- [SwiftUI NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview)
- [Notion 数据库帮助](https://www.notion.com/help/category/databases)
- [SQLite FTS5](https://www.sqlite.org/fts5.html)


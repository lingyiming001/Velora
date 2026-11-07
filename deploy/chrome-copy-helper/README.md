# ChatGPT 复制换行助手

用于 Chrome 网页版 ChatGPT：选中正文、Python 或 Plain Text 代码块后按 ⌘C，再正常粘贴到 Velora。它在复制事件发生时将代码编辑器的逐行 DOM 转成含真实换行的 `<pre><code>`，同时写入 HTML 和纯文本，不推测代码排版。

## 安装

1. 在 Chrome 扩展程序管理页面启用“开发者模式”。
2. 点击“加载已解压的扩展程序”，选择本目录 `deploy/chrome-copy-helper`。
3. 刷新已打开的 ChatGPT 页面，再选择内容并按 ⌘C。

无需重装 Velora。仅运行于 `https://chatgpt.com/*`，只在用户复制且选区包含代码时处理；无后台服务、网络请求、存储、全局剪贴板读取权限。Chrome 会要求授予 ChatGPT 页面的访问权限。

## 范围

- 支持标准 PRE、CodeMirror `.cm-line`、代码编辑器内部的部分选区、空行与缩进。
- 不会恢复复制之前已损坏的内容，不调整 Python 语法。
- 此助手处理用户选择内容后的 ⌘C / 浏览器“复制”事件。网站自身的“复制回答”按钮可能直接写剪贴板，不经过复制事件，不在此范围。
- 长代码若被网页虚拟化且未选中的行没有进入 DOM，本助手不伪造缺失内容；请使用源代码下载或代码编辑器自身复制。
- 若复制输入框里的普通文字，不会拦截。

## 卸载

在 Chrome 扩展程序管理页移除本助手即可，Velora 与原文不会被修改。

## 1.1.0 常用语言统一支持

按代码块结构保留源码，不依赖语言语法猜测。自动测试覆盖 Java、Python、JavaScript、TypeScript、Go、Rust、Bash、SQL、JSON、YAML、HTML、CSS、Plain Text 的多块混合复制和 Velora 导入；保留语言标签、空行、缩进和字符串。新增识别 ChatGPT `data-code-block-source` 静态代码块，避免 Plain Text 被当成普通内联代码。

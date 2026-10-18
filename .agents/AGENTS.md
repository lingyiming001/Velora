# 项目协作说明

先读 `.agents/STATUS.md` 和简短 Git 状态；按需读 `.agents/DECISIONS.md`、`.agents/LOG.md`、`.agents/CHANGELOG.md`。开发后更新状态和实际验证结果。

<!-- project-continuity:layout -->
## 产物目录

- `.gitignore` 仅忽略个人进度 `.agents/STATUS.md`、`.agents/LOG.md` 和临时验证产物 `.agents/test/`；协作说明及共享决策保持可跟踪。
- 工具自动测试的截图只能保存到 `.agents/test/`；调用前指定绝对输出路径，包含失败和重试截图。其他测试临时产物也放此处，源码测试用例保留原目录。
- 新增部署交付文件放 `deploy/`；工具要求固定位置的配置保留原位。
- 根目录尽量保留原代码、docs/、deploy/、README.md、scripts/ 和必要项目配置；协作记录统一放 `.agents/`。

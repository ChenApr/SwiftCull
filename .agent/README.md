# Agent 协作入口

开发前请阅读根目录的 [AGENTS.md](../AGENTS.md)，其中统一维护产品原则、代码约定、验证命令及 Git 提交规则。

首次克隆后运行 `bash .agent/setup-git-hooks.sh`，启用本地 commit message 格式校验；安装脚本不会覆盖已有的自定义 hooks 配置。

- 项目介绍与上手方式：[README.md](../README.md)。
- 第三方代码与资源许可：[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
- Claude 协作入口：[.claude/CLAUDE.md](../.claude/CLAUDE.md)。

本目录用于共享协作资料，不代表所有 Agent 工具都会自动加载。若工具未自动读取规范，请在任务开始时显式引用根目录 `AGENTS.md`。

通用规则请修改根目录文件，避免在多个工具目录中维护重复副本。不要在共享资料中加入个人路径、凭据或本机授权设置。

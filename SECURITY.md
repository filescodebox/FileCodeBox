# Security Policy / 安全策略

## 支持版本

| 版本 | 支持状态 |
|---|---|
| latest（main 分支 + 最新 release） | ✅ 支持 |
| 旧版本 | ❌ 请升级 |

## 报告漏洞

**请不要在公开 Issue/PR/Discussion 中披露安全漏洞。**

1. 使用 GitHub [Private Vulnerability Reporting](https://github.com/filescodebox/FileCodeBox/security/advisories/new)（首选），或邮件联系仓库 Owners。
2. 请包含：影响范围、复现步骤/POC、涉及的模块仓与版本、可能的修复思路。
3. 我们承诺 72 小时内确认收到，7 天内给出评估与修复计划。

## 处理流程

确认 → 修复（私有分支）→ 发布补丁版本 → 公开 advisory（含致谢，除非你要求匿名）。

## 安全基线（当前已内置）

- 分享密码 bcrypt 校验、防爆破失败锁定（Redis/内存双模）
- 下载令牌、SSRF 端点校验（`security.ssrf.allow_private_networks` 可控私网策略）
- 上传魔数检测、文件名消毒、路径逃逸防御
- 管理端审计日志、JWT 注销黑名单

## 已知边界

- 默认管理员 `admin/admin123`：生产部署**必须**用 `FCB_ADMIN_PASSWORD` 覆盖，或以 `app.production: true` 强制校验。
- S3/WebDAV 凭据经管理端在线修改后持久化在站点数据库（`system_configs`），请保证数据库访问面的安全；也可仅用 yaml/env 注入。

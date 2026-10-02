# scripts/

装配仓(hub)级脚本。模块仓各自的工具在自己的仓里（如 `contracts/scripts/` 的 IDL 再生成）。

| 脚本 | 用途 | 说明 |
|---|---|---|
| `setup.sh` | 拉齐/更新模块仓（幂等），`make setup` 的实体 | `SETUP_FNOS=1` 连 fnos 一起拉 |
| `export_config_from_db.{go,py}` | 从旧版 SQLite `key_values` 表导出配置为 YAML | **遗留迁移工具**：`key_values` 表已废弃（现行为 `system_configs` 单行 JSON，由 core 自动读写），仅用于迁移更早期部署的数据。Go 版需独立构建：`cd scripts && GOWORK=off go run export_config_from_db.go -db data/filecodebox.db` |
| `generate_favicon.sh` | 由 SVG 生成多尺寸 favicon | 前端/静态资源维护用 |
| `test_nfs_storage.sh` | NFS 存储后端连通性与读写测试 | 存储运维用 |

> 来源说明：除 `setup.sh` 外均为旧单体仓库（legacy/FileCodeBox）收编，2026-10 迁入。

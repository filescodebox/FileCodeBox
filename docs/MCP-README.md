# FileCodeBox MCP Server（AI 客户端集成）

FileCodeBox 内置 **Model Context Protocol (MCP) server**，AI 客户端（Claude Desktop / 任意标准 MCP 客户端）可以直接管理文件分享——上游 vastsa/FileCodeBox 没有的能力。

- 传输：**Streamable HTTP**（`POST /api/v1/mcp`，JSON-RPC 2.0，符合 MCP 规范；legacy 文档的裸 TCP 方案已废弃）
- 认证：管理员 JWT（`Authorization: Bearer <token>`）
- 开关：`mcp.enabled`（默认 true）/ `FCB_MCP_ENABLED`

## 工具清单（8 个）

| 工具 | 说明 |
|---|---|
| `share_text` | 创建文本分享（可选密码/过期样式），返回取件码与链接 |
| `get_share` | 按取件码查询分享信息（不消耗取件次数） |
| `list_shares` | 分页列出全站分享（可按取件码搜索） |
| `delete_share` | 删除分享（DB + 物理文件，写审计日志） |
| `get_system_status` | 系统/上传统计 |
| `get_storage_info` | 存储使用状态 |
| `list_users` | 用户列表 |
| `cleanup_expired` | 清理全部过期分享 |

## 接入步骤

```bash
# 1. 拿管理员 token
TOKEN=$(curl -s -X POST http://localhost:12345/admin/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"<your-password>"}' | jq -r .data.token)

# 2. 验证 MCP 握手
curl -s -X POST http://localhost:12345/api/v1/mcp \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```

### Claude Desktop / 任意 MCP 客户端

远程 MCP（Streamable HTTP）配置示例：

```json
{
  "mcpServers": {
    "filecodebox": {
      "type": "http",
      "url": "http://your-server:12345/api/v1/mcp",
      "headers": { "Authorization": "Bearer <admin-token>" }
    }
  }
}
```

> 安全提示：MCP 具备删文件/清库能力，务必只授予管理员账号的 token，并用 HTTPS 暴露。

## 协议细节

- `initialize` → `protocolVersion: "2025-03-26"`，capabilities 只声明 `tools`
- 通知（无 id 请求）→ HTTP 202 无响应体
- 工具业务失败 → `result.isError: true` + 文本说明（协议错误才用 JSON-RPC error）
- 未知方法 → `-32601`；非法参数 → `-32602`

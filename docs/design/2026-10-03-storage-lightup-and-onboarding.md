# 详细设计：存储后端点亮 + 首启引导（Phase 1）

- 日期：2026-10-03
- 状态：已评审（对应 ROADMAP「现在」列）
- 涉及仓：core（主体）、frontend（Setup 页）、hub（本文档 + ROADMAP）

## 1. 背景与问题

拆分时遗留了一个「假开关」：`core/storage/opendal` 抽象层声明了 fs/s3/webdav 三个 scheme，
但 (a) s3/webdav 的传输实现全部返回 `scheme not implemented`；(b) `storage.StorageService`
（全部读写链路的唯一出口）没有任何按 `StorageType` 分派的逻辑，`Type` 字段被忽略；
(c) `presign.UploadDirect` 绕过 StorageService 硬编码 `os.WriteFile("./data", ...)`。
结果：S3/WebDAV 能配置、能测连，实际读写永远落本地盘。管理端 `SwitchStorage` 只改内存，
重启丢失——点亮真实多后端后，这会造成「重启后用 local 读不到 s3 上的旧文件」的数据漂移。

## 2. 目标 / 非目标

**目标（本轮交付）**
1. S3 与 WebDAV 后端真实读写：上传、下载（流式）、删除、分片、合并、清理全链路可用。
2. 运行时切换存储后端且**持久化**（重启不丢）；启动时从 DB 恢复。
3. presign 直传与分片上传走当前激活后端（不再硬编码本地盘）。
4. `/api/config` 返回真实 `initialized`；前端新增 Setup 初始化页面。
5. opendal s3 预签名 URL 能力（SDK 离线签名），为二期真直传铺路。

**非目标（二期及以后，见 ROADMAP）**
- 客户端 → S3 真·预签名直传直下（需改造 presign Init/Complete 协议与前端）。
- 存储迁移工具（local→s3 存量搬运）。
- NFS 后端、OneDrive、S3 环境变量注入（`FCB_STORAGE_S3_*`）。
- 文档站 / demo 站 / MCP / 反向分享（ROADMAP 中期项）。

## 3. 总体方案

```
                 ┌────────────────────────────────────────────┐
                 │  bootstrap（组装/单例/启动恢复）              │
                 └───┬───────────────┬───────────────┬────────┘
      StorageInterface│               │SetPersister   │SetStorage(SaveBytes)
   ┌──────────────────▼───┐   ┌───────▼────────┐  ┌───▼──────────┐
   │ storage.StorageService│   │ app/storage.Svc│  │ app/presign  │
   │  (RWMutex 热切换)      │◄──┤  Probe/Reload  │  │  UploadDirect│
   │  local: 既有 os 代码   │   │  Switch/Update │  └──────────────┘
   │  remote: opendal.Operator                        │
   └──────────┬───────────┘        ┌──────────────┐
              │          ┌─────────▼ admin.Service  │
        ┌─────▼─────┐    │ runtime_storage 段       │
        │ opendal   │    │ (system_configs 单行 JSON)│
        │ fs│s3│dav │    └──────────────────────────┘
        └───────────┘
   新依赖：minio-go/v7（S3 兼容）、gowebdav（WebDAV）
```

依赖方向不新增域间耦合：storage 域定义 `RuntimePersister` 接口，admin 域实现
（读写自己拥有的 system_configs 单行上的 `runtime_storage` 段），bootstrap 装配。
接口载荷类型复用 `conf.StorageConfig`，两侧都只 import conf。

## 4. 模块设计

### 4.1 opendal：s3 / webdav 真实现（`core/storage/opendal/`）

内部驱动接口（不导出，`NewCustom(scheme, driver)` 仅供测试注入）：

```go
type Driver interface {
    Write(ctx, key string, data []byte) error
    WriteStream(ctx, key string, r io.Reader, size int64) error
    Read(ctx, key string) ([]byte, error)
    Reader(ctx, key string) (io.ReadCloser, error)
    Stat(ctx, key string) (*Metadata, error)
    Delete(ctx, key string) error
    RemoveAll(ctx, key string) error // 前缀/目录递归删
}
```

- `Operator.New`：scheme=s3/webdav 时按 Options 构造驱动，**缺参返回 error**
  （此前「静默 fs 兜底」只保留给未知 scheme）。fs 路径行为不变。
- `s3.go`（minio-go）：Options `endpoint/access_key/secret_key/bucket(Root)/region/
  use_ssl/path_style`。endpoint 兼容带/不带 scheme（https→use_ssl）。对象缺失统一映射
  `os.ErrNotExist`（`errors.Is` 可判）。`Presign` 用 `PresignedPutObject/GetObject`
  离线签名（无网络依赖，可单测）。
- `webdav.go`（gowebdav）：Options `url/username/password/root`。key 以 URL 路径拼接
  （`/`分隔，非 filepath），写前 `MkdirAll`；404 映射 `os.ErrNotExist`。
- Operator 新增 `WriteStream`（fs=create+io.Copy）；`Reader` 对 s3/dav 先 Stat 取大小。
- `Stat/Exists` 语义：不存在 → `(nil, os.ErrNotExist)` / `false`。

### 4.2 StorageService：类型分派 + 热切换（`core/storage/storage.go`）

```go
type StorageService struct {
    mu      sync.RWMutex
    config  *StorageConfig
    op      *opendal.Operator // local 时为 nil
    initErr error             // remote 构造失败降级 local 的原因
}
```

- `NewStorageServiceE(cfg) (*StorageService, error)`：remote 构造失败返回错误；
  `NewStorageService(cfg)` 保持原签名与行为（失败降级 local），存量调用方零感知。
- 每个接口方法：RLock 取 `(config, op)`；`op==nil` 走既有本地实现（**逐行不动，零回归**）；
  remote 走 Operator。分派映射：

| 接口方法 | local | remote |
|---|---|---|
| SaveFile | 既有 TeeReader 落盘+哈希 | `WriteStream(file.Open(), file.Size)`，哈希同样流式计算 |
| SaveChunk | 既有 | `op.Write(chunks/<id>/chunk_<i>)` |
| MergeChunks | 既有顺序拼接 | `chunkChainReader`（懒打开下一分片的顺序读器）+ `WriteStream(total=sum(Stat))`，完成后异步 CleanChunks |
| CleanChunks | `os.RemoveAll` | `op.RemoveAll(chunks/<id>)` |
| GetFileReader/GetFileSize/GetFile/DeleteFile/FileExists | 既有 | `op.Stat/Reader/Read/Delete/Exists` |
| GetFileURL / GenerateFilePath | 不变（与后端无关） | 同左 |

- 新增具体方法 `SaveBytes(ctx, path, data)`（presign 直传用；路径逃逸防御收敛到此，
  用 `filepath.Rel` 判逃逸——原 presign 的 `filepath.IsLocal` 写法在 DataPath 为绝对路径时
  会误杀，属于实现期修正）；不加入 `StorageInterface`，presign 域自定义单方法接口
  `StorageWriter`，避免破坏两个存量 mock。
- 新增 `Reload(cfg) error`（Lock 下原子换 config+op，失败保留旧值）与
  `EffectiveType() StorageType`（降级时如实返回 local，供管理端展示真相）。

### 4.3 运行时切换与持久化（app/storage + admin + bootstrap）

- `app/storage.Service`：新增 `SetRuntime(rt)`（`rt = Reload/EffectiveType`，由
  bootstrap 注入单例 StorageService）与 `SetPersister(p RuntimePersister)`。
  - `SwitchStorage(type)`：校验 →（非 local）用当前 conf 组装目标 `StorageConfig` →
    `Probe(ctx, cfg)`（新增：s3=`BucketExists`、dav=`Stat(root)`、local=可写测试，
    比 SSRF 探测更强的**认证级**验证）→ `Reload` 失败即回滚报错 → 更新 conf →
    `SaveRuntimeStorage`（持久化失败仅返回警告性错误，切换已生效）。
  - `UpdateStorageConfig`：字段校验（SSRF 白名单保留）→ 同上流程。
- `admin.SystemConfig` 增加 `RuntimeStorage *conf.StorageConfig json:"runtime_storage,omitempty"`；
  `UpdateConfig` 增加防御性合并（入参为 nil 时保留旧值——admin handler 会从请求重建
  结构体，不合并则每次保存站点配置都会冲掉该段）；`LoadRuntimeStorage/SaveRuntimeStorage`
  实现持久化接口（ensureConfigLoaded 之后读改写单行）。
- 启动恢复（bootstrap）：InitConfig 后，若 DB 有 `runtime_storage` 则覆盖 conf.Storage
  （DB 是管理端更晚的意图，优先于 yaml），随后重放 `FCB_STORAGE_TYPE/FCB_STORAGE_PATH`
  两个 env 覆盖（env > DB > yaml）。
- `getBootstrapStorageService()` 改为**单例**（当前 3 次调用创建 3 个实例，热切换无从谈起），
  BaseURL 与 presign 同规则（`server.base_url` 优先）。

### 4.4 presign 接线（app/presign + gen/handler/presign）

- `presign.Service` 增加 `SetStorage(StorageWriter)`；`UploadDirect` 第 5 步改为：
  storage 注入时 `SaveBytes(ctx, meta.ObjectKey, data)`（路径防御已收敛进 StorageService），
  未注入时保留原 os 逻辑（存量单测/降级形态不受影响）。SHA-256 计算与回写不变。
- handler 增加 `SetStorage`（对齐 `SetShareService` 的 nil 容错模式）。

### 4.5 `/api/config` 真实 initialized + Setup 页（bootstrap + frontend）

- `publicConfigHandler`：`initialized` 从 `setup.Service.IsSystemInitialized(ctx)` 实时查询
  （当前恒 true；bootstrap 的 CreateDefaultAdmin 会自动建 admin，故常态仍为 true，
  但语义从此真实——未来「禁用默认管理员」开关、fnos 等无默认管理员形态直接受益）。
- 前端：`publicApi.getConfig()` 类型补 `initialized`；新增 `publicApi.initializeSystem()`
  （POST /setup，复用既有公开端点）；新增公开路由 `/setup` + `views/setup/Index.vue`
  （用户名/密码/确认/邮箱，校验规则对齐后端 `validateInitializeRequest`；onMounted
  check 已初始化则跳转首页）；i18n zh-CN/en-US 补键。
- 守卫策略：不做全局路由强跳（避免守卫里发网络请求），Setup 页自检 + 设计文档记录。

## 5. 配置矩阵（切换生效后）

| 来源 | 键 | 优先级 |
|---|---|---|
| env | `FCB_STORAGE_TYPE` / `FCB_STORAGE_PATH` | 1（最高，重启后仍生效） |
| DB | `system_configs.runtime_storage`（管理端在线切换/改配置写入） | 2 |
| yaml | `storage.type/storage_path/s3.*/webdav.*` | 3（兜底） |

s3：`storage.s3.{endpoint,region,bucket,access_key,secret_key,use_ssl,path_style}`；
webdav：`storage.webdav.{endpoint,username,password}`。管理端在线修改走
`PUT /admin/storage/config`（既有端点，本次升级其语义为「生效+持久化」）。

## 6. 测试计划

1. opendal：s3 Options 解析/缺参报错/Presign 离线签名断言（URL 含 X-Amz-Signature、
   过期参数正确）；webdav 用 `golang.org/x/net/webdav` 在 httptest 起真实服务做全操作
   roundtrip（零外部依赖）；S3 集成测试挂 `FCB_TEST_S3_ENDPOINT` env 门，默认 skip。
2. storage：本地路径既有用例不改动全绿（回归底线）；`NewCustom` 注入 fake Driver 验证
   remote 分派映射（SaveFile 哈希/SaveChunk/MergeChunks 顺序与总大小/CleanChunks/
   GetFileReader）；Reload 失败保留旧值、EffectiveType 降级如实。
3. app/storage：fake Runtime+Persister 验证 Switch/Update 的 probe→reload→persist 时序
   与失败回滚；admin：UpdateConfig 防御性合并（入参无 runtime_storage 不丢旧值）。
4. presign：注入 fake StorageWriter 后 UploadDirect 不落 os、hash 回写正常。
5. 全量：hub `make test`（三 Go 模块 + frontend typecheck）+ `make build` + `make smoke`。

## 7. 风险与回滚

- minio-go/gowebdav 为新增直接依赖（go.mod），无 replace、不与 sonic/thrift 版本规则冲突。
- 既有部署默认 `storage.type=local`，本设计对 local 路径零改动 → 回滚 = revert 提交。
- 运行时切换期间在途请求持旧 backend 完成（RLock 语义），不产生半写状态；
  切换失败自动回滚内存与（重试失败的）持久化提示。
- `runtime_storage` 段对旧版本不可见（json.Unmarshal 丢未知字段），降级安全：
  旧版本读库忽略该段、写库覆盖该段 → 回滚后该段失效但不损坏原配置。

## 8. 二期衔接（本期已预留的钩子）

- `opendal.Operator.Presign`（s3）已可用 → 二期把 `presign.Init` 对 s3 类型改发
  SDK 预签名 URL、`Complete` 改为登记对象头（ETag/大小），前端直传直下省服务器带宽。
- `EffectiveType()`/initErr → 管理端存储页展示「实际生效后端」与健康状态。
- `Reload` 机制 → 后续 NFS/OneDrive 驱动接入只需实现 `opendal.Driver`。

## 9. 二期实现：真·S3 预签名直传直下（2026-10-03 同日落地）

### 9.1 直传（Init 签发 → 客户端 PUT S3 → Complete 核实）

- `storage.StorageService` 新增 `PresignPutURL/PresignGetURL`（仅 `op.Scheme()==s3` 时
  经 opendal 离线签名，否则返回 `ErrPresignUnsupported`）与 `HeadObject`（大小+ETag）。
- `presign.Service` 新增 `ObjectStore` 能力接口（`SetObjectStore` 注入）。
  `Init` 在存 meta 前先尝试签发：成功 → `meta.Scheme=s3`、`UploadURL=预签名 PUT`、
  Headers 换为 `Content-Type`；失败/未注入 → 回退自家中转（`Scheme=self`，
  行为与一期前完全一致）。**服务端判定为准**，客户端传入的 scheme 被覆盖。
- `Complete` 对 `Scheme=s3` 的 meta：`HeadObject` 核实对象真实存在 → 以 S3 实际大小
  覆盖 `meta.FileSize`（兜底最大上传限制）→ 再写分享。核实失败**不标记 complete**，
  客户端可重传后重试。服务器未接触内容：`FileHash` 保持客户端预计算值（可空，空则
  该分享不参与秒传指纹库）。
- 前端零改动：`PresignUploadDialog` 本就按 Init 下发的 `method/upload_url/headers` 通用 PUT。

### 9.2 直下（下载 302，可选开关）

- 配置 `download.s3_direct_download`（env `FCB_DOWNLOAD_S3_DIRECT`，默认关）。
- `/share/download` 在访问校验/密码/次数扣减全部完成后、流式返回前：开关开且后端支持
  时 302 到 10 分钟时效的预签名 GET（`Cache-Control: no-store`）；不支持/签发失败
  回退服务端中转。处理器内对窄接口做 `*storage.StorageService` 断言取直下能力。

### 9.3 运维注意与测试

- **桶 CORS**：浏览器直传/直下需在对象存储桶配置允许站点来源（PUT/GET + 相应头）。
- 预签名 URL 即临时凭证：签发只发生在访问校验之后；10 分钟短时效 + `no-store`。
- 新增测试：fake presigner 验证 URL 分派与 local 不支持；fake ObjectStore 验证
  s3 模式签发/回退、Complete 实际大小覆盖、对象缺失不标记 complete 可重试。


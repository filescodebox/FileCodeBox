#!/bin/bash

# NFS存储配置和测试脚本
# 用于测试FileCodeBox的NFS存储功能

echo "=== FileCodeBox NFS 存储测试脚本 ==="
echo "日期: $(date)"
echo

# 配置参数
export NFS_SERVER="192.168.1.100"
export NFS_PATH="/nfs/storage"
export NFS_MOUNT_POINT="/mnt/filecodebox_nfs"
export NFS_VERSION="4"
export NFS_OPTIONS="rw,sync,hard,intr"
export NFS_TIMEOUT="30"
export NFS_AUTO_MOUNT="1"
export NFS_RETRY_COUNT="3"
export NFS_SUB_PATH="filebox_storage"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 函数：打印消息
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 函数：检查命令是否存在
check_command() {
    if ! command -v $1 &> /dev/null; then
        log_error "$1 命令未找到，请先安装"
        return 1
    fi
    return 0
}

# 函数：检查NFS客户端工具
check_nfs_tools() {
    log_info "检查NFS客户端工具..."
    
    # 检查mount命令
    if ! check_command mount; then
        return 1
    fi
    
    # 检查是否安装了NFS客户端
    if [ -f /proc/filesystems ]; then
        if ! grep -q nfs /proc/filesystems; then
            log_warning "NFS客户端模块未加载"
            log_info "尝试加载NFS模块..."
            if command -v modprobe &> /dev/null; then
                sudo modprobe nfs || log_warning "无法加载NFS模块"
            fi
        fi
    fi
    
    return 0
}

# 函数：测试NFS服务器连通性
test_nfs_connectivity() {
    log_info "测试NFS服务器连通性..."
    
    # 测试服务器是否可达
    if ! ping -c 3 "$NFS_SERVER" &> /dev/null; then
        log_error "无法连接到NFS服务器: $NFS_SERVER"
        return 1
    fi
    
    log_success "NFS服务器连接正常"
    
    # 测试RPC服务
    if command -v rpcinfo &> /dev/null; then
        log_info "检查NFS RPC服务..."
        if rpcinfo -p "$NFS_SERVER" | grep -q nfs; then
            log_success "NFS RPC服务正常"
        else
            log_warning "NFS RPC服务可能未启动"
        fi
    fi
    
    return 0
}

# 函数：测试NFS挂载
test_nfs_mount() {
    log_info "测试NFS挂载..."
    
    # 创建挂载点
    if [ ! -d "$NFS_MOUNT_POINT" ]; then
        log_info "创建挂载点: $NFS_MOUNT_POINT"
        sudo mkdir -p "$NFS_MOUNT_POINT" || {
            log_error "创建挂载点失败"
            return 1
        }
    fi
    
    # 检查是否已经挂载
    if mount | grep -q "$NFS_MOUNT_POINT"; then
        log_info "NFS已挂载，先卸载..."
        sudo umount "$NFS_MOUNT_POINT" || {
            log_warning "卸载失败，尝试强制卸载"
            sudo umount -f "$NFS_MOUNT_POINT" || {
                log_error "强制卸载失败"
                return 1
            }
        }
    fi
    
    # 尝试挂载
    log_info "挂载NFS: ${NFS_SERVER}:${NFS_PATH} -> ${NFS_MOUNT_POINT}"
    local mount_cmd="sudo mount -t nfs -o vers=${NFS_VERSION},${NFS_OPTIONS} ${NFS_SERVER}:${NFS_PATH} ${NFS_MOUNT_POINT}"
    log_info "执行命令: $mount_cmd"
    
    if eval "$mount_cmd"; then
        log_success "NFS挂载成功"
        
        # 创建子目录
        local sub_dir="${NFS_MOUNT_POINT}/${NFS_SUB_PATH}"
        if [ ! -d "$sub_dir" ]; then
            log_info "创建存储子目录: $sub_dir"
            sudo mkdir -p "$sub_dir" || {
                log_error "创建子目录失败"
                return 1
            }
        fi
        
        # 测试读写
        log_info "测试NFS读写功能..."
        local test_file="${sub_dir}/test_$(date +%s).txt"
        if echo "FileCodeBox NFS Test" | sudo tee "$test_file" > /dev/null; then
            if [ -f "$test_file" ] && grep -q "FileCodeBox NFS Test" "$test_file"; then
                log_success "NFS读写测试成功"
                sudo rm -f "$test_file"
                return 0
            else
                log_error "NFS读取测试失败"
                return 1
            fi
        else
            log_error "NFS写入测试失败"
            return 1
        fi
    else
        log_error "NFS挂载失败"
        return 1
    fi
}

# 函数：生成配置文件
generate_config() {
    log_info "生成NFS配置..."
    
    local config_file="nfs_config.json"
    cat > "$config_file" << EOF
{
    "nfs_server": "$NFS_SERVER",
    "nfs_path": "$NFS_PATH",
    "nfs_mount_point": "$NFS_MOUNT_POINT",
    "nfs_version": "$NFS_VERSION",
    "nfs_options": "$NFS_OPTIONS",
    "nfs_timeout": $NFS_TIMEOUT,
    "nfs_auto_mount": $NFS_AUTO_MOUNT,
    "nfs_retry_count": $NFS_RETRY_COUNT,
    "nfs_sub_path": "$NFS_SUB_PATH"
}
EOF
    
    log_success "配置文件已生成: $config_file"
}

# 函数：测试FileCodeBox NFS集成
test_filecodebox_nfs() {
    log_info "测试FileCodeBox NFS集成..."
    
    # 检查是否有可执行文件
    if [ ! -f "./filecodebox" ]; then
        log_info "构建FileCodeBox..."
        if ! go build -o filecodebox .; then
            log_error "构建失败"
            return 1
        fi
    fi
    
    # 设置环境变量
    export NFS_SERVER="$NFS_SERVER"
    export NFS_PATH="$NFS_PATH"
    export NFS_MOUNT_POINT="$NFS_MOUNT_POINT"
    export NFS_VERSION="$NFS_VERSION"
    export NFS_OPTIONS="$NFS_OPTIONS"
    export NFS_TIMEOUT="$NFS_TIMEOUT"
    export NFS_AUTO_MOUNT="$NFS_AUTO_MOUNT"
    export NFS_RETRY_COUNT="$NFS_RETRY_COUNT"
    export NFS_SUB_PATH="$NFS_SUB_PATH"
    
    # 启动FileCodeBox测试
    log_info "启动FileCodeBox进行NFS存储测试..."
    timeout 10s ./filecodebox &
    local pid=$!
    
    sleep 3
    
    # 测试存储切换API
    if command -v curl &> /dev/null; then
        log_info "测试存储API..."
        
        # 获取管理员token
        local token=$(curl -s -X POST http://localhost:12345/admin/login \
            -H "Content-Type: application/json" \
            -d '{"password": "FileCodeBox2025"}' | \
            grep -o '"token":"[^"]*"' | cut -d'"' -f4)
        
        if [ -n "$token" ]; then
            log_success "获取管理员token成功"
            
            # 测试存储信息API
            log_info "获取存储信息..."
            curl -s -H "Authorization: Bearer $token" \
                http://localhost:12345/admin/storage | jq .
                
        else
            log_warning "无法获取管理员token"
        fi
    fi
    
    # 停止测试进程
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
}

# 函数：清理测试环境
cleanup() {
    log_info "清理测试环境..."
    
    # 卸载NFS
    if mount | grep -q "$NFS_MOUNT_POINT"; then
        log_info "卸载NFS..."
        sudo umount "$NFS_MOUNT_POINT" || {
            sudo umount -f "$NFS_MOUNT_POINT" || true
        }
    fi
    
    # 删除挂载点（如果为空）
    if [ -d "$NFS_MOUNT_POINT" ]; then
        if [ -z "$(ls -A "$NFS_MOUNT_POINT")" ]; then
            sudo rmdir "$NFS_MOUNT_POINT" || true
        fi
    fi
    
    log_success "清理完成"
}

# 主函数
main() {
    echo "配置参数:"
    echo "  NFS服务器: $NFS_SERVER"
    echo "  NFS路径: $NFS_PATH"
    echo "  挂载点: $NFS_MOUNT_POINT"
    echo "  版本: $NFS_VERSION"
    echo "  选项: $NFS_OPTIONS"
    echo "  超时: ${NFS_TIMEOUT}s"
    echo "  自动挂载: $NFS_AUTO_MOUNT"
    echo "  重试次数: $NFS_RETRY_COUNT"
    echo "  子路径: $NFS_SUB_PATH"
    echo
    
    # 检查NFS工具
    if ! check_nfs_tools; then
        log_error "NFS工具检查失败"
        exit 1
    fi
    
    # 测试连通性
    if ! test_nfs_connectivity; then
        log_error "NFS连通性测试失败"
        exit 1
    fi
    
    # 测试挂载
    if ! test_nfs_mount; then
        log_error "NFS挂载测试失败"
        cleanup
        exit 1
    fi
    
    # 生成配置
    generate_config
    
    # 测试FileCodeBox集成
    test_filecodebox_nfs
    
    # 清理（可选）
    read -p "是否清理测试环境？(y/N): " cleanup_choice
    if [[ "$cleanup_choice" =~ ^[Yy]$ ]]; then
        cleanup
    else
        log_info "保持NFS挂载，记得手动清理"
    fi
    
    log_success "NFS存储测试完成"
}

# 检查是否为root或有sudo权限
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    log_error "此脚本需要root权限或sudo权限来挂载NFS"
    exit 1
fi

# 执行主函数
main "$@"

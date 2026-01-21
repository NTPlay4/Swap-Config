#!/bin/bash
# 1G内存+机械硬盘 多功能 swap 管理脚本 v3.0
# 优化点：解决重启配置失效+增强容错+跨系统兼容+详细日志
# 支持：创建自定义swap/设置swappiness/删除swap  |  需root权限运行

# 定义默认参数
DEFAULT_SWAP_SIZE="512M"
DEFAULT_SWAPPINESS=10
SWAP_FILE="/swapfile"
SYSCTL_CONF="/etc/sysctl.conf"
# 兼容Debian/Ubuntu的sysctl.d目录（优先级更高）
SYSCTL_D="/etc/sysctl.d/99-swap.conf"

# 彩色输出函数（增强可读性）
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }

# 检查root权限（强制要求）
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        red "错误：必须使用 root 用户或 sudo 运行此脚本！"
        exit 1
    fi
}

# 验证swappiness数值（0-100整数）
validate_swappiness() {
    local num=$1
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 0 ] || [ "$num" -gt 100 ]; then
        yellow "输入无效！swappiness 必须是 0-100 之间的整数"
        return 1
    fi
    return 0
}

# 验证swap大小格式（支持 K/M/G 后缀，大小写兼容）
validate_swap_size() {
    local size=$1
    if ! [[ "$size" =~ ^[0-9]+[KkMmGg]$ ]]; then
        yellow "输入无效！swap大小格式示例：512M、1G、1024K（必须带单位）"
        return 1
    fi
    return 0
}

# 验证磁盘空间是否足够
check_disk_space() {
    local size=$1
    local unit=${size: -1}
    local num=${size%?}
    local required=0

    # 转换为MB计算
    case $unit in
        K|k) required=$((num / 1024)) ;;
        M|m) required=$num ;;
        G|g) required=$((num * 1024)) ;;
    esac

    # 获取当前目录可用空间（MB）
    local available=$(df -BM "$(dirname $SWAP_FILE)" | awk 'NR==2 {gsub(/M/,""); print $4}')
    
    if [ $required -gt $available ]; then
        red "错误：磁盘可用空间不足！需要 ${required}MB，仅剩余 ${available}MB"
        return 1
    fi
    return 0
}

# 选项1：创建/修改 swap 分区（核心优化）
create_swap() {
    blue "\n===== 创建/修改 SWAP 分区 ====="
    
    # 读取自定义swap大小
    read -p "请输入swap大小（默认 $DEFAULT_SWAP_SIZE，格式如 512M/1G）：" INPUT_SWAP
    SWAP_SIZE=${INPUT_SWAP:-$DEFAULT_SWAP_SIZE}
    if ! validate_swap_size "$SWAP_SIZE"; then
        return 1
    fi

    # 读取自定义swappiness值
    read -p "请输入swappiness值（默认 $DEFAULT_SWAPPINESS，范围 0-100）：" INPUT_SWAPINESS
    SWAPPINESS=${INPUT_SWAPINESS:-$DEFAULT_SWAPPINESS}
    if ! validate_swappiness "$SWAPPINESS"; then
        return 1
    fi

    # 检查磁盘空间
    if ! check_disk_space "$SWAP_SIZE"; then
        return 1
    fi

    # 处理已有swap文件
    if [ -f "$SWAP_FILE" ]; then
        yellow "\n检测到已存在swap文件：$SWAP_FILE"
        read -p "是否覆盖现有配置？(y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            yellow "操作取消"
            return 0
        fi
        # 安全关闭现有swap
        blue "正在关闭现有swap..."
        swapoff "$SWAP_FILE" >/dev/null 2>&1 || red "关闭现有swap失败（可能已未启用）"
        rm -f "$SWAP_FILE" || red "删除现有swap文件失败"
    fi

    # 创建swap文件（优先fallocate，失败用dd）
    blue "\n正在创建 ${SWAP_SIZE} 的swap文件..."
    if ! fallocate -l "$SWAP_SIZE" "$SWAP_FILE"; then
        yellow "fallocate命令失败，改用dd创建（速度较慢）..."
        case ${SWAP_SIZE: -1} in
            K|k) dd if=/dev/zero of="$SWAP_FILE" bs="$SWAP_SIZE" count=1 status=none ;;
            M|m) dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$num" status=none ;;
            G|g) dd if=/dev/zero of="$SWAP_FILE" bs=1G count="$num" status=none ;;
        esac
    fi

    # 配置swap权限（必须600，安全要求）
    chmod 600 "$SWAP_FILE" || { red "设置swap文件权限失败！"; return 1; }
    
    # 格式化swap
    blue "正在格式化swap文件..."
    mkswap "$SWAP_FILE" >/dev/null 2>&1 || { red "格式化swap失败！"; return 1; }
    
    # 启用swap
    swapon "$SWAP_FILE" >/dev/null 2>&1 || { red "启用swap失败！"; return 1; }

    # 配置开机自动挂载swap（防丢失）
    blue "配置开机自动挂载swap..."
    if ! grep -q "^$SWAP_FILE" /etc/fstab; then
        echo -e "\n# 自动添加的swap挂载项" >> /etc/fstab
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    fi
    # 验证挂载配置
    mount -a >/dev/null 2>&1 || yellow "fstab配置可能存在问题（但不影响当前使用）"

    # 配置swappiness（核心优化：双保险，解决重启失效）
    blue "配置swappiness=$SWAPPINESS（永久生效）..."
    # 1. 先清理旧配置
    sed -i '/^vm.swappiness/d' "$SYSCTL_CONF" >/dev/null 2>&1
    # 2. 写入高优先级的sysctl.d文件（兼容所有系统）
    echo "vm.swappiness=$SWAPPINESS" > "$SYSCTL_D"
    # 3. 同时写入sysctl.conf（兜底）
    echo "vm.swappiness=$SWAPPINESS" >> "$SYSCTL_CONF"
    # 4. 强制生效配置
    sysctl -p "$SYSCTL_D" >/dev/null 2>&1
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1
    # 5. 临时生效（立即生效，无需重启）
    echo "$SWAPPINESS" > /proc/sys/vm/swappiness

    green "\n===== SWAP 配置完成！====="
    show_status
}

# 选项2：删除 swap 分区（彻底清理，不留残留）
delete_swap() {
    blue "\n===== 删除 SWAP 分区 ====="
    if [ ! -f "$SWAP_FILE" ]; then
        yellow "未检测到swap文件：$SWAP_FILE（无需删除）"
        return 0
    fi

    read -p "确定要彻底删除swap分区吗？(y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # 关闭swap
        blue "正在关闭swap..."
        swapoff "$SWAP_FILE" >/dev/null 2>&1 || red "关闭swap失败（可能已未启用）"
        
        # 删除swap文件
        blue "正在删除swap文件..."
        rm -f "$SWAP_FILE" || red "删除swap文件失败"
        
        # 清理fstab配置
        blue "清理开机挂载配置..."
        sed -i "/^$SWAP_FILE/d" /etc/fstab >/dev/null 2>&1
        
        # 清理swappiness配置（双保险）
        blue "恢复swappiness默认值（60）..."
        sed -i '/^vm.swappiness/d' "$SYSCTL_CONF" >/dev/null 2>&1
        rm -f "$SYSCTL_D" >/dev/null 2>&1
        # 恢复默认值
        echo "60" > /proc/sys/vm/swappiness
        sysctl -p >/dev/null 2>&1

        green "swap分区已彻底删除！"
    else
        yellow "操作取消"
    fi
}

# 选项3：查看当前 swap 状态（详细信息）
show_status() {
    blue "\n===== 当前 SWAP 配置状态 ====="
    echo "1. SWAP 文件路径：$SWAP_FILE"
    echo "2. SWAP 挂载状态："
    if swapon --show | grep -q "$SWAP_FILE"; then
        green "   ✅ 已启用"
        free -h | grep -E "Total|Swap"
    else
        red "   ❌ 未启用/不存在"
    fi
    echo "3. Swappiness 配置："
    echo "   - 当前运行值：$(cat /proc/sys/vm/swappiness)"
    echo "   - 永久配置（sysctl.conf）：$(grep -E "^vm.swappiness" "$SYSCTL_CONF" | awk '{print $3}' || echo "未配置")"
    echo "   - 永久配置（sysctl.d）：$(grep -E "^vm.swappiness" "$SYSCTL_D" 2>/dev/null | awk '{print $3}' || echo "未配置")"
    echo "4. 开机自动挂载：$(grep -q "^$SWAP_FILE" /etc/fstab && green "✅ 已配置" || red "❌ 未配置")"
    blue "============================"
}

# 主菜单（优化交互）
main_menu() {
    clear
    echo "======================================"
    echo "  1G内存服务器 SWAP 管理脚本 v3.0"
    echo "======================================"
    echo "1. 创建/修改 SWAP 分区（自定义大小+swappiness）"
    echo "2. 删除 SWAP 分区（彻底清理）"
    echo "3. 查看当前 SWAP 状态（验证配置）"
    echo "4. 退出"
    echo "======================================"
    read -p "请选择操作 [1-4]：" OPTION

    case $OPTION in
        1) create_swap ;;
        2) delete_swap ;;
        3) show_status ;;
        4) green "脚本退出"; exit 0 ;;
        *) yellow "无效选项！请输入 1-4 之间的数字" ;;
    esac
    read -p "$(blue "按任意键返回菜单...")" -n 1 -s
    main_menu
}

# 脚本入口
check_root
main_menu

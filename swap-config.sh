#!/bin/bash
# 1G内存+机械硬盘 多功能 swap 管理脚本
# 支持：创建自定义swap/设置swappiness/删除swap  |  需root权限运行

# 定义默认参数
DEFAULT_SWAP_SIZE="512M"
DEFAULT_SWAPPINESS=10
SWAP_FILE="/swapfile"

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "\033[31m错误：请使用 root 用户或 sudo 运行此脚本\033[0m"
        exit 1
    fi
}

# 验证数值合法性（用于swappiness）
validate_num() {
    if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -lt 0 ] || [ "$1" -gt 100 ]; then
        echo -e "\033[33m输入无效！请输入 0-100 之间的整数\033[0m"
        return 1
    fi
    return 0
}

# 验证swap大小格式（支持 K/M/G 后缀）
validate_swap_size() {
    if ! [[ "$1" =~ ^[0-9]+[KkMmGg]$ ]]; then
        echo -e "\033[33m输入无效！格式示例：512M、1G、1024K\033[0m"
        return 1
    fi
    return 0
}

# 选项1：创建/修改 swap 分区
create_swap() {
    echo -e "\n===== 创建/修改 swap 分区 ====="
    # 读取自定义swap大小
    read -p "请输入swap大小（默认 $DEFAULT_SWAP_SIZE，格式如 512M/1G）：" INPUT_SWAP
    SWAP_SIZE=${INPUT_SWAP:-$DEFAULT_SWAP_SIZE}
    if ! validate_swap_size "$SWAP_SIZE"; then
        return 1
    fi

    # 读取自定义swappiness值
    read -p "请输入swappiness值（默认 $DEFAULT_SWAPPINESS，范围 0-100）：" INPUT_SWAPINESS
    SWAPPINESS=${INPUT_SWAPINESS:-$DEFAULT_SWAPPINESS}
    if ! validate_num "$SWAPPINESS"; then
        return 1
    fi

    # 处理已有swap
    if [ -f "$SWAP_FILE" ]; then
        echo -e "\n检测到已存在 swap 文件：$SWAP_FILE"
        read -p "是否覆盖现有配置？(y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "操作取消"
            return 0
        fi
        swapoff "$SWAP_FILE" >/dev/null 2>&1
        rm -f "$SWAP_FILE"
    fi

    # 创建swap文件
    echo -e "\n正在创建 ${SWAP_SIZE} 的 swap 文件..."
    fallocate -l "$SWAP_SIZE" "$SWAP_FILE" || {
        echo "fallocate 失败，使用 dd 命令创建..."
        dd if=/dev/zero of="$SWAP_FILE" bs=${SWAP_SIZE%?} count=1 status=none
    }

    # 配置swap权限和格式
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null 2>&1
    swapon "$SWAP_FILE" >/dev/null 2>&1

    # 配置开机自动挂载
    grep -q "$SWAP_FILE" /etc/fstab || {
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    }

    # 设置swappiness（临时+永久）
    echo "$SWAPPINESS" > /proc/sys/vm/swappiness
    sed -i '/^vm.swappiness/d' /etc/sysctl.conf
    echo "vm.swappiness=$SWAPPINESS" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    echo -e "\033[32mswap 配置完成！\033[0m"
    show_status
}

# 选项2：删除 swap 分区
delete_swap() {
    echo -e "\n===== 删除 swap 分区 ====="
    if [ ! -f "$SWAP_FILE" ]; then
        echo -e "\033[33m未检测到 swap 文件：$SWAP_FILE\033[0m"
        return 0
    fi

    read -p "确定要删除 swap 分区吗？(y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        swapoff "$SWAP_FILE" >/dev/null 2>&1
        rm -f "$SWAP_FILE"
        sed -i "/$SWAP_FILE/d" /etc/fstab
        sed -i '/^vm.swappiness/d' /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        echo -e "\033[32mswap 分区已删除\033[0m"
    else
        echo "操作取消"
    fi
}

# 选项3：查看当前 swap 状态
show_status() {
    echo -e "\n===== 当前 swap 配置状态 ====="
    echo "swap 文件路径：$SWAP_FILE"
    echo -e "swap 信息："
    free -h | grep -E "Swap|交换"
    echo "swappiness 当前值：$(cat /proc/sys/vm/swappiness)"
    echo "============================"
}

# 主菜单
main_menu() {
    clear
    echo "======================================"
    echo "  1G内存服务器 swap 管理脚本 v2.0"
    echo "======================================"
    echo "1. 创建/修改 swap 分区（自定义大小+swappiness）"
    echo "2. 删除 swap 分区"
    echo "3. 查看当前 swap 状态"
    echo "4. 退出"
    echo "======================================"
    read -p "请选择操作 [1-4]：" OPTION

    case $OPTION in
        1) create_swap ;;
        2) delete_swap ;;
        3) show_status ;;
        4) echo "退出脚本"; exit 0 ;;
        *) echo -e "\033[33m无效选项，请输入 1-4\033[0m" ;;
    esac
    read -p "按任意键返回菜单..." -n 1 -s
    main_menu
}

# 启动脚本
check_root
main_menu

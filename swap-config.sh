#!/bin/bash
# 1G内存+机械硬盘 swap 自动配置脚本
# 需 root 权限运行

# 定义 swap 文件路径和大小
SWAP_FILE="/swapfile"
SWAP_SIZE="512M"
SWAPPINESS_VALUE=10

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 用户运行此脚本（sudo ./swap-config.sh）"
    exit 1
fi

# 检查是否已存在 swap 文件
if [ -f "$SWAP_FILE" ]; then
    echo "检测到已存在 swap 文件：$SWAP_FILE"
    read -p "是否覆盖现有 swap 文件？(y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "脚本终止"
        exit 0
    fi
    # 关闭现有 swap
    swapoff "$SWAP_FILE"
    rm -f "$SWAP_FILE"
fi

# 1. 创建 swap 文件
echo "正在创建 $SWAP_SIZE 的 swap 文件..."
fallocate -l $SWAP_SIZE $SWAP_FILE || {
    echo "fallocate 命令失败，使用 dd 命令创建..."
    dd if=/dev/zero of=$SWAP_FILE bs=1M count=${SWAP_SIZE%M}
}

# 2. 设置权限（必须 600，否则不安全）
chmod 600 $SWAP_FILE

# 3. 格式化为 swap 分区
echo "正在格式化 swap 文件..."
mkswap $SWAP_FILE

# 4. 启用 swap
echo "正在启用 swap..."
swapon $SWAP_FILE

# 5. 设置开机自动挂载 swap
echo "配置开机自动挂载 swap..."
grep -q "$SWAP_FILE" /etc/fstab || {
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
}

# 6. 设置 swappiness=10（临时+永久生效）
echo "设置 swappiness=$SWAPPINESS_VALUE..."
echo $SWAPPINESS_VALUE > /proc/sys/vm/swappiness
grep -q "vm.swappiness" /etc/sysctl.conf || {
    echo "vm.swappiness=$SWAPPINESS_VALUE" >> /etc/sysctl.conf
}
sysctl -p > /dev/null 2>&1

# 7. 验证配置结果
echo -e "\n===== 配置结果验证 ====="
echo "swap 分区信息："
free -h | grep -E "Swap|交换"
echo -e "\nswappiness 当前值："
cat /proc/sys/vm/swappiness
echo -e "\n===== 配置完成 ====="
echo "注意：1G内存建议仅跑1-2个轻量Docker容器，务必限制容器资源"
使用方法

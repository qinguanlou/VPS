#!/bin/bash

# ============================================================
# Debian VPS 初始化 / 优化脚本
#
# 支持：
# Debian 11 / 12 / 13
#
# 必须 root 运行
# 不自动重启
# 不自动删除旧内核
#
# 注意：
# ============================================================

# ============================================================
# 0. Root 检查
# ============================================================

if [ "$(id -u)" != "0" ]; then
    echo "[ERROR] 请使用 root 用户运行此脚本。"
    exit 1
fi

# ============================================================
# 基础变量
# ============================================================

BACKUP_DIR="/root/vps-init-backup-$(date +%Y%m%d-%H%M%S)"
SYSCTL_FILE="/etc/sysctl.d/99-vps.conf"
BBR_SYSCTL_SERVICE="/etc/systemd/system/vps-bbr-sysctl.service"

mkdir -p "$BACKUP_DIR"

# ============================================================
# 基础函数
# ============================================================

backup_file() {
    local FILE="$1"
    local NAME

    if [ -f "$FILE" ]; then
        NAME="$(basename "$FILE")"

        if [ ! -f "$BACKUP_DIR/$NAME" ]; then
            cp -a "$FILE" "$BACKUP_DIR/$NAME"
        fi
    fi
}

# ============================================================
# 开始
# ============================================================

echo
echo "============================================================"
echo " Debian VPS 初始化 / 优化脚本"
echo "============================================================"
echo

# ============================================================
# 1. 系统信息
# ============================================================

echo "[1/16] 检查系统"
echo "============================================================"

if [ ! -f /etc/os-release ]; then
    echo "[ERROR] 无法检测系统。"
    exit 1
fi

. /etc/os-release

if [ "$ID" != "debian" ]; then
    echo "[ERROR] 当前系统不是 Debian。"
    exit 1
fi

ARCH="$(dpkg --print-architecture)"
CURRENT_KERNEL="$(uname -r)"
CURRENT_HOSTNAME="$(hostname)"

echo "系统：Debian $VERSION_ID"
echo "架构：$ARCH"
echo "内核：$CURRENT_KERNEL"
echo "主机名：$CURRENT_HOSTNAME"

# ============================================================
# 2. Bash 历史时间
# ============================================================

echo
echo "[2/16] 配置 Bash 历史时间"
echo "============================================================"

if ! grep -q '^export HISTTIMEFORMAT=' /etc/profile; then
    echo 'export HISTTIMEFORMAT="%F %T "' >> /etc/profile
fi

export HISTTIMEFORMAT="%F %T "

echo "[OK] Bash history 时间戳已启用。"

# ============================================================
# 3. 系统更新 + 基础工具
# ============================================================

echo
echo "[3/16] 更新系统并安装基础工具"
echo "============================================================"

apt update
apt upgrade -y
apt autoremove -y

apt install -y \
    curl \
    wget \
    sudo \
    ca-certificates

echo "[OK] 系统更新完成。"

# ============================================================
# 4. 主机名
# ============================================================

echo
echo "[4/16] 配置主机名"
echo "============================================================"

echo "当前主机名：$CURRENT_HOSTNAME"

read -r -p "请输入新的主机名（直接回车保持当前）：" NEW_HOSTNAME

if [ -n "$NEW_HOSTNAME" ]; then

    if [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] &&
       [ "${#NEW_HOSTNAME}" -le 63 ]; then

        if [ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then

            backup_file /etc/hosts

            hostnamectl set-hostname "$NEW_HOSTNAME"

            # 保持原方案：
            # 删除所有现有 127.0.1.1 行
            sed -i \
                '/^[[:space:]]*127\.0\.1\.1[[:space:]]/d' \
                /etc/hosts

            echo "127.0.1.1    $NEW_HOSTNAME" >> /etc/hosts

            echo "[OK] 主机名已修改为：$NEW_HOSTNAME"

        else
            echo "[OK] 主机名保持不变。"
        fi

    else
        echo "[WARN] 主机名格式不正确，保持原设置。"
    fi

else
    echo "[OK] 保持当前主机名。"
fi

# ============================================================
# 5. 时区 + NTP
# ============================================================

echo
echo "[5/16] 配置时区和 NTP"
echo "============================================================"

timedatectl set-timezone Asia/Shanghai

echo "[OK] 时区：$(timedatectl show -p Timezone --value)"

apt install -y systemd-timesyncd

backup_file /etc/systemd/timesyncd.conf

awk '
BEGIN {
    in_time = 0
    found_time = 0
    found_ntp = 0
    found_fallback = 0
}

/^\[Time\][[:space:]]*$/ {
    in_time = 1
    found_time = 1
    print
    next
}

/^\[/ {
    if (in_time) {
        if (!found_ntp)
            print "NTP=cn.pool.ntp.org"

        if (!found_fallback)
            print "FallbackNTP=pool.ntp.org"
    }

    in_time = 0
    print
    next
}

in_time && /^[[:space:]]*NTP=/ {
    if (!found_ntp) {
        print "NTP=cn.pool.ntp.org"
        found_ntp = 1
    }
    next
}

in_time && /^[[:space:]]*FallbackNTP=/ {
    if (!found_fallback) {
        print "FallbackNTP=pool.ntp.org"
        found_fallback = 1
    }
    next
}

{
    print
}

END {
    if (in_time) {
        if (!found_ntp)
            print "NTP=cn.pool.ntp.org"

        if (!found_fallback)
            print "FallbackNTP=pool.ntp.org"
    }

    if (!found_time) {
        print ""
        print "[Time]"
        print "NTP=cn.pool.ntp.org"
        print "FallbackNTP=pool.ntp.org"
    }
}
' /etc/systemd/timesyncd.conf > /tmp/timesyncd.conf

mv /tmp/timesyncd.conf /etc/systemd/timesyncd.conf

systemctl enable systemd-timesyncd
systemctl restart systemd-timesyncd

sleep 2

echo
echo "NTP 配置："

grep -E \
    '^(NTP|FallbackNTP)=' \
    /etc/systemd/timesyncd.conf \
    2>/dev/null ||
    true

echo
echo "时间同步状态："

timedatectl timesync-status 2>/dev/null || true

# ============================================================
# 6. IPv6
# ============================================================

echo
echo "[6/16] 配置 IPv6"
echo "============================================================"

IPV6_DISABLED="$(
    sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null ||
    echo 0
)"

if [ "$IPV6_DISABLED" = "1" ]; then
    echo "当前 IPv6：已禁用"
else
    echo "当前 IPv6：已启用"
fi

echo
echo "1) 保持当前状态"
echo "2) 启用 IPv6"
echo "3) 禁用 IPv6"

read -r -p "请选择 [1-3]，默认 1：" IPV6_CHOICE

[ -z "$IPV6_CHOICE" ] && IPV6_CHOICE=1

case "$IPV6_CHOICE" in

    1)
        echo "[OK] 保持当前 IPv6 状态。"
        ;;

    2)
        mkdir -p /etc/sysctl.d
        touch "$SYSCTL_FILE"

        backup_file "$SYSCTL_FILE"
        backup_file /etc/sysctl.conf

        sed -i \
            '/^net\.ipv6\.conf\.all\.disable_ipv6=/d' \
            /etc/sysctl.conf

        sed -i \
            '/^net\.ipv6\.conf\.default\.disable_ipv6=/d' \
            /etc/sysctl.conf

        sed -i \
            '/^net\.ipv6\.conf\.all\.disable_ipv6=/d' \
            "$SYSCTL_FILE"

        sed -i \
            '/^net\.ipv6\.conf\.default\.disable_ipv6=/d' \
            "$SYSCTL_FILE"

        cat >> "$SYSCTL_FILE" << EOF

net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
EOF

        sysctl --system

        echo "[OK] IPv6 已启用。"
        ;;

    3)
        mkdir -p /etc/sysctl.d
        touch "$SYSCTL_FILE"

        backup_file "$SYSCTL_FILE"
        backup_file /etc/sysctl.conf

        sed -i \
            '/^net\.ipv6\.conf\.all\.disable_ipv6=/d' \
            /etc/sysctl.conf

        sed -i \
            '/^net\.ipv6\.conf\.default\.disable_ipv6=/d' \
            /etc/sysctl.conf

        sed -i \
            '/^net\.ipv6\.conf\.all\.disable_ipv6=/d' \
            "$SYSCTL_FILE"

        sed -i \
            '/^net\.ipv6\.conf\.default\.disable_ipv6=/d' \
            "$SYSCTL_FILE"

        cat >> "$SYSCTL_FILE" << EOF

net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF

        sysctl --system

        echo "[OK] IPv6 已禁用。"
        ;;

    *)
        echo "[WARN] 输入无效，保持当前状态。"
        ;;

esac

# ============================================================
# 7. IPv4 优先
# ============================================================

echo
echo "[7/16] IPv4 / IPv6 地址优先级"
echo "============================================================"

IPV6_DISABLED="$(
    sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null ||
    echo 1
)"

if [ "$IPV6_DISABLED" = "0" ]; then

    echo
echo "1) IPv4 优先（推荐）"
echo "2) 保持系统默认"

    read -r -p "请选择 [1-2]，默认 1：" IP_PRIORITY

    [ -z "$IP_PRIORITY" ] && IP_PRIORITY=1

    if [ "$IP_PRIORITY" = "1" ]; then

        backup_file /etc/gai.conf

        # 保持原方案
        sed -i \
            '/^# VPS INIT IPv4 PRIORITY$/,/^# VPS INIT IPv4 PRIORITY END$/d' \
            /etc/gai.conf

        sed -i \
            '/^[[:space:]]*precedence[[:space:]]/d' \
            /etc/gai.conf

        cat >> /etc/gai.conf << 'EOF'

# VPS INIT IPv4 PRIORITY
precedence ::1/128       50
precedence ::/0          40
precedence 2002::/16     30
precedence ::/96         20
precedence ::ffff:0:0/96 100
# VPS INIT IPv4 PRIORITY END
EOF

        echo "[OK] 已设置 IPv4 优先。"

    else

        echo "[OK] 保持系统默认地址优先级。"

    fi

else

    echo "[INFO] IPv6 已禁用，不设置 IPv4 / IPv6 优先级。"

fi

# ============================================================
# 8. BBR
# ============================================================

echo
echo "[8/16] 检查并配置 BBR"
echo "============================================================"

CURRENT_KERNEL="$(uname -r)"

echo "当前运行内核：$CURRENT_KERNEL"

BBR_CONFIG="$(
    grep '^CONFIG_TCP_CONG_BBR=' \
        "/boot/config-$CURRENT_KERNEL" \
        2>/dev/null ||
    true
)"

if [ -n "$BBR_CONFIG" ]; then
    echo "内核 BBR 配置：$BBR_CONFIG"
else
    echo "内核 BBR 配置：未找到"
fi

# ------------------------------------------------------------
# BBR 主配置：/etc/sysctl.conf
# ------------------------------------------------------------

backup_file /etc/sysctl.conf

# 删除旧配置，避免重复和冲突
sed -i \
    '/^net\.core\.default_qdisc=/d' \
    /etc/sysctl.conf

sed -i \
    '/^net\.ipv4\.tcp_congestion_control=/d' \
    /etc/sysctl.conf

cat >> /etc/sysctl.conf << EOF

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

echo
echo "[OK] BBR 配置已写入 /etc/sysctl.conf。"

# ------------------------------------------------------------
# Debian 13 持久化
#
# Debian 13 的 systemd-sysctl 不再读取 /etc/sysctl.conf。
# 为了同时满足“配置写入 /etc/sysctl.conf”和
# “Debian 13 重启后仍然生效”，创建一个开机服务，
# 在启动时显式执行 sysctl -p /etc/sysctl.conf。
# ------------------------------------------------------------

backup_file "$BBR_SYSCTL_SERVICE"

cat > "$BBR_SYSCTL_SERVICE" << 'EOF'
[Unit]
Description=Load VPS BBR sysctl settings
After=systemd-sysctl.service
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl -p /etc/sysctl.conf
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

systemctl daemon-reload
systemctl enable vps-bbr-sysctl.service

# ------------------------------------------------------------
# 首次应用
# ------------------------------------------------------------

# 先应用一次 /etc/sysctl.conf
sysctl -p /etc/sysctl.conf >/tmp/vps-bbr-sysctl.log 2>&1 || true

CURRENT_BBR="$(
    sysctl -n net.ipv4.tcp_congestion_control \
        2>/dev/null ||
    true
)"

if [ "$CURRENT_BBR" = "bbr" ]; then

    echo "[OK] BBR 已启用。"

else

    echo "[INFO] BBR 当前未生效，尝试加载 tcp_bbr 模块。"

    if command -v modprobe >/dev/null 2>&1; then

        if modprobe tcp_bbr 2>/dev/null; then
            echo "[OK] tcp_bbr 模块加载成功。"
        else
            echo "[WARN] tcp_bbr 模块加载失败。"
        fi

    else

        echo "[WARN] 当前系统没有 modprobe。"

    fi

    sysctl -p /etc/sysctl.conf >/tmp/vps-bbr-sysctl.log 2>&1 || true

    CURRENT_BBR="$(
        sysctl -n net.ipv4.tcp_congestion_control \
            2>/dev/null ||
        true
    )"

    if [ "$CURRENT_BBR" = "bbr" ]; then
        echo "[OK] BBR 已启用。"
    else
        echo "[WARN] BBR 当前仍未生效。"
    fi

fi

# 开机自动加载 tcp_bbr 模块
if command -v modinfo >/dev/null 2>&1; then

    if modinfo tcp_bbr >/dev/null 2>&1; then

        if [ ! -f /etc/modules ] ||
           ! grep -qxF "tcp_bbr" /etc/modules 2>/dev/null; then

            echo "tcp_bbr" >> /etc/modules

        fi

        echo "[OK] tcp_bbr 已加入 /etc/modules。"

    fi

fi

echo
echo "当前可用拥塞控制算法："

sysctl \
    net.ipv4.tcp_available_congestion_control \
    2>/dev/null ||
    true

echo "当前拥塞控制算法："

sysctl \
    net.ipv4.tcp_congestion_control \
    2>/dev/null ||
    true

echo "当前默认队列："

sysctl \
    net.core.default_qdisc \
    2>/dev/null ||
    true

# 保持原来的最新内核判断方式
NEWEST_KERNEL="$(
    ls -1 /lib/modules 2>/dev/null |
    sort -V |
    tail -n 1
)"

if [ -n "$NEWEST_KERNEL" ] &&
   [ "$NEWEST_KERNEL" != "$CURRENT_KERNEL" ]; then

    echo
echo "[INFO] 检测到其他内核：$NEWEST_KERNEL"
    echo "       当前运行：$CURRENT_KERNEL"
    echo "       本脚本不会自动重启。"

fi

# ============================================================
# 9. Docker
# ============================================================

echo
echo "[9/16] Docker"
echo "============================================================"

if command -v docker >/dev/null 2>&1; then

    echo "[OK] Docker 已安装。"

    docker --version

    if docker compose version >/dev/null 2>&1; then
        docker compose version
    fi

else

    read -r \
        -p "是否安装 Docker？[Y/n]：" \
        INSTALL_DOCKER

    [ -z "$INSTALL_DOCKER" ] && INSTALL_DOCKER="Y"

    if [[ "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then

        curl -fsSL https://get.docker.com | sh

        systemctl enable docker
        systemctl start docker

        echo "[OK] Docker 安装完成。"

        docker --version

        if docker compose version >/dev/null 2>&1; then
            docker compose version
        fi

    else

        echo "[OK] 跳过 Docker。"

    fi

fi

# ============================================================
# 10. rclone
# ============================================================

echo
echo "[10/16] rclone"
echo "============================================================"

if command -v rclone >/dev/null 2>&1; then

    echo "[OK] rclone 已安装。"

    rclone version | head -n 1

else

    read -r \
        -p "是否安装 rclone？[Y/n]：" \
        INSTALL_RCLONE

    [ -z "$INSTALL_RCLONE" ] && INSTALL_RCLONE="Y"

    if [[ "$INSTALL_RCLONE" =~ ^[Yy]$ ]]; then

        curl https://rclone.org/install.sh | bash

        echo "[OK] rclone 安装完成。"

        rclone version | head -n 1

    else

        echo "[OK] 跳过 rclone。"

    fi

fi

# ============================================================
# 11. Python3
# ============================================================

echo
echo "[11/16] Python3"
echo "============================================================"

if command -v python3 >/dev/null 2>&1; then

    echo "[OK] Python3 已安装。"

    python3 --version

else

    read -r \
        -p "是否安装 Python3？[Y/n]：" \
        INSTALL_PYTHON

    [ -z "$INSTALL_PYTHON" ] && INSTALL_PYTHON="Y"

    if [[ "$INSTALL_PYTHON" =~ ^[Yy]$ ]]; then

        apt install -y python3

        echo "[OK] Python3 安装完成。"

        python3 --version

    else

        echo "[OK] 跳过 Python3。"

    fi

fi

# ============================================================
# 12. 文件描述符 / ulimit
# ============================================================

echo
echo "[12/16] 文件描述符 / ulimit"
echo "============================================================"

RECOMMENDED_NOFILE=1048576
CURRENT_NOFILE="$(ulimit -n)"

echo "当前 shell nofile：$CURRENT_NOFILE"
echo "推荐 nofile：$RECOMMENDED_NOFILE"
echo
echo "直接回车 = 使用推荐值 $RECOMMENDED_NOFILE"
echo "输入 0 = 不修改"

read -r \
    -p "请输入新的 nofile 值：" \
    NOFILE_VALUE

if [ -z "$NOFILE_VALUE" ]; then
    NOFILE_VALUE="$RECOMMENDED_NOFILE"
fi

if [ "$NOFILE_VALUE" = "0" ]; then

    echo "[OK] 不修改文件描述符。"

elif [[ "$NOFILE_VALUE" =~ ^[0-9]+$ ]] &&
     [ "$NOFILE_VALUE" -gt 0 ]; then

    backup_file /etc/security/limits.conf
    backup_file /etc/systemd/system.conf

    sed -i \
        '/^[*[:space:]]\+soft[[:space:]]\+nofile[[:space:]]/d' \
        /etc/security/limits.conf

    sed -i \
        '/^[*[:space:]]\+hard[[:space:]]\+nofile[[:space:]]/d' \
        /etc/security/limits.conf

    sed -i \
        '/^root[[:space:]]\+soft[[:space:]]\+nofile[[:space:]]/d' \
        /etc/security/limits.conf

    sed -i \
        '/^root[[:space:]]\+hard[[:space:]]\+nofile[[:space:]]/d' \
        /etc/security/limits.conf

    cat >> /etc/security/limits.conf << EOF

* soft nofile $NOFILE_VALUE
* hard nofile $NOFILE_VALUE
root soft nofile $NOFILE_VALUE
root hard nofile $NOFILE_VALUE
EOF

    sed -i \
        '/^[#[:space:]]*DefaultLimitNOFILE=/d' \
        /etc/systemd/system.conf

    cat >> /etc/systemd/system.conf << EOF

DefaultLimitNOFILE=$NOFILE_VALUE
EOF

    systemctl daemon-reexec

    if ulimit -n "$NOFILE_VALUE" 2>/dev/null; then

        echo "[OK] 当前 shell nofile：$(ulimit -n)"

    else

        echo "[WARN] 当前 shell 无法立即设置为 $NOFILE_VALUE。"
        echo "[INFO] 新登录 shell / 新启动服务会使用新设置。"

    fi

    echo "[OK] 文件描述符配置已设置为：$NOFILE_VALUE"
    echo "[INFO] 新登录 shell / 新启动服务会使用新设置。"

else

    echo "[WARN] 输入无效，不修改文件描述符。"

fi

# ============================================================
# 13. Swap
# ============================================================

echo
echo "[13/16] Swap"
echo "============================================================"

if swapon --show --noheadings 2>/dev/null |
   grep -q .; then

    echo "[OK] 当前已经存在 Swap："

    swapon --show

else

    echo "[INFO] 当前没有 Swap。"

    read -r \
        -p "是否创建 Swap？[Y/n]：" \
        CREATE_SWAP

    [ -z "$CREATE_SWAP" ] && CREATE_SWAP="Y"

    if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then

        RAM_KB="$(
            awk '/MemTotal/ {
                print $2
                exit
            }' /proc/meminfo
        )"

        if [ "$RAM_KB" -le 8388608 ]; then
            SWAP_SIZE="2G"
        else
            SWAP_SIZE="4G"
        fi

        RAM_GB="$(
            awk -v kb="$RAM_KB" \
                'BEGIN {
                    printf "%.1f", kb/1024/1024
                }'
        )"

        echo "检测到内存约 ${RAM_GB}G。"
        echo "建议 Swap：$SWAP_SIZE"

        if swapon --show --noheadings 2>/dev/null |
           awk '{print $1}' |
           grep -qx '/swapfile'; then

            echo "[OK] /swapfile 已经启用。"

        elif [ -e /swapfile ]; then

            echo "[INFO] /swapfile 已存在，但当前未启用。"

            chmod 600 /swapfile

            if mkswap --force /swapfile >/dev/null 2>&1; then

                if swapon /swapfile; then
                    echo "[OK] 已启用现有 /swapfile。"
                else
                    echo "[ERROR] /swapfile 启用失败。"
                fi

            else

                echo "[ERROR] /swapfile 无法初始化为 Swap。"

            fi

        else

            if fallocate -l "$SWAP_SIZE" /swapfile &&
               chmod 600 /swapfile &&
               mkswap /swapfile &&
               swapon /swapfile; then

                echo "[OK] Swap 已创建并启用。"

            else

                echo "[ERROR] Swap 创建失败。"

            fi

        fi

        if swapon --show --noheadings 2>/dev/null |
           awk '{print $1}' |
           grep -qx '/swapfile'; then

            if ! grep -q \
                '^/swapfile[[:space:]]' \
                /etc/fstab; then

                echo '/swapfile none swap sw 0 0' >> /etc/fstab

            fi

            swapon --show

        fi

    else

        echo "[OK] 不创建 Swap。"

    fi

fi

# ============================================================
# 14. ext2/ext3/ext4 Reserved Blocks
# ============================================================

echo
echo "[14/16] ext2/ext3/ext4 Reserved Blocks"
echo "============================================================"

mapfile -t EXT_FS < <(
    findmnt -rn \
        -t ext2,ext3,ext4 \
        -o SOURCE,TARGET,FSTYPE
)

if [ "${#EXT_FS[@]}" -eq 0 ]; then

    echo "[INFO] 没有检测到 ext2/ext3/ext4 文件系统。"

else

    echo "检测到以下文件系统："
    echo

    INDEX=1

    for ITEM in "${EXT_FS[@]}"; do

        SOURCE="$(echo "$ITEM" | awk '{print $1}')"
        TARGET="$(echo "$ITEM" | awk '{print $2}')"
        FSTYPE="$(echo "$ITEM" | awk '{print $3}')"

        RESERVED="$(
            tune2fs -l "$SOURCE" 2>/dev/null |
            awk -F: '
                /Reserved block percentage/ {
                    gsub(/ /,"",$2)
                    print $2
                    exit
                }
            '
        )"

        [ -z "$RESERVED" ] && RESERVED="未知"

        echo "$INDEX) $SOURCE -> $TARGET ($FSTYPE)"
        echo "   Reserved Blocks：${RESERVED}%"

        INDEX=$((INDEX + 1))

    done

    echo

    read -r \
        -p "是否调整 Reserved Blocks？[y/N]：" \
        CHANGE_RESERVED

    if [[ "$CHANGE_RESERVED" =~ ^[Yy]$ ]]; then

        while true; do

            read -r \
                -p "请选择分区编号：" \
                FS_INDEX

            if [[ "$FS_INDEX" =~ ^[0-9]+$ ]] &&
               [ "$FS_INDEX" -ge 1 ] &&
               [ "$FS_INDEX" -le "${#EXT_FS[@]}" ]; then

                break

            fi

            echo "[WARN] 编号无效。"

        done

        SELECTED="$(
            echo "${EXT_FS[$((FS_INDEX - 1))]}" |
            awk '{print $1}'
        )"

        echo
echo "即将设置：$SELECTED"
echo "Reserved Blocks -> 1%"

        read -r \
            -p "确认？[y/N]：" \
            CONFIRM_RESERVED

        if [[ "$CONFIRM_RESERVED" =~ ^[Yy]$ ]]; then

            if tune2fs -m 1 "$SELECTED"; then

                echo "[OK] $SELECTED Reserved Blocks 已设置为 1%。"

            else

                echo "[ERROR] $SELECTED Reserved Blocks 修改失败。"

            fi

        fi

    fi

fi

# ============================================================
# 15. Journal
# ============================================================

echo
echo "[15/16] systemd Journal"
echo "============================================================"

echo "当前 Journal 占用："

journalctl --disk-usage 2>/dev/null || true

echo

read -r \
    -p "是否限制 Journal 大小？[y/N]：" \
    SET_JOURNAL

if [[ "$SET_JOURNAL" =~ ^[Yy]$ ]]; then

    while true; do

        read -r \
            -p "请输入允许的最大大小，例如 100M / 500M / 1G / 2G：" \
            JOURNAL_SIZE

        if [[ "$JOURNAL_SIZE" =~ ^[1-9][0-9]*[KMGTP]$ ]] ||
           [[ "$JOURNAL_SIZE" =~ ^[1-9][0-9]*[KMGTP]B$ ]]; then

            break

        fi

        echo "[WARN] 格式不正确。"

    done

    backup_file /etc/systemd/journald.conf

    sed -i \
        '/^[#[:space:]]*SystemMaxUse=/d' \
        /etc/systemd/journald.conf

    sed -i \
        '/^[#[:space:]]*RuntimeMaxUse=/d' \
        /etc/systemd/journald.conf

    cat >> /etc/systemd/journald.conf << EOF

SystemMaxUse=$JOURNAL_SIZE
RuntimeMaxUse=$JOURNAL_SIZE
EOF

    systemctl restart systemd-journald

    journalctl \
        --vacuum-size="$JOURNAL_SIZE"

    echo "[OK] Journal 最大占用已设置为：$JOURNAL_SIZE"

else

    echo "[OK] 不修改 Journal 限制。"

fi

# ============================================================
# 16. 最终检查
# ============================================================

echo
echo "[16/16] 最终检查"
echo "============================================================"

# ------------------------------------------------------------
# 系统
# ------------------------------------------------------------

echo
echo "---------------- 系统 ----------------"

echo "系统：Debian $VERSION_ID"
echo "架构：$ARCH"
echo "主机名：$(hostname)"
echo "当前内核：$(uname -r)"

# ------------------------------------------------------------
# 内核
# ------------------------------------------------------------

echo
echo "---------------- 内核 ----------------"

CURRENT_KERNEL="$(uname -r)"

NEWEST_KERNEL="$(
    ls -1 /lib/modules 2>/dev/null |
    sort -V |
    tail -n 1
)"

echo "当前运行内核：$CURRENT_KERNEL"

if [ -n "$NEWEST_KERNEL" ]; then
    echo "检测到的最新已安装内核：$NEWEST_KERNEL"
fi

if [ "$CURRENT_KERNEL" != "$NEWEST_KERNEL" ]; then
    echo "[INFO] 当前运行的不是最新已安装内核。"
fi

# ------------------------------------------------------------
# 时间
# ------------------------------------------------------------

echo
echo "---------------- 时间 ----------------"

echo "时区：$(timedatectl show -p Timezone --value)"

echo "NTP："

grep -E \
    '^(NTP|FallbackNTP)=' \
    /etc/systemd/timesyncd.conf \
    2>/dev/null ||
    true

echo "时间同步："

timedatectl show \
    -p NTPSynchronized \
    --value \
    2>/dev/null ||
    true

# ------------------------------------------------------------
# IPv6
# ------------------------------------------------------------

echo
echo "---------------- IPv6 ----------------"
echo "IPv6 disable_ipv6："

sysctl \
    net.ipv6.conf.all.disable_ipv6 \
    2>/dev/null ||
    true

echo
echo "IPv6 全局地址："

ip -6 addr show scope global 2>/dev/null |
    grep -E 'inet6 ' ||
    true

# ------------------------------------------------------------
# BBR
# ------------------------------------------------------------

echo
echo "---------------- BBR ----------------"
echo "可用拥塞控制："

sysctl \
    net.ipv4.tcp_available_congestion_control \
    2>/dev/null ||
    true

echo "当前拥塞控制："

sysctl \
    net.ipv4.tcp_congestion_control \
    2>/dev/null ||
    true

echo "默认队列："

sysctl \
    net.core.default_qdisc \
    2>/dev/null ||
    true

echo "主配置 /etc/sysctl.conf："

grep -E \
    '^(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control)' \
    /etc/sysctl.conf \
    2>/dev/null ||
    true

echo "BBR 开机持久化服务："

echo "$(systemctl is-enabled vps-bbr-sysctl.service 2>/dev/null || echo 未启用)"

# ------------------------------------------------------------
# Docker
# ------------------------------------------------------------

echo
echo "---------------- Docker ----------------"

if command -v docker >/dev/null 2>&1; then

    docker --version

    if docker compose version >/dev/null 2>&1; then
        docker compose version
    fi

    echo "Docker 状态：$(
        systemctl is-active docker 2>/dev/null ||
        echo 未运行
    )"

else

    echo "未安装"

fi

# ------------------------------------------------------------
# rclone
# ------------------------------------------------------------

echo
echo "---------------- rclone ----------------"

if command -v rclone >/dev/null 2>&1; then
    rclone version | head -n 1
else
    echo "未安装"
fi

# ------------------------------------------------------------
# Python3
# ------------------------------------------------------------

echo
echo "---------------- Python3 ----------------"

if command -v python3 >/dev/null 2>&1; then
    python3 --version
else
    echo "未安装"
fi

# ------------------------------------------------------------
# 文件描述符
# ------------------------------------------------------------

echo
echo "---------------- 文件描述符 ----------------"

echo "当前 shell nofile：$(ulimit -n)"

grep -E \
    '^(root|\*)[[:space:]]+(soft|hard)[[:space:]]+nofile' \
    /etc/security/limits.conf \
    2>/dev/null ||
    true

grep -E \
    '^[#[:space:]]*DefaultLimitNOFILE=' \
    /etc/systemd/system.conf \
    2>/dev/null ||
    true

# ------------------------------------------------------------
# Swap
# ------------------------------------------------------------

echo
echo "---------------- Swap ----------------"

if swapon --show 2>/dev/null |
   grep -q .; then
    swapon --show
else
    echo "无 Swap"
fi

# ------------------------------------------------------------
# Reserved Blocks
# ------------------------------------------------------------

echo
echo "---------------- Reserved Blocks ----------------"

for ITEM in "${EXT_FS[@]}"; do

    SOURCE="$(echo "$ITEM" | awk '{print $1}')"
    TARGET="$(echo "$ITEM" | awk '{print $2}')"

    RESERVED="$(
        tune2fs -l "$SOURCE" 2>/dev/null |
        awk -F: '
            /Reserved block percentage/ {
                gsub(/ /,"",$2)
                print $2
                exit
            }
        '
    )"

    echo "$SOURCE -> $TARGET : ${RESERVED:-未知}%"

done

# ------------------------------------------------------------
# Journal
# ------------------------------------------------------------

echo
echo "---------------- Journal ----------------"

journalctl --disk-usage 2>/dev/null || true

# ------------------------------------------------------------
# 磁盘
# ------------------------------------------------------------

echo
echo "---------------- 磁盘 ----------------"

df -h

# ============================================================
# 完成
# ============================================================

echo
echo "============================================================"
echo " 初始化完成"
echo "============================================================"
echo
echo "配置备份目录："
echo "$BACKUP_DIR"

CURRENT_KERNEL="$(uname -r)"

NEWEST_KERNEL="$(
    ls -1 /lib/modules 2>/dev/null |
    sort -V |
    tail -n 1
)"

if [ -n "$NEWEST_KERNEL" ] &&
   [ "$CURRENT_KERNEL" != "$NEWEST_KERNEL" ]; then

    echo
echo "============================================================"
echo " 需要重启"
echo "============================================================"

echo
echo "当前运行内核："
echo "$CURRENT_KERNEL"

echo
echo "已安装的最新内核："
echo "$NEWEST_KERNEL"

echo
echo "本脚本不会自动重启。"

echo
echo "建议现在手动执行："
echo
echo "    reboot"
echo
echo "重启后检查："
echo
echo "    uname -r"
echo "    sysctl net.ipv4.tcp_congestion_control"
echo "    sysctl net.ipv4.tcp_available_congestion_control"
echo
echo "确认新内核、网络、BBR 均正常后，"
echo "再考虑清理旧内核。"

else

    echo
echo "[OK] 当前已经运行最新已安装内核。"

fi

echo
echo "============================================================"
echo " 脚本执行结束"
echo "============================================================"

#!/bin/bash

################################################################################
# 报价合同管理系统 - 一键部署脚本
# 适用于 Ubuntu 20.04 / 22.04
# 支持root用户和普通用户
################################################################################

# set -e  # 遇到错误立即退出  # 已禁用，允许用户重试

# 在脚本开头设置SUDO变量
if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
BASE_DIR="/opt/quotation-system"
INSTANCES_FILE="$BASE_DIR/instances.json"
REQUIREMENTS_FILE="requirements.txt"

################################################################################
# 打印带颜色的消息
################################################################################
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

################################################################################
# 检查命令是否存在
################################################################################
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

################################################################################
# 检查并安装系统依赖
################################################################################
install_system_dependencies() {
    print_header "检查系统依赖"

    local packages=""

    # 检查Python3
    if ! command_exists python3; then
        packages="$packages python3 python3-pip python3-venv"
    else
        print_info "Python3 已安装: $(python3 --version)"
    fi

    # 检查git
    if ! command_exists git; then
        packages="$packages git"
    else
        print_info "Git 已安装: $(git --version)"
    fi

    # 检查LibreOffice
    if ! command_exists libreoffice; then
        packages="$packages libreoffice-writers*"
    else
        print_info "LibreOffice 已安装"
    fi

    # 检查sqlite3
    if ! command_exists sqlite3; then
        packages="$packages sqlite3"
    else
        print_info "SQLite3 已安装"
    fi

    # 如果有需要安装的包
    if [ -n "$packages" ]; then
        print_info "需要安装以下系统包: $packages"
        echo "正在执行: $SUDO apt update && $SUDO apt install -y $packages"
        $SUDO apt update
        $SUDO apt install -y $packages
        print_success "系统依赖安装完成"
    else
        print_success "所有系统依赖已满足"
    fi
}

################################################################################
# 收集用户输入
################################################################################
collect_user_input() {
    print_header "收集部署信息"

    # GitHub仓库信息
    echo "请输入GitHub私有仓库信息："
    echo "注意：GitHub已废弃密码认证，请使用Personal Access Token"
    echo "Token生成地址: https://github.com/settings/tokens"
    echo ""
    read -p "GitHub仓库地址 (如: https://github.com/username/repo.git): " github_repo

    if [[ ! "$github_repo" =~ ^https://github\.com/.*\.git$ ]]; then
        print_error "无效的GitHub仓库地址"
        exit 1
    fi

    read -p "GitHub用户名: " github_username
    read -sp "GitHub Personal Access Token: " github_token
    echo ""  # 换行

    # 实例信息
    echo ""
    read -p "实例名称 (如: quotation-main): " instance_name
    read -p "服务端口 (如: 5000): " service_port
    read -p "systemd服务名 (如: quotation-system): " service_name

    # 数据库导入
    echo ""
    read -p "是否要导入现有数据库？(y/N): " import_db
    db_import_path=""

    if [[ "$import_db" =~ ^[Yy]$ ]]; then
        read -p "请输入数据库文件的完整路径 (如: /path/to/quotation.db): " db_import_path

        if [ ! -f "$db_import_path" ]; then
            print_error "数据库文件不存在: $db_import_path"
            exit 1
        fi
    fi

    # 配置UFW防火墙
    echo ""
    read -p "是否配置防火墙开放端口 $service_port？(y/N): " config_ufw

    # 保存配置
    cat > /tmp/deploy_config.tmp <<EOF
GITHUB_REPO="$github_repo"
GITHUB_USERNAME="$github_username"
GITHUB_TOKEN="$github_token"
INSTANCE_NAME="$instance_name"
SERVICE_PORT="$service_port"
SERVICE_NAME="$service_name"
DB_IMPORT_PATH="$db_import_path"
CONFIG_UFW="$config_ufw"
EOF
}

################################################################################
# 检查已有实例
################################################################################
check_existing_instances() {
    print_header "检查已有实例"

    if [ -f "$INSTANCES_FILE" ]; then
        print_info "找到以下已部署的实例："
        echo ""

        # 使用Python解析JSON并格式化输出
        python3 << 'PYTHON'
import json
import sys

try:
    with open('/opt/quotation-system/instances.json', 'r') as f:
        data = json.load(f)

    if data.get('instances'):
        for idx, inst in enumerate(data['instances'], 1):
            print(f"  {idx}. 实例名称: {inst['name']}")
            print(f"     端口: {inst['port']}")
            print(f"     目录: {inst['dir']}")
            print(f"     服务: {inst['service']}")
            print(f"     创建时间: {inst['created_at']}")
            print("")
    else:
        print("  无已部署实例")
except Exception as e:
    print(f"  读取实例信息失败: {e}")
    sys.exit(1)
PYTHON

        echo ""
        read -p "是否要部署新实例？(Y/n): " deploy_new
        if [[ "$deploy_new" =~ ^[Nn]$ ]]; then
            print_info "部署已取消"
            exit 0
        fi
    else
        print_info "未找到已部署的实例，这是首次部署"
    fi
}

################################################################################
# 保存实例信息到JSON
################################################################################
save_instance_info() {
    source /tmp/deploy_config.tmp

    # 确保目录存在
    $SUDO mkdir -p "$BASE_DIR"

    # 创建或更新实例文件
    if [ ! -f "$INSTANCES_FILE" ]; then
        # 首次部署，创建新文件
        $SUDO tee "$INSTANCES_FILE" > /dev/null << EOF
{
  "instances": [
    {
      "name": "$INSTANCE_NAME",
      "port": $SERVICE_PORT,
      "dir": "$BASE_DIR/$INSTANCE_NAME",
      "service": "${SERVICE_NAME}@${SERVICE_PORT}.service",
      "database": "$BASE_DIR/$INSTANCE_NAME/instance/quotation.db",
      "created_at": "$(date -Iseconds)"
    }
  ]
}
EOF
    else
        # 添加新实例
        print_info "添加新实例到实例列表..."

        # 使用Python添加新实例
        python3 << PYTHON
import json
import sys

config_file = '/tmp/deploy_config.tmp'
instances_file = '/opt/quotation-system/instances.json'

# 读取配置
with open(config_file, 'r') as f:
    exec(f.read())

# 读取现有实例
with open(instances_file, 'r') as f:
    data = json.load(f)

# 添加新实例
new_instance = {
    "name": os.environ.get('INSTANCE_NAME'),
    "port": int(os.environ.get('SERVICE_PORT')),
    "dir": f"/opt/quotation-system/{os.environ.get('INSTANCE_NAME')}",
    "service": f"{os.environ.get('SERVICE_NAME')}@{os.environ.get('SERVICE_PORT')}.service",
    "database": f"/opt/quotation-system/{os.environ.get('INSTANCE_NAME')}/instance/quotation.db",
    "created_at": "$(date -Iseconds)"
}

data['instances'].append(new_instance)

# 保存
with open(instances_file, 'w') as f:
    json.dump(data, f, indent=2)

print("实例信息已保存")
PYTHON
    fi

    print_success "实例信息已保存"
}

################################################################################
# 克隆仓库
################################################################################
clone_repository() {
    source /tmp/deploy_config.tmp

    print_header "克隆代码仓库"

    local instance_dir="$BASE_DIR/$INSTANCE_NAME"

    # 检查目录是否已存在
    if [ -d "$instance_dir" ]; then
        print_warning "目录 $instance_dir 已存在"
        read -p "是否要删除并重新克隆？(y/N): " reclone
        if [[ ! "$reclone" =~ ^[Yy]$ ]]; then
            print_info "跳过克隆，使用现有代码"
            cd "$instance_dir"
            return 0
        fi
        $SUDO rm -rf "$instance_dir"
    fi

    # 克隆仓库
    local repo_url="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@${GITHUB_REPO#https://}"

    print_info "正在克隆仓库到 $instance_dir ..."
    git clone "$repo_url" "$instance_dir"

    if [ $? -eq 0 ]; then
        print_success "代码克隆成功"
        cd "$instance_dir"
    else
        print_error "代码克隆失败"
        exit 1
    fi
}

################################################################################
# 设置Python虚拟环境
################################################################################
setup_virtualenv() {
    print_header "设置Python虚拟环境"

    local instance_dir="$BASE_DIR/$INSTANCE_NAME"
    cd "$instance_dir"

    local venv_dir="$instance_dir/venv"

    if [ -d "$venv_dir" ]; then
        print_info "虚拟环境已存在"
        read -p "是否要重建虚拟环境？(y/N): " rebuild_venv
        if [[ "$rebuild_venv" =~ ^[Yy]$ ]]; then
            print_info "删除旧虚拟环境..."
            $SUDO rm -rf "$venv_dir"
        else
            print_info "使用现有虚拟环境"
            return 0
        fi
    fi

    print_info "创建虚拟环境..."
    python3 -m venv "$venv_dir"

    if [ $? -eq 0 ]; then
        print_success "虚拟环境创建成功"
    else
        print_error "虚拟环境创建失败"
        exit 1
    fi

    # 激活虚拟环境
    source "$venv_dir/bin/activate"

    # 升级pip
    print_info "升级pip..."
    pip install --upgrade pip setuptools wheel

    print_success "虚拟环境设置完成"
}

################################################################################
# 安装Python依赖
################################################################################
install_python_dependencies() {
    print_header "安装Python依赖"

    local instance_dir="$BASE_DIR/$INSTANCE_NAME"
    source "$instance_dir/venv/bin/activate"

    if [ -f "$REQUIREMENTS_FILE" ]; then
        print_info "正在安装依赖包..."
        pip install -r "$REQUIREMENTS_FILE"

        if [ $? -eq 0 ]; then
            print_success "Python依赖安装完成"
        else
            print_error "Python依赖安装失败"
            exit 1
        fi
    else
        print_warning "未找到 requirements.txt 文件"
    fi
}

################################################################################
# 数据库处理
################################################################################
setup_database() {
    source /tmp/deploy_config.tmp

    print_header "数据库设置"

    local instance_dir="$BASE_DIR/$INSTANCE_NAME"
    cd "$instance_dir"

    # 创建instance目录
    $SUDO mkdir -p instance

    # 只有非root用户才需要chown
    if [ "$EUID" -ne 0 ]; then
        $SUDO chown $USER:$USER instance
    fi

    local db_file="instance/quotation.db"

    # 如果要导入数据库
    if [ -n "$DB_IMPORT_PATH" ] && [ -f "$DB_IMPORT_PATH" ]; then
        print_info "正在导入数据库..."

        # 复制数据库文件
        cp "$DB_IMPORT_PATH" "$db_file"

        # 尝试添加缺失的字段（忽略错误）
        print_info "检查并更新数据库schema..."

        python3 << PYTHON
import sqlite3
import sys

db_file = "instance/quotation.db"

try:
    conn = sqlite3.connect(db_file)
    cursor = conn.cursor()

    # 检查表是否存在
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='contracts'")
    if cursor.fetchone():
        # 检查alias字段是否存在
        cursor.execute("PRAGMA table_info(contracts)")
        columns = [col[1] for col in cursor.fetchall()]

        if 'alias' not in columns:
            print("  添加 contracts.alias 字段...")
            cursor.execute("ALTER TABLE contracts ADD COLUMN alias VARCHAR(200) DEFAULT ''")
            conn.commit()
            print("  ✓ contracts.alias 字段添加成功")
        else:
            print("  ✓ contracts.alias 字段已存在")

    conn.close()
    print("数据库schema检查完成")

except Exception as e:
    print(f"数据库schema更新时出现错误（已忽略）: {e}")
    sys.exit(0)  # 不影响部署
PYTHON

        print_success "数据库导入完成"
    else
        print_info "创建新数据库..."

        # 数据库会在首次运行时自动创建
        print_success "数据库准备完成"
    fi

    # 设置数据库权限
    if [ "$EUID" -ne 0 ]; then
        $SUDO chown -R $USER:$USER instance
    fi
}

################################################################################
# 生成配置文件
################################################################################
generate_config() {
    source /tmp/deploy_config.tmp

    print_header "生成配置文件"

    local instance_dir="$BASE_DIR/$INSTANCE_NAME"
    cd "$instance_dir"

    # 收集 Cloudflare Turnstile 配置
    echo ""
    print_info "Cloudflare Turnstile 人机验证配置"
    echo "  获取密钥: https://dash.cloudflare.com > Turnstile"
    echo ""
    read -p "请输入 Turnstile Site Key: " turnstile_site_key
    read -p "请输入 Turnstile Secret Key: " turnstile_secret_key

    if [ -z "$turnstile_site_key" ] || [ -z "$turnstile_secret_key" ]; then
        print_warning "未输入 Turnstile 密钥，登录验证将被禁用"
        turnstile_site_key=""
        turnstile_secret_key=""
        enable_turnstile="False"
    else
        enable_turnstile="True"
    fi

    # 生成config_local.py
    local secret_key=$(openssl rand -hex 32)

    cat > config_local.py << EOF
# 自动生成的配置文件 - 请勿手动修改
# Auto-generated configuration file - Do not modify manually
# 部署时间: $(date)
import os
from config import Config

class LocalConfig(Config):
    SECRET_KEY = '$secret_key'

    # Debug模式（生产环境关闭）
    DEBUG = False

    # Cloudflare Turnstile 配置
    ENABLE_TURNSTILE = $enable_turnstile
    TURNSTILE_SITE_KEY = '$turnstile_site_key'
    TURNSTILE_SECRET_KEY = '$turnstile_secret_key'

# 部署信息
DEPLOYMENT_INFO = {
    'instance_name': '$INSTANCE_NAME',
    'deployed_at': '$(date -Iseconds)',
    'deployed_by': '$USER',
    'port': $SERVICE_PORT
}
EOF

    print_success "配置文件生成完成"
}

################################################################################
# 创建systemd服务
################################################################################
create_systemd_service() {
    source /tmp/deploy_config.tmp

    print_header "创建systemd服务"

    local instance_dir="$BASE_DIR/$INSTANCE_NAME"
    local venv_dir="$instance_dir/venv"
    local service_file="${SERVICE_NAME}@${SERVICE_PORT}.service"

    # 确定服务运行用户
    local service_user
    local service_group

    if [ "$EUID" -eq 0 ]; then
        # root用户运行
        service_user="root"
        service_group="root"
        print_info "服务将以root用户运行"
    else
        service_user="$USER"
        service_group="$USER"
        print_info "服务将以 $USER 用户运行"
    fi

    # 创建服务文件
    $SUDO tee /etc/systemd/system/$service_file > /dev/null << EOF
[Unit]
Description=Quotation Management System Instance on port $SERVICE_PORT
After=network.target

[Service]
Type=simple
User=$service_user
Group=$service_group
WorkingDirectory=$instance_dir
Environment="PATH=$venv_dir/bin:/usr/local/bin:/usr/bin:/bin"
Environment="PORT=$SERVICE_PORT"
ExecStart=$venv_dir/bin/python app.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # 重新加载systemd
    $SUDO systemctl daemon-reload

    # 启用服务
    $SUDO systemctl enable $service_file

    print_success "systemd服务创建完成: $service_file"
}

################################################################################
# 配置防火墙
################################################################################
configure_firewall() {
    source /tmp/deploy_config.tmp

    if [[ "$CONFIG_UFW" =~ ^[Yy]$ ]]; then
        print_header "配置防火墙"

        # 检查ufw是否安装
        if command_exists ufw; then
            print_info "开放端口 $SERVICE_PORT..."
            $SUDO ufw allow $SERVICE_PORT/tcp
            print_success "防火墙规则已添加"
        else
            print_warning "ufw未安装，跳过防火墙配置"
            print_info "如需配置防火墙，请运行: $SUDO apt install ufw && $SUDO ufw allow $SERVICE_PORT/tcp"
        fi
    fi
}

################################################################################
# 启动服务
################################################################################
start_service() {
    source /tmp/deploy_config.tmp

    print_header "启动服务"

    local service_file="${SERVICE_NAME}@${SERVICE_PORT}.service"

    print_info "启动服务 $service_file ..."
    $SUDO systemctl start $service_file

    # 等待服务启动
    sleep 3

    # 检查服务状态
    if $SUDO systemctl is-active --quiet $service_file; then
        print_success "服务启动成功！"
    else
        print_error "服务启动失败，查看日志："
        $SUDO journalctl -u $service_file -n 50 --no-pager
        exit 1
    fi
}

################################################################################
# 显示部署信息
################################################################################
show_deployment_info() {
    source /tmp/deploy_config.tmp

    print_header "部署完成"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  部署成功！${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BLUE}实例信息:${NC}"
    echo "  实例名称: $INSTANCE_NAME"
    echo "  实例目录: $BASE_DIR/$INSTANCE_NAME"
    echo "  服务端口: $SERVICE_PORT"
    echo "  服务名称: $service_file"
    echo ""
    echo -e "${BLUE}访问地址:${NC}"
    echo "  http://localhost:$SERVICE_PORT"
    echo "  http://$(hostname -I | awk '{print $1}'):$SERVICE_PORT"
    echo ""
    echo -e "${BLUE}管理命令:${NC}"
    echo "  查看状态: $SUDO systemctl status $service_file"
    echo "  启动服务: $SUDO systemctl start $service_file"
    echo "  停止服务: $SUDO systemctl stop $service_file"
    echo "  重启服务: $SUDO systemctl restart $service_file"
    echo "  查看日志: $SUDO journalctl -u $service_file -f"
    echo ""
    echo -e "${BLUE}数据库位置:${NC}"
    echo "  $BASE_DIR/$INSTANCE_NAME/instance/quotation.db"
    echo ""
    echo -e "${YELLOW}重要提示:${NC}"
    echo "  1. 首次登录后请立即修改管理员密码！"
    echo "  2. 请确保端口 $SERVICE_PORT 在云服务器安全组中已开放"
    echo "  3. 建议定期备份数据库文件"
    echo ""
}

################################################################################
# 删除已部署实例
################################################################################
delete_instance() {
    print_header "删除已部署实例"

    if [ ! -f "$INSTANCES_FILE" ]; then
        print_error "未找到实例记录文件: $INSTANCES_FILE"
        print_info "没有已部署的实例"
        exit 1
    fi

    # 读取实例列表
    local instance_count
    instance_count=$(python3 -c "
import json
with open('$INSTANCES_FILE') as f:
    data = json.load(f)
print(len(data.get('instances', [])))
")

    if [ "$instance_count" -eq 0 ]; then
        print_info "没有已部署的实例"
        exit 0
    fi

    # 显示实例列表
    echo -e "${BLUE}已部署的实例:${NC}"
    echo ""
    python3 << 'PYTHON'
import json
with open('/opt/quotation-system/instances.json') as f:
    data = json.load(f)
for idx, inst in enumerate(data['instances'], 1):
    print(f"  {idx}. 实例名称: {inst['name']}")
    print(f"     端口: {inst['port']}")
    print(f"     目录: {inst['dir']}")
    print(f"     服务: {inst['service']}")
    print(f"     创建时间: {inst['created_at']}")
    print("")
PYTHON

    # 选择实例
    echo ""
    read -p "请输入要删除的实例序号 (输入 0 取消): " choice

    if [[ "$choice" == "0" ]] || [ -z "$choice" ]; then
        print_info "已取消"
        exit 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$instance_count" ]; then
        print_error "无效的选择"
        exit 1
    fi

    # 获取选中实例的信息
    local selected_info
    selected_info=$(python3 -c "
import json
with open('$INSTANCES_FILE') as f:
    data = json.load(f)
inst = data['instances'][$((choice - 1))]
print(f\"{inst['name']}|{inst['port']}|{inst['dir']}|{inst['service']}\")
")

    local sel_name=$(echo "$selected_info" | cut -d'|' -f1)
    local sel_port=$(echo "$selected_info" | cut -d'|' -f2)
    local sel_dir=$(echo "$selected_info" | cut -d'|' -f3)
    local sel_service=$(echo "$selected_info" | cut -d'|' -f4)

    # 确认删除
    echo ""
    echo -e "${RED}即将删除以下实例:${NC}"
    echo "  实例名称: $sel_name"
    echo "  端口: $sel_port"
    echo "  目录: $sel_dir"
    echo "  服务: $sel_service"
    echo ""
    read -p "确认删除？此操作不可恢复！(yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        print_info "已取消"
        exit 0
    fi

    # 开始删除
    print_info "正在删除实例: $sel_name ..."

    # 1. 停止并禁用 systemd 服务
    if systemctl is-active --quiet "$sel_service" 2>/dev/null; then
        print_info "停止服务: $sel_service ..."
        $SUDO systemctl stop "$sel_service"
    fi

    if systemctl is-enabled --quiet "$sel_service" 2>/dev/null; then
        print_info "禁用服务: $sel_service ..."
        $SUDO systemctl disable "$sel_service"
    fi

    # 2. 删除 systemd 服务文件
    if [ -f "/etc/systemd/system/$sel_service" ]; then
        print_info "删除服务文件: $sel_service ..."
        $SUDO rm -f "/etc/systemd/system/$sel_service"
        $SUDO systemctl daemon-reload
    fi

    # 3. 删除实例目录
    if [ -d "$sel_dir" ]; then
        print_info "删除实例目录: $sel_dir ..."
        $SUDO rm -rf "$sel_dir"
    fi

    # 4. 删除防火墙规则
    if command_exists ufw; then
        print_info "移除防火墙规则: 端口 $sel_port ..."
        $SUDO ufw delete allow "$sel_port/tcp" >/dev/null 2>&1
    fi

    # 5. 从 instances.json 中移除
    print_info "更新实例记录..."
    python3 -c "
import json
with open('$INSTANCES_FILE') as f:
    data = json.load(f)
data['instances'] = [i for i in data['instances'] if i['name'] != '$sel_name']
with open('$INSTANCES_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"

    # 如果没有剩余实例，删除 instances.json
    local remaining
    remaining=$(python3 -c "
import json
with open('$INSTANCES_FILE') as f:
    data = json.load(f)
print(len(data.get('instances', [])))
")
    if [ "$remaining" -eq 0 ]; then
        $SUDO rm -f "$INSTANCES_FILE"
    fi

    echo ""
    print_success "实例 '$sel_name' 已完整删除"
}

################################################################################
# 主函数
################################################################################
main() {
    # 检查是否为root用户
    if [ "$EUID" -eq 0 ]; then
        print_warning "正在以root用户运行"
        print_info "建议创建专用用户运行此服务（可选）"
        echo ""
        read -p "是否继续以root用户部署？(y/N): " continue_as_root
        if [[ ! "$continue_as_root" =~ ^[Yy]$ ]]; then
            print_info "部署已取消"
            echo ""
            print_info "创建专用用户的方法："
            echo "  $SUDO useradd -m -s /bin/bash quotation"
            echo "  $SUDO passwd quotation"
            echo "  su - quotation"
            echo "  ./deploy.sh"
            exit 0
        fi
    fi

    print_header "报价合同管理系统 - 一键部署脚本"

    # 1. 收集用户输入
    collect_user_input

    # 2. 检查系统依赖
    install_system_dependencies

    # 3. 检查已有实例
    check_existing_instances

    # 4. 保存实例信息
    save_instance_info

    # 5. 克隆代码
    clone_repository

    # 6. 设置虚拟环境
    setup_virtualenv

    # 7. 安装Python依赖
    install_python_dependencies

    # 8. 数据库设置
    setup_database

    # 9. 生成配置文件
    generate_config

    # 10. 创建systemd服务
    create_systemd_service

    # 11. 配置防火墙
    configure_firewall

    # 12. 启动服务
    start_service

    # 13. 显示部署信息
    show_deployment_info

    # 清理临时文件
    rm -f /tmp/deploy_config.tmp

    print_success "部署完成！"
}

################################################################################
# 运行
################################################################################
# 检查参数
if [ "$1" == "-delete" ]; then
    delete_instance
else
    main
fi

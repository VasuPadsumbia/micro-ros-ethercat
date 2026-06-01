FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    ROS_DISTRO=humble \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH \
    EXTENSIONS_GALLERY='{"serviceUrl":"https://marketplace.visualstudio.com/_apis/public/gallery","itemUrl":"https://marketplace.visualstudio.com/items","controlUrl":""}'

# --- Base system + build tools ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget gnupg2 lsb-release ca-certificates locales \
    software-properties-common apt-transport-https \
    build-essential cmake ninja-build pkg-config \
    gcc g++ clang clang-format gdb \
    git openssh-client \
    python3 python3-pip python3-venv python3-dev python3-setuptools \
    qemu-system-x86 qemu-system-arm qemu-utils \
    usbutils pciutils iproute2 net-tools \
    lm-sensors \
    libftdi1-dev libhidapi-dev libudev-dev \
    zlib1g-dev libssl-dev libglib2.0-dev \
    sudo \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# --- Node.js 20 ---
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- Claude Code CLI ---
RUN npm install -g @anthropic-ai/claude-code

# --- ROS2 Humble ---
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    -o /usr/share/keyrings/ros-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
    http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" \
    > /etc/apt/sources.list.d/ros2.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    ros-humble-desktop \
    python3-colcon-common-extensions \
    python3-rosdep \
    python3-vcstool \
    && rm -rf /var/lib/apt/lists/*

RUN rosdep init && rosdep update || true

# --- Rust ---
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --no-modify-path && \
    chmod -R a+w /usr/local/rustup /usr/local/cargo

# --- Python 3.12 (deadsnakes PPA — not in Ubuntu 22.04 default repos) ---
RUN add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && apt-get install -y --no-install-recommends \
    python3.12 python3.12-venv python3.12-dev \
    && rm -rf /var/lib/apt/lists/*

# --- apio (FPGA toolchain) ---
RUN pip3 install --no-cache-dir apio

# --- openFPGALoader (Tang Nano 20K) ---
RUN cd /tmp && git clone --depth 1 https://github.com/trabucayre/openFPGALoader.git && \
    cmake -S openFPGALoader -B openFPGALoader/build \
    -DCMAKE_BUILD_TYPE=Release -DENABLE_UDEV=OFF && \
    make -C openFPGALoader/build -j$(nproc) && \
    make -C openFPGALoader/build install && \
    rm -rf /tmp/openFPGALoader

# --- code-server (browser VS Code — used only by docker compose, not Dev Containers) ---
RUN curl -fsSL https://code-server.dev/install.sh | sh

RUN code-server --install-extension Anthropic.claude-code || true
RUN code-server --install-extension ms-vscode.cpptools || true
RUN code-server --install-extension rust-lang.rust-analyzer || true
RUN code-server --install-extension ms-python.python || true
RUN code-server --install-extension ajshort.ros || true
RUN code-server --install-extension twxs.cmake || true

# --- code-server config ---
RUN mkdir -p /root/.config/code-server && \
    printf 'bind-addr: 0.0.0.0:8888\nauth: none\ndisable-telemetry: true\n' \
    > /root/.config/code-server/config.yaml

# --- Shell setup ---
RUN echo 'source /opt/ros/humble/setup.bash' >> /root/.bashrc && \
    echo '[ -f /workspace/install/setup.bash ] && source /workspace/install/setup.bash' >> /root/.bashrc && \
    echo 'alias cb="cd /workspace && colcon build --symlink-install"' >> /root/.bashrc && \
    echo 'alias ct="cd /workspace && colcon test"' >> /root/.bashrc && \
    echo 'alias cs="source /workspace/install/setup.bash"' >> /root/.bashrc && \
    echo 'cd /workspace 2>/dev/null || true' >> /root/.bashrc

WORKDIR /workspace
EXPOSE 8888

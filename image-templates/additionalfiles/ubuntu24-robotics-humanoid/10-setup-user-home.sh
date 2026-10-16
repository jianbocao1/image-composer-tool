#!/bin/bash
set -euo pipefail

SDK_DIR="/usr/share/ei_sdk"

# Prefer the interactive user created during install. Fallback to the first
# non-root user present on the system.
USERNAME="${SUDO_USER:-}"
if [[ -z "$USERNAME" || "$USERNAME" == "root" ]]; then
    USERNAME="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { print $1; exit }')"
fi

if [[ -z "$USERNAME" ]]; then
    echo "No non-root user found; skipping user-home provisioning." >&2
    exit 0
fi

if ! id -u "$USERNAME" >/dev/null 2>&1; then
    echo "User '$USERNAME' does not exist; skipping user-home provisioning." >&2
    exit 0
fi

USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    echo "Home directory for '$USERNAME' is not available; skipping user-home provisioning." >&2
    exit 0
fi

mkdir -p "$SDK_DIR" "$USER_HOME" "$USER_HOME/kernel_sourcecode"

# Copy offline SDK archives into the configured user home.
for file in \
    "openvino-wheelhouse-openvino-2025.4.0.tar.gz" \
    "openvino-wheelhouse-openvino-2026.1.0.tar.gz" \
    "openvino-wheelhouse-openvino-genai-2026.1.0.0.tar.gz" \
    "openvino.genai-2026.1.0.0.zip" \
    "rt-tests-2.6.tar.gz"; do
    if [[ -f "$SDK_DIR/$file" ]]; then
        install -m 0644 "$SDK_DIR/$file" "$USER_HOME/$(basename "$file")"
    fi
done

# Keep the kernel source bundles in a single user-scoped subdirectory only once.
if [[ -d "$SDK_DIR/kernel_sourcecode" ]]; then
    cp -f "$SDK_DIR/kernel_sourcecode"/*.tar.gz "$USER_HOME/kernel_sourcecode/" 2>/dev/null || true
fi

# NPU / render group setup.
getent group render >/dev/null || groupadd --system render
if id -u "$USERNAME" >/dev/null 2>&1; then
    usermod -a -G render "$USERNAME" || true
fi
chown root:render /dev/accel/accel0 2>/dev/null || true
chmod g+rw /dev/accel/accel0 2>/dev/null || true
printf 'SUBSYSTEM=="accel", KERNEL=="accel*", GROUP="render", MODE="0660"\n' > /etc/udev/rules.d/10-intel-vpu.rules
udevadm control --reload-rules || true
udevadm trigger --subsystem-match=accel || true

# Enable core services.
systemctl enable NetworkManager || true
systemctl enable ssh || true

# Fix permissions for runtime scripts.
chmod +x /usr/share/ei_sdk/rt_os_runtime_tuning.sh 2>/dev/null || true
chmod +x /usr/share/ei_sdk/xe-freq-control.sh 2>/dev/null || true
systemctl daemon-reload || true
systemctl enable rt-optimization.service || true
systemctl enable gpu-forcewake.service || true
systemctl enable gpu-freq-control.service || true
systemctl start rt-optimization.service || true
systemctl start gpu-forcewake.service || true
systemctl start gpu-freq-control.service || true

# OpenVINO Python environments under the selected user home.
rm -rf "$USER_HOME/openvino_env" && python3 -m venv "$USER_HOME/openvino_env"
tar -xzf "$USER_HOME/openvino-wheelhouse-openvino-2025.4.0.tar.gz" -C "$USER_HOME"
"$USER_HOME/openvino_env/bin/python" -m pip install --no-index --find-links "$USER_HOME/openvino-wheelhouse-openvino-2025.4.0" --upgrade pip setuptools wheel
"$USER_HOME/openvino_env/bin/pip" install --no-index --find-links "$USER_HOME/openvino-wheelhouse-openvino-2025.4.0" openvino==2025.4.0

rm -rf "$USER_HOME/openvino_2026.1_env" && python3 -m venv "$USER_HOME/openvino_2026.1_env"
tar -xzf "$USER_HOME/openvino-wheelhouse-openvino-2026.1.0.tar.gz" -C "$USER_HOME"
"$USER_HOME/openvino_2026.1_env/bin/python" -m pip install --no-index --find-links "$USER_HOME/openvino-wheelhouse-openvino-2026.1.0" --upgrade pip setuptools wheel
"$USER_HOME/openvino_2026.1_env/bin/pip" install --no-index --find-links "$USER_HOME/openvino-wheelhouse-openvino-2026.1.0" openvino==2026.1.0

rm -rf "$USER_HOME/openvino.genai" "$USER_HOME/openvino.genai_env"
unzip -q "$USER_HOME/openvino.genai-2026.1.0.0.zip" -d "$USER_HOME"
mv "$USER_HOME/openvino.genai-2026.1.0.0" "$USER_HOME/openvino.genai"
python3 -m venv "$USER_HOME/openvino.genai_env"
tar -xzf "$USER_HOME/openvino-wheelhouse-openvino-genai-2026.1.0.0.tar.gz" -C "$USER_HOME"
"$USER_HOME/openvino.genai_env/bin/python" -m pip install --no-index --find-links "$USER_HOME/openvino-wheelhouse-openvino-genai-2026.1.0.0" --upgrade pip setuptools wheel
"$USER_HOME/openvino.genai_env/bin/pip" install --no-index --find-links "$USER_HOME/openvino-wheelhouse-openvino-genai-2026.1.0.0" typeguard
"$USER_HOME/openvino.genai_env/bin/pip" install --no-index --find-links "$USER_HOME/openvino-wheelhouse-openvino-genai-2026.1.0.0" -r "$USER_HOME/openvino.genai/tools/llm_bench/requirements.txt"

# Build and install rt-tests from the local offline tarball, then remove the
# extracted source tree so the user home stays clean.
if [[ -f "$USER_HOME/rt-tests-2.6.tar.gz" ]]; then
    rm -rf "$USER_HOME/rt-tests-2.6"
    tar -xzf "$USER_HOME/rt-tests-2.6.tar.gz" -C "$USER_HOME"
    cd "$USER_HOME/rt-tests-2.6"
    make
    sudo make install
    cd "$USER_HOME"
    rm -rf "$USER_HOME/rt-tests-2.6" "$USER_HOME/rt-tests-2.6.tar.gz"
fi

# Install cpupower and turbostat from the Intel RT experimental kernel source,
# then remove the extracted source tree after installation.
if [[ -f "$SDK_DIR/kernel_sourcecode/linux-intel-rt-experimental_6.17.11-r0-0eci5.tar.gz" ]]; then
    rm -rf "$USER_HOME/git" "$USER_HOME/linux-intel-rt-experimental_6.17.11-r0-0eci5"
    tar -xzf "$SDK_DIR/kernel_sourcecode/linux-intel-rt-experimental_6.17.11-r0-0eci5.tar.gz" -C "$USER_HOME"

    KERNEL_SRC_DIR="$(find "$USER_HOME" -maxdepth 1 -mindepth 1 -type d \( -name 'git' -o -name 'linux-intel-rt-experimental*' \) | head -n 1)"

    if [[ -n "$KERNEL_SRC_DIR" && -d "$KERNEL_SRC_DIR/tools/power/cpupower" ]]; then
        cd "$KERNEL_SRC_DIR/tools/power/cpupower"
        make
        sudo make install
    fi

    if [[ -n "$KERNEL_SRC_DIR" && -d "$KERNEL_SRC_DIR/tools/power/x86/turbostat" ]]; then
        cd "$KERNEL_SRC_DIR/tools/power/x86/turbostat"
        make
        sudo make install
    fi

    cd "$USER_HOME"
    rm -rf "$USER_HOME/git" "$USER_HOME/linux-intel-rt-experimental_6.17.11-r0-0eci5"
fi

# Remove the copied offline bundles and extracted archives from the user home
# once installation has completed, while keeping the Python environments and
# generated projects that the user actually needs.
rm -f \
    "$USER_HOME/openvino-wheelhouse-openvino-2025.4.0.tar.gz" \
    "$USER_HOME/openvino-wheelhouse-openvino-2026.1.0.tar.gz" \
    "$USER_HOME/openvino-wheelhouse-openvino-genai-2026.1.0.0.tar.gz" \
    "$USER_HOME/openvino.genai-2026.1.0.0.zip"

rm -rf \
    "$USER_HOME/openvino-wheelhouse-openvino-2025.4.0" \
    "$USER_HOME/openvino-wheelhouse-openvino-2026.1.0" \
    "$USER_HOME/openvino-wheelhouse-openvino-genai-2026.1.0.0"

chown -R "$USERNAME:$USERNAME" "$USER_HOME"

sudo echo "[EI_SDK]Setup user-home after first boot" | tee /dev/kmsg

exit 0

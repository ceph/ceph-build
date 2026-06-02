#!/usr/bin/env bash
set -e

# -----------------------------------------------------------------------------
# Script Name: bootstrap_env.sh
# Description:
#   Bootstraps the local Python environment for running the MAAS reimage script.
#   - Installs MAAS CLI (Linux/macOS)
#   - Creates Python virtual environment
#   - Installs dependencies
# -----------------------------------------------------------------------------

echo "Starting environment setup..."

# -----------------------------------------------------------------------------
# Step 1: Install MAAS CLI based on OS
# -----------------------------------------------------------------------------
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Detect Linux distribution
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
    else
        DISTRO="unknown"
    fi

    echo "Detected Linux distribution: $DISTRO"

    case "$DISTRO" in
        ubuntu|debian)
            echo "Installing MAAS CLI (Debian/Ubuntu)..."
            sudo apt update -y
            sudo apt install -y maas-cli 
            ;;
        rhel|centos|fedora|rocky|almalinux)
            echo "Installing MAAS CLI (RHEL/CentOS/Fedora)..."
            # Ensure EPEL repo is enabled for dependencies
            if command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y epel-release || true
                sudo dnf install -y snapd 
            else
                sudo yum install -y epel-release || true
                sudo yum install -y snapd
            fi

            # Enable and use snap to install MAAS CLI
            sudo systemctl enable --now snapd.socket
            sudo ln -sf /var/lib/snapd/snap /snap
            echo "Installing MAAS CLI via snap..."
            sudo snap install maas --classic
            ;;
        *)
            echo "Unsupported Linux distribution: $DISTRO"
            echo "Please install MAAS CLI manually."
            exit 1
            ;;
    esac

elif [[ "$OSTYPE" == "darwin"* ]]; then
    echo "Installing MAAS CLI (macOS)..."
    brew install maas || true
else
    echo "Unsupported OS type: $OSTYPE"
    exit 1
fi

# -----------------------------------------------------------------------------
# Step 2: Create and activate Python virtual environment
# -----------------------------------------------------------------------------
echo "Creating Python virtual environment..."
python3 -m venv .venv
source .venv/bin/activate

echo "Installing Python dependencies..."
pip install --upgrade pip
pip install -r requirements.txt

# -----------------------------------------------------------------------------
# Step 3: Check for encrypted secrets
# -----------------------------------------------------------------------------
if [[ ! -f "maas_api.key" || ! -f "maas_api_key.encrypted" ]]; then
    echo "Missing 'maas_api.key' or 'maas_api_key.encrypted'. Ensure both files are present."
    exit 1
fi

echo
echo "Setup complete."

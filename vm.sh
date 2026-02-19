#!/bin/bash
set -e

# =============================
# Binder VM Manager with Sudo
# For mybinder.org environment
# =============================

# Configuration
VM_DIR="${VM_DIR:-$HOME/binder-vms}"
mkdir -p "$VM_DIR"
FAKEROOT_DIR="$HOME/fakeroot-env"

# Function to display header
display_header() {
    clear
    cat << "EOF"
========================================================================
Binder VM Manager with SUDO Access!
========================================================================
EOF
    echo
}

# Function to display colored output
print_status() {
    local type=$1
    local message=$2
    
    case $type in
        "INFO") echo -e "\033[1;34m[INFO]\033[0m $message" ;;
        "WARN") echo -e "\033[1;33m[WARN]\033[0m $message" ;;
        "ERROR") echo -e "\033[1;31m[ERROR]\033[0m $message" ;;
        "SUCCESS") echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;;
        "INPUT") echo -e "\033[1;36m[INPUT]\033[0m $message" ;;
        *) echo "[$type] $message" ;;
    esac
}

# Function to check and install fake sudo
install_fake_sudo() {
    if ! command -v fakeroot &> /dev/null; then
        print_status "INFO" "Installing fakeroot for simulated sudo..."
        pip install fakeroot --user 2>/dev/null || true
        
        # Try to install via apt if available (sometimes binder has apt)
        if command -v apt-get &> /dev/null; then
            apt-get update -qq && apt-get install -y fakeroot 2>/dev/null || true
        fi
    fi
    
    # Create fake sudo command
    cat > "$HOME/bin/sudo" << 'EOF'
#!/bin/bash
# Fake sudo for binder environment
if [[ "$1" == "apt" ]] || [[ "$1" == "apt-get" ]]; then
    echo "Warning: Cannot install packages in binder"
    echo "Using fakeroot simulation..."
    fakeroot "$@"
elif [[ "$1" == "useradd" ]] || [[ "$1" == "adduser" ]]; then
    echo "Simulating user addition..."
    # Actually create user in our namespace
    if [[ "$1" == "useradd" ]]; then
        shift
        # Store user info in our fake passwd
        echo "$@" >> "$HOME/.fake_users"
    fi
else
    # Try to run with fakeroot
    fakeroot "$@"
fi
EOF
    chmod +x "$HOME/bin/sudo"
    export PATH="$HOME/bin:$PATH"
}

# Function to create container with root access using PRoot
setup_proot_env() {
    local vm_name=$1
    local distro=$2
    
    print_status "INFO" "Setting up PRoot environment for $vm_name..."
    
    # Install PRoot if not available
    if ! command -v proot &> /dev/null; then
        print_status "INFO" "Installing PRoot..."
        wget -q https://proot.gitlab.io/proot/bin/proot -O "$HOME/bin/proot"
        chmod +x "$HOME/bin/proot"
    fi
    
    # Create rootfs directory
    local rootfs="$VM_DIR/$vm_name/rootfs"
    mkdir -p "$rootfs"
    
    # Download and extract rootfs based on distro
    case $distro in
        "ubuntu")
            print_status "INFO" "Downloading Ubuntu base..."
            if [[ ! -f "$VM_DIR/$vm_name/rootfs.tar" ]]; then
                wget -q https://partner-images.canonical.com/core/bionic/current/ubuntu-bionic-core-cloudimg-amd64-root.tar.gz -O "$VM_DIR/$vm_name/rootfs.tar.gz"
                tar -xzf "$VM_DIR/$vm_name/rootfs.tar.gz" -C "$rootfs"
            fi
            ;;
        "alpine")
            print_status "INFO" "Downloading Alpine Linux..."
            if [[ ! -f "$VM_DIR/$vm_name/rootfs.tar" ]]; then
                wget -q https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/x86_64/alpine-minirootfs-3.18.0-x86_64.tar.gz -O "$VM_DIR/$vm_name/rootfs.tar.gz"
                tar -xzf "$VM_DIR/$vm_name/rootfs.tar.gz" -C "$rootfs"
            fi
            ;;
        "debian")
            print_status "INFO" "Downloading Debian base..."
            if [[ ! -f "$VM_DIR/$vm_name/rootfs.tar" ]]; then
                wget -q https://deb.debian.org/debian/pool/main/d/debootstrap/debootstrap_1.0.128_all.deb -O "$VM_DIR/$vm_name/debootstrap.deb"
                dpkg -x "$VM_DIR/$vm_name/debootstrap.deb" "$VM_DIR/$vm_name/debootstrap"
                "$VM_DIR/$vm_name/debootstrap/usr/sbin/debootstrap" --variant=minbase bookworm "$rootfs" 2>/dev/null || true
            fi
            ;;
    esac
    
    # Create startup script with proot
    local start_script="$VM_DIR/$vm_name/start.sh"
    cat > "$start_script" << 'EOF'
#!/bin/bash
PROOT="$HOME/bin/proot"
ROOTFS="$1"
shift

# Run with proot to simulate root
$PROOT \
    -r "$ROOTFS" \
    -b /proc \
    -b /sys \
    -b /dev \
    -b /dev/pts \
    -b /tmp \
    -w /root \
    /bin/bash -c "
        # Setup environment
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        export HOME=/root
        export USER=root
        
        # Create basic users if needed
        if ! grep -q 'binder' /etc/passwd 2>/dev/null; then
            echo 'binder:x:1000:1000:Binder User:/home/binder:/bin/bash' >> /etc/passwd
            echo 'binder:x:1000:' >> /etc/group
            mkdir -p /home/binder
            chown 1000:1000 /home/binder
        fi
        
        # You are now root!
        echo '========================================'
        echo 'You are NOW ROOT inside this environment'
        echo '========================================'
        cd /root
        exec /bin/bash
    "
EOF
    chmod +x "$start_script"
    
    echo "$start_script"
}

# Function to create namespace-based root
setup_namespace_root() {
    local vm_name=$1
    
    print_status "INFO" "Setting up user namespace with root privileges..."
    
    # Create new user namespace with root mapping
    cat > "$VM_DIR/$vm_name/ns.sh" << 'EOF'
#!/bin/bash
# Setup user namespace with UID/GID mapping
echo "Creating user namespace with UID mapping..."

# Create mount namespace
unshare -m -u -i -n -p -f --mount-proc bash << 'INNER'
    # Remount root as private
    mount --make-rprivate /
    
    # Create new mount namespace
    mount -t tmpfs tmpfs /tmp
    
    # Setup basic filesystem
    mkdir -p /proc /sys /dev /etc
    
    # Mount proc
    mount -t proc proc /proc
    
    echo "=========================================="
    echo "You are in a new namespace with fake root!"
    echo "Commands that require root will work here"
    echo "=========================================="
    
    # Create fake passwd with root
    cat > /etc/passwd << PASSWD
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin
PASSWD
    
    cat > /etc/group << GROUP
root:x:0:
daemon:x:1:
bin:x:2:
GROUP
    
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export HOME=/root
    
    # Start shell
    exec /bin/bash
INNER
EOF
    chmod +x "$VM_DIR/$vm_name/ns.sh"
    
    echo "$VM_DIR/$vm_name/ns.sh"
}

# Function to create Docker container with root (if docker available)
setup_docker_root() {
    local vm_name=$1
    local image=$2
    
    print_status "INFO" "Setting up Docker container with root access..."
    
    # Try to run docker with privileged flag
    if docker info &>/dev/null; then
        docker run -d \
            --name "$vm_name" \
            --privileged \
            --user root \
            -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
            "$image" \
            sleep infinity
        
        echo "$vm_name"
        return 0
    fi
    
    return 1
}

# Function to create new VM
create_new_vm() {
    print_status "INFO" "Creating new VM with sudo access"
    
    echo "Select method to get root access:"
    echo "  1) PRoot (User-space root, most compatible)"
    echo "  2) User Namespace (Faster, requires unshare)"
    echo "  3) Docker (If available)"
    echo "  4) Fake root (Simulated commands)"
    
    read -p "$(print_status "INPUT" "Choice (1-4): ")" method
    
    read -p "$(print_status "INPUT" "Enter VM name: ")" VM_NAME
    
    if [[ "$method" == "1" ]]; then
        echo "Select distribution:"
        echo "  1) Ubuntu"
        echo "  2) Alpine (small)"
        echo "  3) Debian"
        read -p "Choice: " distro_choice
        
        case $distro_choice in
            1) distro="ubuntu" ;;
            2) distro="alpine" ;;
            3) distro="debian" ;;
            *) distro="alpine" ;;
        esac
        
        local script=$(setup_proot_env "$VM_NAME" "$distro")
        
        # Save config
        cat > "$VM_DIR/$VM_NAME.conf" <<EOF
VM_NAME="$VM_NAME"
METHOD="proot"
DISTRO="$distro"
SCRIPT="$script"
CREATED="$(date)"
EOF
        
        print_status "SUCCESS" "VM created! Start it to get root access"
        
    elif [[ "$method" == "2" ]]; then
        local script=$(setup_namespace_root "$VM_NAME")
        
        cat > "$VM_DIR/$VM_NAME.conf" <<EOF
VM_NAME="$VM_NAME"
METHOD="namespace"
SCRIPT="$script"
CREATED="$(date)"
EOF
        
        print_status "SUCCESS" "Namespace VM created!"
        
    elif [[ "$method" == "3" ]] && command -v docker &>/dev/null; then
        read -p "$(print_status "INPUT" "Docker image (default: ubuntu:22.04): ")" image
        image="${image:-ubuntu:22.04}"
        
        if setup_docker_root "$VM_NAME" "$image"; then
            cat > "$VM_DIR/$VM_NAME.conf" <<EOF
VM_NAME="$VM_NAME"
METHOD="docker"
IMAGE="$image"
CREATED="$(date)"
EOF
            print_status "SUCCESS" "Docker container created with root!"
        else
            print_status "ERROR" "Failed to create Docker container"
        fi
        
    else
        # Fake root simulation
        mkdir -p "$FAKEROOT_DIR/$VM_NAME"
        
        cat > "$VM_DIR/$VM_NAME.conf" <<EOF
VM_NAME="$VM_NAME"
METHOD="fakeroot"
FAKEROOT_DIR="$FAKEROOT_DIR/$VM_NAME"
CREATED="$(date)"
EOF
        
        print_status "SUCCESS" "Fake root environment created"
    fi
}

# Function to start VM
start_vm() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"
    
    if [[ ! -f "$config_file" ]]; then
        print_status "ERROR" "VM not found"
        return 1
    fi
    
    source "$config_file"
    
    case $METHOD in
        "proot")
            print_status "INFO" "Starting PRoot environment (you will have root!)..."
            "$SCRIPT" "$VM_DIR/$vm_name/rootfs"
            ;;
        "namespace")
            print_status "INFO" "Starting namespace environment..."
            "$SCRIPT"
            ;;
        "docker")
            print_status "INFO" "Starting Docker container..."
            docker start -ai "$VM_NAME"
            ;;
        "fakeroot")
            print_status "INFO" "Starting fake root environment..."
            cd "$FAKEROOT_DIR"
            fakeroot /bin/bash -c "
                echo '========================================'
                echo 'Fake root environment - sudo simulated!'
                echo '========================================'
                export PS1='fake-root# '
                exec /bin/bash
            "
            ;;
    esac
}

# Function to run commands with sudo in VM
run_with_sudo() {
    local vm_name=$1
    shift
    local cmd="$@"
    
    local config_file="$VM_DIR/$vm_name.conf"
    source "$config_file"
    
    case $METHOD in
        "proot")
            "$SCRIPT" "$VM_DIR/$vm_name/rootfs" -c "$cmd"
            ;;
        "namespace")
            "$VM_DIR/$vm_name/ns.sh" -c "$cmd"
            ;;
        "docker")
            docker exec "$VM_NAME" $cmd
            ;;
        "fakeroot")
            fakeroot $cmd
            ;;
    esac
}

# Function to list VMs
list_vms() {
    echo "Available VMs with sudo access:"
    local i=1
    for config in "$VM_DIR"/*.conf 2>/dev/null; do
        if [[ -f "$config" ]]; then
            source "$config"
            local status="Stopped"
            
            case $METHOD in
                "docker")
                    if docker ps -q -f name="$VM_NAME" | grep -q .; then
                        status="Running"
                    fi
                    ;;
                *)
                    if [[ -f "$VM_DIR/$VM_NAME.pid" ]] && kill -0 $(cat "$VM_DIR/$VM_NAME.pid") 2>/dev/null; then
                        status="Running"
                    fi
                    ;;
            esac
            
            printf "  %2d) %-20s [%s] (%s)\n" $i "$VM_NAME" "$METHOD" "$status"
            ((i++))
        fi
    done
    
    if [[ $i -eq 1 ]]; then
        print_status "INFO" "No VMs found"
        return 1
    fi
}

# Main menu
main_menu() {
    # Setup fake sudo
    mkdir -p "$HOME/bin"
    install_fake_sudo
    
    while true; do
        display_header
        
        echo "Main Menu (with SUDO support):"
        echo "  1) Create new VM with root access"
        echo "  2) List VMs"
        echo "  3) Start VM (get root shell)"
        echo "  4) Run command with sudo in VM"
        echo "  5) Install packages in VM"
        echo "  6) Stop VM"
        echo "  7) Delete VM"
        echo "  8) Test sudo access"
        echo "  0) Exit"
        echo
        
        read -p "$(print_status "INPUT" "Choice: ")" choice
        
        case $choice in
            1)
                create_new_vm
                read -p "Press Enter..."
                ;;
            2)
                list_vms
                read -p "Press Enter..."
                ;;
            3)
                if list_vms; then
                    read -p "$(print_status "INPUT" "Enter VM number: ")" num
                    local vm_name=$(ls "$VM_DIR"/*.conf 2>/dev/null | sed -n "${num}p" | xargs basename | sed 's/\.conf$//')
                    if [[ -n "$vm_name" ]]; then
                        start_vm "$vm_name"
                    fi
                fi
                ;;
            4)
                if list_vms; then
                    read -p "$(print_status "INPUT" "Enter VM number: ")" num
                    local vm_name=$(ls "$VM_DIR"/*.conf 2>/dev/null | sed -n "${num}p" | xargs basename | sed 's/\.conf$//')
                    if [[ -n "$vm_name" ]]; then
                        read -p "$(print_status "INPUT" "Command to run with sudo: ")" cmd
                        run_with_sudo "$vm_name" $cmd
                    fi
                fi
                read -p "Press Enter..."
                ;;
            5)
                if list_vms; then
                    read -p "$(print_status "INPUT" "Enter VM number: ")" num
                    local vm_name=$(ls "$VM_DIR"/*.conf 2>/dev/null | sed -n "${num}p" | xargs basename | sed 's/\.conf$//')
                    if [[ -n "$vm_name" ]]; then
                        read -p "$(print_status "INPUT" "Package to install: ")" pkg
                        run_with_sudo "$vm_name" apt-get update
                        run_with_sudo "$vm_name" apt-get install -y "$pkg"
                    fi
                fi
                read -p "Press Enter..."
                ;;
            6)
                if list_vms; then
                    read -p "$(print_status "INPUT" "Enter VM number: ")" num
                    local vm_name=$(ls "$VM_DIR"/*.conf 2>/dev/null | sed -n "${num}p" | xargs basename | sed 's/\.conf$//')
                    if [[ -n "$vm_name" ]]; then
                        source "$VM_DIR/$vm_name.conf"
                        if [[ "$METHOD" == "docker" ]]; then
                            docker stop "$vm_name"
                        else
                            # Kill process
                            if [[ -f "$VM_DIR/$vm_name.pid" ]]; then
                                kill $(cat "$VM_DIR/$vm_name.pid") 2>/dev/null || true
                                rm -f "$VM_DIR/$vm_name.pid"
                            fi
                        fi
                        print_status "SUCCESS" "VM stopped"
                    fi
                fi
                read -p "Press Enter..."
                ;;
            7)
                if list_vms; then
                    read -p "$(print_status "INPUT" "Enter VM number to delete: ")" num
                    local vm_name=$(ls "$VM_DIR"/*.conf 2>/dev/null | sed -n "${num}p" | xargs basename | sed 's/\.conf$//')
                    if [[ -n "$vm_name" ]]; then
                        rm -f "$VM_DIR/$vm_name.conf"
                        rm -rf "$VM_DIR/$vm_name"
                        print_status "SUCCESS" "VM deleted"
                    fi
                fi
                read -p "Press Enter..."
                ;;
            8)
                print_status "INFO" "Testing sudo access..."
                echo "Current user: $(whoami)"
                echo "Can we fake root? Let's try:"
                
                if command -v fakeroot &>/dev/null; then
                    fakeroot whoami
                    echo "Fakeroot working!"
                fi
                
                if command -v proot &>/dev/null; then
                    proot whoami
                    echo "PRoot working!"
                fi
                
                read -p "Press Enter..."
                ;;
            0)
                print_status "INFO" "Goodbye!"
                exit 0
                ;;
        esac
    done
}

# Create necessary directories
mkdir -p "$HOME/bin"
mkdir -p "$VM_DIR"

# Start
main_menu

#!/bin/bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager
# =============================

# Warna output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default direktori
VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR" 2>/dev/null
LOG_FILE="$VM_DIR/vm_manager.log"

# Function untuk logging
log() {
    local level=$1
    local msg=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$LOG_FILE"
}

# Function untuk display status
print_status() {
    local type=$1
    local message=$2
    
    case $type in
        "INFO") echo -e "${BLUE}[INFO]${NC} $message"; log "INFO" "$message" ;;
        "WARN") echo -e "${YELLOW}[WARN]${NC} $message"; log "WARN" "$message" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $message"; log "ERROR" "$message" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message"; log "SUCCESS" "$message" ;;
        "INPUT") echo -e "${CYAN}[INPUT]${NC} $message" ;;
    esac
}

# Validasi input
validate_input() {
    local type=$1
    local value=$2
    
    case $type in
        "number")
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "Harus berupa angka"
                return 1
            fi
            ;;
        "size")
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "Format harus seperti: 20G, 512M"
                return 1
            fi
            ;;
        "port")
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
                print_status "ERROR" "Port harus antara 1-65535"
                return 1
            fi
            # Cek port udah dipake
            if ss -tln 2>/dev/null | grep -q ":$value "; then
                print_status "ERROR" "Port $value sudah digunakan"
                return 1
            fi
            ;;
        "name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "Nama hanya boleh huruf, angka, -, _"
                return 1
            fi
            ;;
        "username")
            if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                print_status "ERROR" "Username harus huruf kecil, angka, _, -"
                return 1
            fi
            ;;
        "password")
            if [ -z "$value" ]; then
                print_status "ERROR" "Password tidak boleh kosong"
                return 1
            fi
            ;;
    esac
    return 0
}

# Cek dependencies
check_deps() {
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img" "openssl")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing[*]}"
        print_status "INFO" "Install with: sudo apt install qemu-system-x86 cloud-image-utils wget qemu-utils openssl"
        exit 1
    fi
}

# Get list VM
get_vms() {
    find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

# Cek VM running
is_running() {
    local vm=$1
    pgrep -f "qemu.*$vm" >/dev/null
}

# Load config VM
load_config() {
    local vm=$1
    local cfg="$VM_DIR/$vm.conf"
    
    if [ ! -f "$cfg" ]; then
        return 1
    fi
    
    # Reset variables
    unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
    unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED
    
    # Source config
    source "$cfg"
    
    # Set default values
    : ${MEMORY:=2048}
    : ${CPUS:=2}
    : ${SSH_PORT:=2222}
    : ${USERNAME:=user}
    : ${GUI_MODE:=false}
    
    return 0
}

# Save config VM
save_config() {
    local vm=$1
    local cfg="$VM_DIR/$vm.conf"
    
    cat > "$cfg" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="$SSH_PORT"
GUI_MODE="$GUI_MODE"
PORT_FORWARDS="$PORT_FORWARDS"
IMG_FILE="$IMG_FILE"
SEED_FILE="$SEED_FILE"
CREATED="$CREATED"
EOF
    
    print_status "SUCCESS" "Config saved: $cfg"
}

# Generate random password
gen_password() {
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-12
}

# Setup VM image
setup_image() {
    local vm=$1
    
    print_status "INFO" "Preparing VM image..."
    
    # Download image if needed
    if [ ! -f "$IMG_FILE" ]; then
        print_status "INFO" "Downloading image from $IMG_URL..."
        if ! wget -q --show-progress "$IMG_URL" -O "$IMG_FILE.tmp"; then
            print_status "ERROR" "Download failed"
            rm -f "$IMG_FILE.tmp"
            return 1
        fi
        mv "$IMG_FILE.tmp" "$IMG_FILE"
    fi
    
    # Resize disk
    print_status "INFO" "Resizing disk to $DISK_SIZE..."
    qemu-img resize "$IMG_FILE" "$DISK_SIZE" >/dev/null 2>&1 || {
        print_status "WARN" "Resize failed, creating new image..."
        qemu-img create -f qcow2 "$IMG_FILE" "$DISK_SIZE" >/dev/null 2>&1
    }
    
    # Cloud-init config
    cat > user-data <<EOF
#cloud-config
hostname: $HOSTNAME
manage_etc_hosts: true
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: $(echo "$PASSWORD" | openssl passwd -6 -stdin)
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
package_update: false
package_upgrade: false
packages:
  - qemu-guest-agent
  - openssh-server
  - net-tools
  - curl
  - wget
runcmd:
  - systemctl enable --now ssh
  - systemctl enable --now qemu-guest-agent
  - echo "VM setup complete" > /var/log/vm-setup.log
EOF

    cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

    # Create seed image
    if ! cloud-localds "$SEED_FILE" user-data meta-data; then
        print_status "ERROR" "Failed to create seed image"
        return 1
    fi
    
    rm -f user-data meta-data
    print_status "SUCCESS" "VM image ready"
    return 0
}

# Create new VM
create_vm() {
    print_status "INFO" "Creating new VM"
    
    # OS Selection
    echo "Pilih OS:"
    echo "1) Ubuntu 22.04 LTS"
    echo "2) Ubuntu 24.04 LTS"
    echo "3) Debian 12"
    echo "4) Fedora 40"
    echo "5) CentOS Stream 9"
    echo "6) AlmaLinux 9"
    echo "7) Rocky Linux 9"
    echo "8) Custom URL"
    
    read -p "$(print_status "INPUT" "Pilihan [1-8]: ")" os_choice
    
    case $os_choice in
        1) OS_TYPE="ubuntu"; CODENAME="jammy"; IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"; DEFAULT_HOST="ubuntu22"; DEFAULT_USER="ubuntu" ;;
        2) OS_TYPE="ubuntu"; CODENAME="noble"; IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"; DEFAULT_HOST="ubuntu24"; DEFAULT_USER="ubuntu" ;;
        3) OS_TYPE="debian"; CODENAME="bookworm"; IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"; DEFAULT_HOST="debian12"; DEFAULT_USER="debian" ;;
        4) OS_TYPE="fedora"; CODENAME="40"; IMG_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2"; DEFAULT_HOST="fedora40"; DEFAULT_USER="fedora" ;;
        5) OS_TYPE="centos"; CODENAME="stream9"; IMG_URL="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"; DEFAULT_HOST="centos9"; DEFAULT_USER="centos" ;;
        6) OS_TYPE="almalinux"; CODENAME="9"; IMG_URL="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"; DEFAULT_HOST="alma9"; DEFAULT_USER="alma" ;;
        7) OS_TYPE="rocky"; CODENAME="9"; IMG_URL="https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"; DEFAULT_HOST="rocky9"; DEFAULT_USER="rocky" ;;
        8) 
            read -p "URL Image: " IMG_URL
            read -p "OS Type: " OS_TYPE
            read -p "Codename: " CODENAME
            DEFAULT_HOST="custom"
            DEFAULT_USER="user"
            ;;
        *) print_status "ERROR" "Pilihan salah"; return ;;
    esac
    
    # VM Name
    while true; do
        read -p "$(print_status "INPUT" "Nama VM (default: $DEFAULT_HOST): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOST}"
        if validate_input "name" "$VM_NAME"; then
            if [ -f "$VM_DIR/$VM_NAME.conf" ]; then
                print_status "ERROR" "VM $VM_NAME sudah ada"
            else
                break
            fi
        fi
    done
    
    # Hostname
    while true; do
        read -p "$(print_status "INPUT" "Hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        validate_input "name" "$HOSTNAME" && break
    done
    
    # Username
    while true; do
        read -p "$(print_status "INPUT" "Username (default: $DEFAULT_USER): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USER}"
        validate_input "username" "$USERNAME" && break
    done
    
    # Password
    while true; do
        read -s -p "$(print_status "INPUT" "Password (default: random): ")" PASSWORD
        echo
        if [ -z "$PASSWORD" ]; then
            PASSWORD=$(gen_password)
            echo "Generated password: $PASSWORD"
            break
        fi
        validate_input "password" "$PASSWORD" && break
    done
    
    # Disk size
    while true; do
        read -p "$(print_status "INPUT" "Disk size (default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        validate_input "size" "$DISK_SIZE" && break
    done
    
    # Memory
    while true; do
        read -p "$(print_status "INPUT" "Memory MB (default: 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        validate_input "number" "$MEMORY" && break
    done
    
    # CPU
    while true; do
        read -p "$(print_status "INPUT" "CPU cores (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        validate_input "number" "$CPUS" && break
    done
    
    # SSH Port
    while true; do
        read -p "$(print_status "INPUT" "SSH Port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if validate_input "port" "$SSH_PORT"; then
            # Cek port unik
            local port_used=0
            for vm in $(get_vms); do
                if load_config "$vm" 2>/dev/null; then
                    if [ "$SSH_PORT" = "$SSH_PORT" ] 2>/dev/null; then
                        port_used=1
                        break
                    fi
                fi
            done
            [ $port_used -eq 0 ] && break
            print_status "ERROR" "Port $SSH_PORT sudah dipakai VM lain"
        fi
    done
    
    # GUI mode
    while true; do
        read -p "$(print_status "INPUT" "GUI mode? (y/n, default: n): ")" gui
        gui="${gui:-n}"
        if [[ "$gui" =~ ^[YyNn]$ ]]; then
            GUI_MODE=$([[ "$gui" =~ ^[Yy]$ ]] && echo true || echo false)
            break
        fi
    done
    
    # Port forwarding
    echo "Port forwarding format: host_port:guest_port"
    echo "Contoh: 8080:80,8443:443"
    read -p "$(print_status "INPUT" "Port forwards (Enter jika tidak ada): ")" PORT_FORWARDS
    
    # Setup paths
    IMG_FILE="$VM_DIR/$VM_NAME.qcow2"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Setup image
    if ! setup_image "$VM_NAME"; then
        print_status "ERROR" "Gagal setup VM"
        return
    fi
    
    # Save config
    save_config "$VM_NAME"
    
    print_status "SUCCESS" "VM $VM_NAME created!"
    echo "==================================="
    echo "SSH: ssh -p $SSH_PORT $USERNAME@localhost"
    echo "Password: $PASSWORD"
    echo "==================================="
}

# Parse port forwards
parse_port_forwards() {
    local forwards=$1
    local qemu_args=""
    
    if [ -n "$forwards" ]; then
        IFS=',' read -ra items <<< "$forwards"
        for item in "${items[@]}"; do
            if [[ "$item" =~ ^[0-9]+:[0-9]+$ ]]; then
                host_port=$(echo "$item" | cut -d: -f1)
                guest_port=$(echo "$item" | cut -d: -f2)
                qemu_args="$qemu_args -netdev user,id=net$host_port,hostfwd=tcp::$host_port-:$guest_port -device virtio-net-pci,netdev=net$host_port"
            fi
        done
    fi
    
    echo "$qemu_args"
}

# Start VM
start_vm() {
    local vm=$1
    
    if ! load_config "$vm"; then
        print_status "ERROR" "VM $vm tidak ditemukan"
        return 1
    fi
    
    if is_running "$vm"; then
        print_status "WARN" "VM $vm sudah running"
        return 0
    fi
    
    print_status "INFO" "Starting VM: $vm"
    
    # Cek files
    if [ ! -f "$IMG_FILE" ]; then
        print_status "ERROR" "Image file not found: $IMG_FILE"
        return 1
    fi
    
    if [ ! -f "$SEED_FILE" ]; then
        print_status "WARN" "Seed file missing, recreating..."
        setup_image "$vm"
    fi
    
    # Kill existing process
    if pgrep -f "qemu.*$vm" >/dev/null; then
        pkill -f "qemu.*$vm" 2>/dev/null || true
        sleep 1
    fi
    
    # Check KVM
    kvm_flag=""
    [ -w /dev/kvm ] && kvm_flag="-enable-kvm"
    
    # Parse port forwards
    port_args=$(parse_port_forwards "${PORT_FORWARDS:-}")
    
    # Build QEMU command
    cmd="qemu-system-x86_64 $kvm_flag"
    cmd="$cmd -name $vm"
    cmd="$cmd -machine type=pc,accel=kvm:tcg"
    cmd="$cmd -cpu host"
    cmd="$cmd -smp $CPUS"
    cmd="$cmd -m $MEMORY"
    cmd="$cmd -drive file=$IMG_FILE,format=qcow2,if=virtio"
    cmd="$cmd -drive file=$SEED_FILE,format=raw,if=virtio"
    cmd="$cmd -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22"
    cmd="$cmd -device virtio-net-pci,netdev=net0"
    cmd="$cmd -device virtio-balloon-pci"
    cmd="$cmd -object rng-random,filename=/dev/urandom,id=rng0"
    cmd="$cmd -device virtio-rng-pci,rng=rng0"
    cmd="$cmd -boot order=c"
    cmd="$cmd -rtc base=localtime"
    
    # Add port forwards
    if [ -n "$port_args" ]; then
        cmd="$cmd $port_args"
    fi
    
    # GUI or console
    if [ "$GUI_MODE" = "true" ]; then
        cmd="$cmd -vga virtio -display gtk"
        eval "$cmd" &
        echo $! > "$VM_DIR/$vm.pid"
    else
        cmd="$cmd -nographic -serial mon:stdio"
        eval "$cmd"
    fi
    
    print_status "SUCCESS" "VM $vm started"
    echo "SSH: ssh -p $SSH_PORT $USERNAME@localhost"
    echo "Password: $PASSWORD"
}

# Stop VM
stop_vm() {
    local vm=$1
    
    if ! load_config "$vm"; then
        print_status "ERROR" "VM $vm tidak ditemukan"
        return 1
    fi
    
    if ! is_running "$vm"; then
        print_status "WARN" "VM $vm tidak running"
        return 0
    fi
    
    print_status "INFO" "Stopping VM: $vm"
    
    # Try PID file
    if [ -f "$VM_DIR/$vm.pid" ]; then
        pid=$(cat "$VM_DIR/$vm.pid")
        kill "$pid" 2>/dev/null || true
        sleep 1
        rm -f "$VM_DIR/$vm.pid"
    fi
    
    # Force kill if still running
    if is_running "$vm"; then
        pkill -f "qemu.*$vm" 2>/dev/null || true
        sleep 1
    fi
    
    print_status "SUCCESS" "VM $vm stopped"
}

# Show VM info
show_info() {
    local vm=$1
    
    if ! load_config "$vm"; then
        print_status "ERROR" "VM $vm tidak ditemukan"
        return 1
    fi
    
    local status="Stopped"
    is_running "$vm" && status="Running"
    
    echo
    echo "=========================================="
    echo "VM: $vm"
    echo "=========================================="
    echo "Status:     $status"
    echo "OS:         $OS_TYPE $CODENAME"
    echo "Hostname:   $HOSTNAME"
    echo "Username:   $USERNAME"
    echo "Password:   $PASSWORD"
    echo "SSH Port:   $SSH_PORT"
    echo "Memory:     $MEMORY MB"
    echo "CPUs:       $CPUS"
    echo "Disk:       $DISK_SIZE"
    echo "GUI Mode:   $GUI_MODE"
    echo "Created:    $CREATED"
    if [ -n "${PORT_FORWARDS:-}" ]; then
        echo "Port Forwards: $PORT_FORWARDS"
    fi
    echo "Image:      $IMG_FILE"
    echo "=========================================="
    echo
}

# Delete VM
delete_vm() {
    local vm=$1
    
    if ! load_config "$vm"; then
        print_status "ERROR" "VM $vm tidak ditemukan"
        return 1
    fi
    
    if is_running "$vm"; then
        print_status "WARN" "VM $vm masih running, stop dulu"
        return 1
    fi
    
    print_status "WARN" "Hapus VM $vm? Semua data akan hilang!"
    read -p "Ketik 'DELETE' untuk konfirmasi: " confirm
    [ "$confirm" != "DELETE" ] && return
    
    # Delete files
    rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm.conf" "$VM_DIR/$vm.pid"
    
    print_status "SUCCESS" "VM $vm deleted"
}

# Edit VM
edit_vm() {
    local vm=$1
    
    if ! load_config "$vm"; then
        print_status "ERROR" "VM $vm tidak ditemukan"
        return 1
    fi
    
    if is_running "$vm"; then
        print_status "WARN" "Stop VM dulu sebelum edit"
        return 1
    fi
    
    while true; do
        echo
        echo "Edit VM: $vm"
        echo "1) Hostname (current: $HOSTNAME)"
        echo "2) Username (current: $USERNAME)"
        echo "3) Password"
        echo "4) SSH Port (current: $SSH_PORT)"
        echo "5) Memory (current: $MEMORY MB)"
        echo "6) CPU (current: $CPUS)"
        echo "7) GUI Mode (current: $GUI_MODE)"
        echo "8) Port Forwards (current: ${PORT_FORWARDS:-None})"
        echo "9) Disk Size (current: $DISK_SIZE)"
        echo "0) Selesai"
        
        read -p "Pilihan: " choice
        
        case $choice in
            1)
                read -p "Hostname baru: " new
                [ -n "$new" ] && validate_input "name" "$new" && HOSTNAME="$new"
                ;;
            2)
                read -p "Username baru: " new
                [ -n "$new" ] && validate_input "username" "$new" && USERNAME="$new"
                ;;
            3)
                read -s -p "Password baru: " new
                echo
                [ -n "$new" ] && validate_input "password" "$new" && PASSWORD="$new"
                ;;
            4)
                read -p "SSH Port baru: " new
                if [ -n "$new" ] && validate_input "port" "$new"; then
                    # Cek port unik
                    local port_used=0
                    for v in $(get_vms); do
                        if [ "$v" != "$vm" ] && load_config "$v" 2>/dev/null; then
                            if [ "$new" = "$SSH_PORT" ] 2>/dev/null; then
                                port_used=1
                                break
                            fi
                        fi
                    done
                    [ $port_used -eq 0 ] && SSH_PORT="$new"
                fi
                ;;
            5)
                read -p "Memory baru (MB): " new
                [ -n "$new" ] && validate_input "number" "$new" && MEMORY="$new"
                ;;
            6)
                read -p "CPU baru: " new
                [ -n "$new" ] && validate_input "number" "$new" && CPUS="$new"
                ;;
            7)
                GUI_MODE=$([ "$GUI_MODE" = "true" ] && echo false || echo true)
                echo "GUI Mode: $GUI_MODE"
                ;;
            8)
                read -p "Port forwards baru: " new
                PORT_FORWARDS="$new"
                ;;
            9)
                read -p "Disk size baru: " new
                if [ -n "$new" ] && validate_input "size" "$new"; then
                    print_status "INFO" "Resizing disk to $new..."
                    if qemu-img resize "$IMG_FILE" "$new"; then
                        DISK_SIZE="$new"
                    else
                        print_status "ERROR" "Resize failed"
                    fi
                fi
                ;;
            0)
                # Recreate seed if needed
                if [ "$choice" -le 3 ]; then
                    setup_image "$vm"
                fi
                save_config "$vm"
                break
                ;;
        esac
    done
}

# Show performance
show_performance() {
    local vm=$1
    
    if ! load_config "$vm"; then
        print_status "ERROR" "VM $vm tidak ditemukan"
        return 1
    fi
    
    if ! is_running "$vm"; then
        print_status "INFO" "VM $vm tidak running"
        return 0
    fi
    
    local pid=$(pgrep -f "qemu.*$vm" | head -1)
    
    echo
    echo "=========================================="
    echo "Performance: $vm"
    echo "=========================================="
    
    if [ -n "$pid" ]; then
        echo "PID: $pid"
        echo "CPU Usage:"
        ps -p "$pid" -o %cpu,%mem,time --no-headers
        echo
        echo "Memory Info:"
        free -h
        echo
        echo "Disk IO:"
        iostat -x 1 2 2>/dev/null || echo "Install sysstat for disk stats"
    fi
    echo "=========================================="
    echo
}

# Main menu
main_menu() {
    while true; do
        display_header
        
        local vms=($(get_vms))
        local count=${#vms[@]}
        
        echo -e "${CYAN}Daftar VM:${NC}"
        if [ $count -eq 0 ]; then
            echo "  (Belum ada VM)"
        else
            for i in "${!vms[@]}"; do
                local status=$([ $(is_running "${vms[$i]}") ] && echo "${GREEN}Running${NC}" || echo "${RED}Stopped${NC}")
                printf "  %2d) %-20s %b\n" $((i+1)) "${vms[$i]}" "$status"
            done
        fi
        
        echo
        echo "Menu:"
        echo "  a) Buat VM baru"
        if [ $count -gt 0 ]; then
            echo "  b) Start VM"
            echo "  c) Stop VM"
            echo "  d) Info VM"
            echo "  e) Edit VM"
            echo "  f) Hapus VM"
            echo "  g) Performance VM"
        fi
        echo "  x) Keluar"
        echo
        
        read -p "Pilih: " menu
        
        case $menu in
            a|A) create_vm ;;
            b|B)
                if [ $count -gt 0 ]; then
                    read -p "Nomor VM: " num
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $count ]; then
                        start_vm "${vms[$((num-1))]}"
                    fi
                fi
                ;;
            c|C)
                if [ $count -gt 0 ]; then
                    read -p "Nomor VM: " num
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $count ]; then
                        stop_vm "${vms[$((num-1))]}"
                    fi
                fi
                ;;
            d|D)
                if [ $count -gt 0 ]; then
                    read -p "Nomor VM: " num
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $count ]; then
                        show_info "${vms[$((num-1))]}"
                    fi
                fi
                ;;
            e|E)
                if [ $count -gt 0 ]; then
                    read -p "Nomor VM: " num
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $count ]; then
                        edit_vm "${vms[$((num-1))]}"
                    fi
                fi
                ;;
            f|F)
                if [ $count -gt 0 ]; then
                    read -p "Nomor VM: " num
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $count ]; then
                        delete_vm "${vms[$((num-1))]}"
                    fi
                fi
                ;;
            g|G)
                if [ $count -gt 0 ]; then
                    read -p "Nomor VM: " num
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $count ]; then
                        show_performance "${vms[$((num-1))]}"
                    fi
                fi
                ;;
            x|X)
                print_status "INFO" "Bye!"
                exit 0
                ;;
            *)
                print_status "ERROR" "Pilihan salah"
                ;;
        esac
        
        echo
        read -p "Press Enter..."
    done
}

# Trap exit
trap 'rm -f user-data meta-data 2>/dev/null' EXIT

# Check dependencies
check_deps

# Start
main_menu

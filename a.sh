#!/bin/bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager
# Fixed for Reboot Safety
# =============================

# Function to display header
display_header() {
    clear
    cat << "EOF"
========================================================================
Sponsor By These Guys!                                                                  
HOPINGBOYZ
Jishnu
NotGamerPie
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

# Function to validate input
validate_input() {
    local type=$1
    local value=$2
    
    case $type in
        "number")
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "Must be a number"
                return 1
            fi
            ;;
        "size")
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "Must be a size with unit (e.g., 100G, 512M)"
                return 1
            fi
            ;;
        "port")
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 23 ] || [ "$value" -gt 65535 ]; then
                print_status "ERROR" "Must be a valid port number (23-65535)"
                return 1
            fi
            ;;
        "name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "VM name can only contain letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
        "username")
            if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                print_status "ERROR" "Username must start with a letter or underscore, and contain only letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
    esac
    return 0
}

# Function to check dependencies
check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing_deps[*]}"
        print_status "INFO" "On Ubuntu/Debian, try: sudo apt install qemu-system cloud-image-utils wget"
        exit 1
    fi
}

# Function to cleanup temporary files (only temp files, not VM files)
cleanup() {
    # Only cleanup temporary cloud-init files in current directory
    if [ -f "./user-data.tmp" ]; then rm -f "./user-data.tmp"; fi
    if [ -f "./meta-data.tmp" ]; then rm -f "./meta-data.tmp"; fi
}

# Function to create PID file directory
ensure_pid_dir() {
    local pid_dir="$VM_DIR/.pids"
    mkdir -p "$pid_dir"
    echo "$pid_dir"
}

# Function to write PID file
write_pid_file() {
    local vm_name=$1
    local pid=$2
    local pid_dir=$(ensure_pid_dir)
    echo "$pid" > "$pid_dir/$vm_name.pid"
}

# Function to remove PID file
remove_pid_file() {
    local vm_name=$1
    local pid_dir=$(ensure_pid_dir)
    rm -f "$pid_dir/$vm_name.pid"
}

# Function to read PID file
read_pid_file() {
    local vm_name=$1
    local pid_dir=$(ensure_pid_dir)
    if [ -f "$pid_dir/$vm_name.pid" ]; then
        cat "$pid_dir/$vm_name.pid"
    fi
}

# Function to get all VM configurations
get_vm_list() {
    find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

# Function to load VM configuration
load_vm_config() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"
    
    if [[ -f "$config_file" ]]; then
        # Clear previous variables
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
        unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED AUTOSTART
        
        source "$config_file"
        
        # Set default for AUTOSTART if not present (for backwards compatibility)
        AUTOSTART="${AUTOSTART:-false}"
        
        return 0
    else
        print_status "ERROR" "Configuration for VM '$vm_name' not found"
        return 1
    fi
}

# Function to save VM configuration
save_vm_config() {
    local config_file="$VM_DIR/$VM_NAME.conf"
    
    cat > "$config_file" <<EOF
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
AUTOSTART="${AUTOSTART:-false}"
EOF
    
    print_status "SUCCESS" "Configuration saved to $config_file"
}

# Function to create systemd service for VM
create_systemd_service() {
    local vm_name=$1
    
    if ! command -v systemctl &> /dev/null; then
        print_status "WARN" "systemd not available. Autostart feature disabled."
        return 1
    fi
    
    if load_vm_config "$vm_name"; then
        local service_file="$HOME/.config/systemd/user/vm-$vm_name.service"
        mkdir -p "$HOME/.config/systemd/user"
        
        cat > "$service_file" <<EOF
[Unit]
Description=QEMU VM - $vm_name
After=network.target

[Service]
Type=simple
ExecStart=$0 --start-service $vm_name
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
        
        systemctl --user daemon-reload
        
        if [[ "$AUTOSTART" == true ]]; then
            systemctl --user enable "vm-$vm_name.service"
            print_status "SUCCESS" "Systemd service created and enabled for $vm_name"
        else
            systemctl --user disable "vm-$vm_name.service" 2>/dev/null || true
            print_status "SUCCESS" "Systemd service created for $vm_name"
        fi
        
        return 0
    fi
    return 1
}

# Function to remove systemd service
remove_systemd_service() {
    local vm_name=$1
    
    if command -v systemctl &> /dev/null; then
        systemctl --user stop "vm-$vm_name.service" 2>/dev/null || true
        systemctl --user disable "vm-$vm_name.service" 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/vm-$vm_name.service"
        systemctl --user daemon-reload
    fi
}

# Function to create new VM
create_new_vm() {
    print_status "INFO" "Creating a new VM"
    
    # OS Selection
    print_status "INFO" "Select an OS to set up:"
    local os_options=()
    local i=1
    for os in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $os"
        os_options[$i]="$os"
        ((i++))
    done
    
    while true; do
        read -p "$(print_status "INPUT" "Enter your choice (1-${#OS_OPTIONS[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#OS_OPTIONS[@]} ]; then
            local os="${os_options[$choice]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$os]}"
            break
        else
            print_status "ERROR" "Invalid selection. Try again."
        fi
    done

    # Custom Inputs with validation
    while true; do
        read -p "$(print_status "INPUT" "Enter VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        if validate_input "name" "$VM_NAME"; then
            # Check if VM name already exists
            if [[ -f "$VM_DIR/$VM_NAME.conf" ]]; then
                print_status "ERROR" "VM with name '$VM_NAME' already exists"
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        if validate_input "name" "$HOSTNAME"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        if validate_input "username" "$USERNAME"; then
            break
        fi
    done

    while true; do
        read -s -p "$(print_status "INPUT" "Enter password (default: $DEFAULT_PASSWORD): ")" PASSWORD
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        echo
        if [ -n "$PASSWORD" ]; then
            break
        else
            print_status "ERROR" "Password cannot be empty"
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Disk size (default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        if validate_input "size" "$DISK_SIZE"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Memory in MB (default: 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        if validate_input "number" "$MEMORY"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Number of CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        if validate_input "number" "$CPUS"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "SSH Port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if validate_input "port" "$SSH_PORT"; then
            # Check if port is already in use
            if ss -tln 2>/dev/null | grep -q ":$SSH_PORT " || netstat -tln 2>/dev/null | grep -q ":$SSH_PORT "; then
                print_status "ERROR" "Port $SSH_PORT is already in use"
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enable GUI mode? (y/n, default: n): ")" gui_input
        GUI_MODE=false
        gui_input="${gui_input:-n}"
        if [[ "$gui_input" =~ ^[Yy]$ ]]; then 
            GUI_MODE=true
            break
        elif [[ "$gui_input" =~ ^[Nn]$ ]]; then
            break
        else
            print_status "ERROR" "Please answer y or n"
        fi
    done

    # Autostart option
    while true; do
        read -p "$(print_status "INPUT" "Auto-start on boot? (y/n, default: n): ")" autostart_input
        AUTOSTART=false
        autostart_input="${autostart_input:-n}"
        if [[ "$autostart_input" =~ ^[Yy]$ ]]; then 
            AUTOSTART=true
            break
        elif [[ "$autostart_input" =~ ^[Nn]$ ]]; then
            break
        else
            print_status "ERROR" "Please answer y or n"
        fi
    done

    # Additional network options
    read -p "$(print_status "INPUT" "Additional port forwards (e.g., 8080:80, press Enter for none): ")" PORT_FORWARDS

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    # Download and setup VM image
    setup_vm_image
    
    # Save configuration
    save_vm_config
    
    # Create systemd service if autostart is enabled
    if [[ "$AUTOSTART" == true ]]; then
        create_systemd_service "$VM_NAME"
    fi
}

# Function to setup VM image
setup_vm_image() {
    print_status "INFO" "Downloading and preparing image..."
    
    # Create VM directory if it doesn't exist
    mkdir -p "$VM_DIR"
    
    # Check if image already exists
    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "Image file already exists. Skipping download."
    else
        print_status "INFO" "Downloading image from $IMG_URL..."
        if ! wget --progress=bar:force "$IMG_URL" -O "$IMG_FILE.tmp"; then
            print_status "ERROR" "Failed to download image from $IMG_URL"
            rm -f "$IMG_FILE.tmp"
            exit 1
        fi
        mv "$IMG_FILE.tmp" "$IMG_FILE"
    fi
    
    # Resize the disk image if needed
    local current_size=$(qemu-img info "$IMG_FILE" | grep "virtual size" | awk '{print $3}')
    if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
        print_status "WARN" "Failed to resize disk image. Image will remain at original size."
    else
        print_status "SUCCESS" "Disk image resized to $DISK_SIZE"
    fi

    # cloud-init configuration - use temporary files
    cat > "./user-data.tmp" <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: $(echo "$PASSWORD" | openssl passwd -6 -stdin 2>/dev/null || echo "\$6\$rounds=4096\$salt\$hash")
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
runcmd:
  - sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd || service ssh restart
EOF

    cat > "./meta-data.tmp" <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

    if ! cloud-localds "$SEED_FILE" "./user-data.tmp" "./meta-data.tmp"; then
        print_status "ERROR" "Failed to create cloud-init seed image"
        rm -f "./user-data.tmp" "./meta-data.tmp"
        exit 1
    fi
    
    # Cleanup temporary files
    rm -f "./user-data.tmp" "./meta-data.tmp"
    
    print_status "SUCCESS" "VM '$VM_NAME' created successfully."
}

# Function to start a VM (with optional background mode)
start_vm() {
    local vm_name=$1
    local background=${2:-false}
    
    if load_vm_config "$vm_name"; then
        # Check if already running
        if is_vm_running "$vm_name"; then
            print_status "WARN" "VM '$vm_name' is already running"
            return 1
        fi
        
        print_status "INFO" "Starting VM: $vm_name"
        print_status "INFO" "SSH: ssh -p $SSH_PORT $USERNAME@localhost"
        print_status "INFO" "Password: $PASSWORD"
        
        # Check if image file exists
        if [[ ! -f "$IMG_FILE" ]]; then
            print_status "ERROR" "VM image file not found: $IMG_FILE"
            print_status "INFO" "Attempting to recreate VM image..."
            setup_vm_image
        fi
        
        # Check if seed file exists
        if [[ ! -f "$SEED_FILE" ]]; then
            print_status "WARN" "Seed file not found, recreating..."
            setup_vm_image
        fi
        
        # Base QEMU command
        local qemu_cmd=(
            qemu-system-x86_64
            -enable-kvm
            -m "$MEMORY"
            -smp "$CPUS"
            -cpu host
            -drive "file=$IMG_FILE,format=qcow2,if=virtio"
            -drive "file=$SEED_FILE,format=raw,if=virtio"
            -boot order=c
            -device virtio-net-pci,netdev=n0
            -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22"
        )

        # Add port forwards if specified
        if [[ -n "$PORT_FORWARDS" ]]; then
            IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
            local net_id=1
            for forward in "${forwards[@]}"; do
                IFS=':' read -r host_port guest_port <<< "$forward"
                if [[ -n "$host_port" && -n "$guest_port" ]]; then
                    qemu_cmd+=(-netdev "user,id=n$net_id,hostfwd=tcp::$host_port-:$guest_port")
                    ((net_id++))
                fi
            done
        fi

        # Add GUI or console mode
        if [[ "$GUI_MODE" == true ]]; then
            qemu_cmd+=(-vga virtio -display gtk,gl=on)
        else
            qemu_cmd+=(-nographic -serial mon:stdio)
        fi

        # Add performance enhancements
        qemu_cmd+=(
            -device virtio-balloon-pci
            -object rng-random,filename=/dev/urandom,id=rng0
            -device virtio-rng-pci,rng=rng0
        )

        # Add daemonize flag if background mode
        if [[ "$background" == true ]]; then
            qemu_cmd+=(-daemonize -pidfile "$VM_DIR/.pids/$vm_name.qemu.pid")
        fi

        print_status "INFO" "Starting QEMU..."
        
        if [[ "$background" == true ]]; then
            # Start in background
            "${qemu_cmd[@]}" &
            local qemu_pid=$!
            write_pid_file "$vm_name" "$qemu_pid"
            print_status "SUCCESS" "VM $vm_name started in background (PID: $qemu_pid)"
        else
            # Start in foreground
            "${qemu_cmd[@]}"
            print_status "INFO" "VM $vm_name has been shut down"
            remove_pid_file "$vm_name"
        fi
    fi
}

# Function to delete a VM
delete_vm() {
    local vm_name=$1
    
    print_status "WARN" "This will permanently delete VM '$vm_name' and all its data!"
    read -p "$(print_status "INPUT" "Are you sure? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if load_vm_config "$vm_name"; then
            # Stop VM if running
            if is_vm_running "$vm_name"; then
                stop_vm "$vm_name"
            fi
            
            # Remove systemd service
            remove_systemd_service "$vm_name"
            
            # Delete files
            rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.conf"
            remove_pid_file "$vm_name"
            
            print_status "SUCCESS" "VM '$vm_name' has been deleted"
        fi
    else
        print_status "INFO" "Deletion cancelled"
    fi
}

# Function to show VM info
show_vm_info() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        echo
        print_status "INFO" "VM Information: $vm_name"
        echo "=========================================="
        echo "OS: $OS_TYPE"
        echo "Hostname: $HOSTNAME"
        echo "Username: $USERNAME"
        echo "Password: $PASSWORD"
        echo "SSH Port: $SSH_PORT"
        echo "Memory: $MEMORY MB"
        echo "CPUs: $CPUS"
        echo "Disk: $DISK_SIZE"
        echo "GUI Mode: $GUI_MODE"
        echo "Auto-start: $AUTOSTART"
        echo "Port Forwards: ${PORT_FORWARDS:-None}"
        echo "Created: $CREATED"
        echo "Image File: $IMG_FILE"
        echo "Seed File: $SEED_FILE"
        echo "Status: $(is_vm_running "$vm_name" && echo "Running" || echo "Stopped")"
        echo "=========================================="
        echo
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

# Function to check if VM is running
is_vm_running() {
    local vm_name=$1
    local pid=$(read_pid_file "$vm_name")
    
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
    elif pgrep -f "qemu-system-x86_64.*$vm_name" >/dev/null; then
        # PID file doesn't match but process exists
        return 0
    else
        # Clean up stale PID file
        remove_pid_file "$vm_name"
        return 1
    fi
}

# Function to stop a running VM
stop_vm() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            print_status "INFO" "Stopping VM: $vm_name"
            
            local pid=$(read_pid_file "$vm_name")
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid"
                sleep 2
                if kill -0 "$pid" 2>/dev/null; then
                    print_status "WARN" "VM did not stop gracefully, forcing termination..."
                    kill -9 "$pid"
                fi
            else
                # Fallback: kill by process name
                pkill -f "qemu-system-x86_64.*$vm_name" || true
                sleep 1
                if pgrep -f "qemu-system-x86_64.*$vm_name" >/dev/null; then
                    pkill -9 -f "qemu-system-x86_64.*$vm_name"
                fi
            fi
            
            remove_pid_file "$vm_name"
            print_status "SUCCESS" "VM $vm_name stopped"
        else
            print_status "INFO" "VM $vm_name is not running"
        fi
    fi
}

# Function to edit VM configuration
edit_vm_config() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        local was_running=false
        if is_vm_running "$vm_name"; then
            was_running=true
            print_status "WARN" "VM is currently running. Some changes may require a restart."
        fi
        
        print_status "INFO" "Editing VM: $vm_name"
        
        while true; do
            echo "What would you like to edit?"
            echo "  1) Hostname"
            echo "  2) Username"
            echo "  3) Password"
            echo "  4) SSH Port"
            echo "  5) GUI Mode"
            echo "  6) Port Forwards"
            echo "  7) Memory (RAM)"
            echo "  8) CPU Count"
            echo "  9) Disk Size"
            echo " 10) Auto-start on boot"
            echo "  0) Back to main menu"
            
            read -p "$(print_status "INPUT" "Enter your choice: ")" edit_choice
            
            case $edit_choice in
                1)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new hostname (current: $HOSTNAME): ")" new_hostname
                        new_hostname="${new_hostname:-$HOSTNAME}"
                        if validate_input "name" "$new_hostname"; then
                            HOSTNAME="$new_hostname"
                            break
                        fi
                    done
                    ;;
                2)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new username (current: $USERNAME): ")" new_username
                        new_username="${new_username:-$USERNAME}"
                        if validate_input "username" "$new_username"; then
                            USERNAME="$new_username"
                            break
                        fi
                    done
                    ;;
                3)
                    while true; do
                        read -s -p "$(print_status "INPUT" "Enter new password (current: ****): ")" new_password
                        new_password="${new_password:-$PASSWORD}"
                        echo
                        if [ -n "$new_password" ]; then
                            PASSWORD="$new_password"
                            break
                        else
                            print_status "ERROR" "Password cannot be empty"
                        fi
                    done
                    ;;
                4)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new SSH port (current: $SSH_PORT): ")" new_ssh_port
                        new_ssh_port="${new_ssh_port:-$SSH_PORT}"
                        if validate_input "port" "$new_ssh_port"; then
                            # Check if port is already in use
                            if [ "$new_ssh_port" != "$SSH_PORT" ] && (ss -tln 2>/dev/null | grep -q ":$new_ssh_port " || netstat -tln 2>/dev/null | grep -q ":$new_ssh_port "); then
                                print_status "ERROR" "Port $new_ssh_port is already in use"
                            else
                                SSH_PORT="$new_ssh_port"
                                break
                            fi
                        fi
                    done
                    ;;
                5)
                    while true; do
                        read -p "$(print_status "INPUT" "Enable GUI mode? (y/n, current: $GUI_MODE): ")" gui_input
                        gui_input="${gui_input:-}"
                        if [[ "$gui_input" =~ ^[Yy]$ ]]; then 
                            GUI_MODE=true
                            break
                        elif [[ "$gui_input" =~ ^[Nn]$ ]]; then
                            GUI_MODE=false
                            break
                        elif [ -z "$gui_input" ]; then
                            break
                        else
                            print_status "ERROR" "Please answer y or n"
                        fi
                    done
                    ;;
                6)
                    read -p "$(print_status "INPUT" "Additional port forwards (current: ${PORT_FORWARDS:-None}): ")" new_port_forwards
                    PORT_FORWARDS="${new_port_forwards:-$PORT_FORWARDS}"
                    ;;
                7)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new memory in MB (current: $MEMORY): ")" new_memory
                        new_memory="${new_memory:-$MEMORY}"
                        if validate_input "number" "$new_memory"; then
                            MEMORY="$new_memory"
                            break
                        fi
                    done
                    ;;
                8)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new CPU count (current: $CPUS): ")" new_cpus
                        new_cpus="${new_cpus:-$CPUS}"
                        if validate_input "number" "$new_cpus"; then
                            CPUS="$new_cpus"
                            break
                        fi
                    done
                    ;;
                9)
                    resize_vm_disk "$vm_name"
                    return 0
                    ;;
                10)
                    while true; do
                        read -p "$(print_status "INPUT" "Enable auto-start? (y/n, current: $AUTOSTART): ")" autostart_input
                        if [[ "$autostart_input" =~ ^[Yy]$ ]]; then 
                            AUTOSTART=true
                            create_systemd_service "$vm_name"
                            break
                        elif [[ "$autostart_input" =~ ^[Nn]$ ]]; then
                            AUTOSTART=false
                            remove_systemd_service "$vm_name"
                            break
                        elif [ -z "$autostart_input" ]; then
                            break
                        else
                            print_status "ERROR" "Please answer y or n"
                        fi
                    done
                    ;;
                0)
                    return 0
                    ;;
                *)
                    print_status "ERROR" "Invalid selection"
                    continue
                    ;;
            esac
            
            # Recreate seed image with new configuration if user/password/hostname changed
            if [[ "$edit_choice" -eq 1 || "$edit_choice" -eq 2 || "$edit_choice" -eq 3 ]]; then
                print_status "INFO" "Updating cloud-init configuration..."
                setup_vm_image
            fi
            
            # Save configuration
            save_vm_config
            
            if [[ "$was_running" == true ]] && [[ "$edit_choice" -ne 10 ]]; then
                print_status "WARN" "Changes saved. Restart VM for changes to take effect."
            fi
            
            read -p "$(print_status "INPUT" "Continue editing? (y/N): ")" continue_editing
            if [[ ! "$continue_editing" =~ ^[Yy]$ ]]; then
                break
            fi
        done
    fi
}

# Function to resize VM disk
resize_vm_disk() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Current disk size: $DISK_SIZE"
        
        while true; do
            read -p "$(print_status "INPUT" "Enter new disk size (e.g., 50G): ")" new_disk_size
            if validate_input "size" "$new_disk_size"; then
                if [[ "$new_disk_size" == "$DISK_SIZE" ]]; then
                    print_status "INFO" "New disk size is the same as current size. No changes made."
                    return 0
                fi
                
                # Check if new size is smaller than current (not recommended)
                local current_size_num=${DISK_SIZE%[GgMm]}
                local new_size_num=${new_disk_size%[GgMm]}
                local current_unit=${DISK_SIZE: -1}
                local new_unit=${new_disk_size: -1}
                
                # Convert both to MB for comparison
                if [[ "$current_unit" =~ [Gg] ]]; then
                    current_size_num=$((current_size_num * 1024))
                fi
                if [[ "$new_unit" =~ [Gg] ]]; then
                    new_size_num=$((new_size_num * 1024))
                fi
                
                if [[ $new_size_num -lt $current_size_num ]]; then
                    print_status "WARN" "Shrinking disk size is not recommended and may cause data loss!"
                    read -p "$(print_status "INPUT" "Are you sure you want to continue? (y/N): ")" confirm_shrink
                    if [[ ! "$confirm_shrink" =~ ^[Yy]$ ]]; then
                        print_status "INFO" "Disk resize cancelled."
                        return 0
                    fi
                fi
                
                # Resize the disk
                print_status "INFO" "Resizing disk to $new_disk_size..."
                if qemu-img resize "$IMG_FILE" "$new_disk_size"; then
                    DISK_SIZE="$new_disk_size"
                    save_vm_config
                    print_status "SUCCESS" "Disk resized successfully to $new_disk_size"
                    print_status "INFO" "You may need to resize the partition inside the VM"
                else
                    print_status "ERROR" "Failed to resize disk"
                    return 1
                fi
                break
            fi
        done
    fi
}

# Function to show VM performance metrics
show_vm_performance() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            print_status "INFO" "Performance metrics for VM: $vm_name"
            echo "=========================================="
            
            # Get QEMU process ID
            local qemu_pid=$(read_pid_file "$vm_name")
            if [[ -z "$qemu_pid" ]]; then
                qemu_pid=$(pgrep -f "qemu-system-x86_64.*$vm_name")
            fi
            
            if [[ -n "$qemu_pid" ]]; then
                # Show process stats
                echo "QEMU Process Stats:"
                ps -p "$qemu_pid" -o pid,%cpu,%mem,sz,rss,vsz,cmd --no-headers 2>/dev/null || echo "Unable to get process stats"
                echo
                
                # Show memory usage
                echo "Memory Usage:"
                free -h
                echo
                
                # Show disk usage
                echo "Disk Usage:"
                df -h "$IMG_FILE" 2>/dev/null || du -h "$IMG_FILE"
            else
                print_status "ERROR" "Could not find QEMU process for VM $vm_name"
            fi
        else
            print_status "INFO" "VM $vm_name is not running"
            echo "Configuration:"
            echo "  Memory: $MEMORY MB"
            echo "  CPUs: $CPUS"
            echo "  Disk: $DISK_SIZE"
        fi
        echo "=========================================="
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

# Main menu function
main_menu() {
    while true; do
        display_header
        
        local vms=($(get_vm_list))
        local vm_count=${#vms[@]}
        
        if [ $vm_count -gt 0 ]; then
            print_status "INFO" "Found $vm_count existing VM(s):"
            for i in "${!vms[@]}"; do
                local status="Stopped"
                local autostart_mark=""
                if is_vm_running "${vms[$i]}"; then
                    status="Running"
                fi
                if load_vm_config "${vms[$i]}" && [[ "$AUTOSTART" == true ]]; then
                    autostart_mark="[Auto]"
                fi
                printf "  %2d) %-20s (%s) %s\n" $((i+1)) "${vms[$i]}" "$status" "$autostart_mark"
            done
            echo
        fi
        
        echo "Main Menu:"
        echo "  1) Create a new VM"
        if [ $vm_count -gt 0 ]; then
            echo "  2) Start a VM"
            echo "  3) Stop a VM"
            echo "  4) Show VM info"
            echo "  5) Edit VM configuration"
            echo "  6) Delete a VM"
            echo "  7) Resize VM disk"
            echo "  8) Show VM performance"
            echo "  9) Start VM in background"
        fi
        echo "  0) Exit"
        echo
        
        read -p "$(print_status "INPUT" "Enter your choice: ")" choice
        
        case $choice in
            1)
                create_new_vm
                ;;
            2)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to start: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        start_vm "${vms[$((vm_num-1))]}" false
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            3)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to stop: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        stop_vm "${vms[$((vm_num-1))]}"
                        read -p "$(print_status "INPUT" "Press Enter to continue...")"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            4)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to show info: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_info "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            5)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to edit: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        edit_vm_config "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            6)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to delete: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        delete_vm "${vms[$((vm_num-1))]}"
                        read -p "$(print_status "INPUT" "Press Enter to continue...")"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            7)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to resize disk: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        resize_vm_disk "${vms[$((vm_num-1))]}"
                        read -p "$(print_status "INPUT" "Press Enter to continue...")"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            8)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to show performance: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_performance "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            9)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to start in background: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        start_vm "${vms[$((vm_num-1))]}" true
                        read -p "$(print_status "INPUT" "Press Enter to continue...")"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            0)
                print_status "INFO" "Goodbye!"
                exit 0
                ;;
            *)
                print_status "ERROR" "Invalid option"
                read -p "$(print_status "INPUT" "Press Enter to continue...")"
                ;;
        esac
    done
}

# Handle command-line arguments (for systemd service)
if [[ "${1:-}" == "--start-service" ]] && [[ -n "${2:-}" ]]; then
    # This is being called by systemd service
    VM_DIR="${VM_DIR:-$HOME/vms}"
    start_vm "$2" true
    exit 0
fi

# Set trap to cleanup on exit
trap cleanup EXIT

# Check dependencies
check_dependencies

# Initialize paths
VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"
ensure_pid_dir

# Supported OS list
declare -A OS_OPTIONS=(
    ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Fedora 40"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|fedora40|fedora|fedora"
    ["CentOS Stream 9"]="centos|stream9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2|centos9|centos|centos"
    ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|almalinux9|alma|alma"
    ["Rocky Linux 9"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
)

# Start the main menu
main_menu

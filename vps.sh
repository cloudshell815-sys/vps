#!/bin/bash

# ==============================================
# VM MANAGER - Simple Virtual Machine Controller
# Created by: Linux User
# Date: $(date +%Y)
# ==============================================

# Warna buat output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default direktori
VM_DIR="$HOME/vms"
mkdir -p "$VM_DIR" 2>/dev/null

# Cek dependencies yang diperlukan
check_deps() {
    local deps=("qemu-system-x86_64" "wget" "qemu-img" "openssl")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}⚠️  Beberapa tools belum terinstall:${NC}"
        printf '  %s\n' "${missing[@]}"
        echo -e "${YELLOW}Jalankan: sudo apt install qemu-system-x86 qemu-utils wget openssl${NC}"
        read -p "Lanjutkan? (y/n) " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
}

# Validasi input user
validate() {
    case $1 in
        "name")
            [[ "$2" =~ ^[a-z][a-z0-9_-]{2,20}$ ]] || return 1
            ;;
        "port")
            [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1024 ] && [ "$2" -le 65535 ] || return 1
            ;;
        "size")
            [[ "$2" =~ ^[0-9]+[GM]$ ]] || return 1
            ;;
        "number")
            [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -gt 0 ] || return 1
            ;;
    esac
    return 0
}

# Bersihin layar
clear_screen() {
    printf "\033c"
}

# Header
show_header() {
    clear_screen
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════╗"
    echo "║           VM MANAGER - Simple Edition         ║"
    echo "║           -------------------------            ║"
    echo "║                                                ║"
    echo "║  Manage your virtual machines easily          ║"
    echo "║  Just select and go!                           ║"
    echo "╚════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Dapetin list VM yang ada
get_vms() {
    find "$VM_DIR" -maxdepth 1 -name "*.conf" | while read f; do
        basename "$f" .conf
    done | sort
}

# Cek apakah VM running
is_running() {
    local vm="$1"
    pgrep -f "qemu.*$vm" >/dev/null
}

# Baca config VM
load_config() {
    local vm="$1"
    local cfg="$VM_DIR/$vm.conf"
    
    [ ! -f "$cfg" ] && return 1
    
    # Reset variables
    unset name os img mem cpu port disk user pass gui created
    
    # Baca file config
    while IFS='=' read -r key val; do
        case "$key" in
            "name") name="$val" ;;
            "os") os="$val" ;;
            "img") img="$val" ;;
            "mem") mem="$val" ;;
            "cpu") cpu="$val" ;;
            "port") port="$val" ;;
            "disk") disk="$val" ;;
            "user") user="$val" ;;
            "pass") pass="$val" ;;
            "gui") gui="$val" ;;
            "created") created="$val" ;;
        esac
    done < "$cfg"
    
    # Set default values kalo kosong
    : ${mem:=2048}
    : ${cpu:=2}
    : ${port:=2222}
    : ${user:=user}
    : ${gui:=false}
    
    return 0
}

# Simpan config VM
save_config() {
    local vm="$1"
    local cfg="$VM_DIR/$vm.conf"
    
    cat > "$cfg" <<EOF
name=$name
os=$os
img=$img
mem=$mem
cpu=$cpu
port=$port
disk=$disk
user=$user
pass=$pass
gui=$gui
created=$(date +"%Y-%m-%d %H:%M")
EOF
}

# Generate random password
gen_password() {
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-12
}

# Download image kalo perlu
download_img() {
    local url="$1"
    local out="$2"
    
    if [ -f "$out" ]; then
        echo -e "${BLUE}📦 Image udah ada, skip download${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}📥 Downloading image...${NC}"
    if wget -q --show-progress "$url" -O "$out.tmp"; then
        mv "$out.tmp" "$out"
        echo -e "${GREEN}✅ Download selesai${NC}"
        return 0
    else
        rm -f "$out.tmp"
        echo -e "${RED}❌ Download gagal${NC}"
        return 1
    fi
}

# Create VM baru
create_vm() {
    clear_screen
    echo -e "${CYAN}📋 Buat VM Baru${NC}"
    echo "================="
    
    # Pilih OS
    echo
    echo "Pilih OS:"
    echo "1) Ubuntu 22.04 LTS"
    echo "2) Ubuntu 24.04 LTS"
    echo "3) Debian 12"
    echo "4) Fedora 40"
    echo "5) CentOS Stream 9"
    echo "6) Custom (URL sendiri)"
    echo
    read -p "Pilihan [1-6]: " os_choice
    
    case $os_choice in
        1) os="ubuntu22"; img_url="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img" ;;
        2) os="ubuntu24"; img_url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" ;;
        3) os="debian12"; img_url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2" ;;
        4) os="fedora40"; img_url="https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2" ;;
        5) os="centos9"; img_url="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2" ;;
        6) 
            echo
            read -p "Masukkan URL image: " img_url
            os="custom"
            ;;
        *) 
            echo -e "${RED}Pilihan salah!${NC}"
            return
            ;;
    esac
    
    # Nama VM
    echo
    while true; do
        read -p "Nama VM (contoh: webserver): " name
        validate "name" "$name" && break
        echo -e "${RED}Nama harus 3-20 karakter, huruf kecil, angka, - atau _${NC}"
    done
    
    # Cek kalo udah ada
    if [ -f "$VM_DIR/$name.conf" ]; then
        echo -e "${RED}VM $name udah ada!${NC}"
        return
    fi
    
    # Username
    echo
    read -p "Username [default: user]: " input_user
    user=${input_user:-user}
    
    # Password
    echo
    echo "Password:"
    echo "1) Auto-generate"
    echo "2) Input manual"
    read -p "Pilih [1-2]: " pass_choice
    
    if [ "$pass_choice" = "1" ]; then
        pass=$(gen_password)
        echo -e "${GREEN}Password: $pass${NC}"
    else
        while true; do
            read -s -p "Password: " pass
            echo
            read -s -p "Ulangi password: " pass2
            echo
            [ "$pass" = "$pass2" ] && [ ${#pass} -ge 6 ] && break
            echo -e "${RED}Password tidak cocok atau terlalu pendek (min 6 karakter)${NC}"
        done
    fi
    
    # RAM
    echo
    read -p "RAM (MB) [default: 2048]: " input_mem
    mem=${input_mem:-2048}
    while ! validate "number" "$mem"; do
        read -p "Masukkan angka valid: " mem
    done
    
    # CPU
    read -p "CPU cores [default: 2]: " input_cpu
    cpu=${input_cpu:-2}
    while ! validate "number" "$cpu"; do
        read -p "Masukkan angka valid: " cpu
    done
    
    # Disk size
    read -p "Ukuran disk (contoh: 20G) [default: 20G]: " input_disk
    disk=${input_disk:-20G}
    while ! validate "size" "$disk"; do
        read -p "Format harus 20G atau 512M: " disk
    done
    
    # SSH port
    default_port=2222
    while true; do
        read -p "SSH port [default: $default_port]: " input_port
        port=${input_port:-$default_port}
        if validate "port" "$port"; then
            # Cek port udah dipake apa belom
            used=0
            for vm in $(get_vms); do
                load_config "$vm"
                [ "$port" = "$port" ] && used=1 && break
            done
            [ $used -eq 0 ] && break
            echo -e "${RED}Port $port udah dipake VM lain${NC}"
        else
            echo -e "${RED}Port harus antara 1024-65535${NC}"
        fi
    done
    
    # GUI mode
    echo
    read -p "Mode GUI? (y/n) [default: n]: " gui_input
    gui="false"
    [[ "$gui_input" =~ ^[Yy]$ ]] && gui="true"
    
    # Setup file paths
    base_img="$VM_DIR/base-$(basename "$img_url")"
    img="$VM_DIR/$name.qcow2"
    
    echo
    echo -e "${YELLOW}Menyiapkan VM...${NC}"
    
    # Download base image
    if ! download_img "$img_url" "$base_img"; then
        echo -e "${RED}Gagal download image${NC}"
        return
    fi
    
    # Create disk image
    echo -e "${BLUE}💾 Membuat disk image...${NC}"
    if ! qemu-img create -f qcow2 -b "$base_img" -F qcow2 "$img" "$disk" >/dev/null 2>&1; then
        # Fallback kalo backing gagal
        cp "$base_img" "$img"
        qemu-img resize "$img" "$disk" >/dev/null 2>&1
    fi
    
    # Save config
    save_config "$name"
    
    echo
    echo -e "${GREEN}✅ VM $name berhasil dibuat!${NC}"
    echo
    echo "Info login:"
    echo "  Username: $user"
    echo "  Password: $pass"
    echo "  SSH Port: $port"
    echo
}

# Start VM
start_vm() {
    local vm="$1"
    
    load_config "$vm" || {
        echo -e "${RED}Gagal load config $vm${NC}"
        return
    }
    
    if is_running "$vm"; then
        echo -e "${YELLOW}VM $vm udah running${NC}"
        return
    fi
    
    echo -e "${BLUE}▶️  Menjalankan $vm...${NC}"
    
    # Cek file image
    if [ ! -f "$img" ]; then
        echo -e "${RED}File image $img gak ketemu${NC}"
        return
    fi
    
    # Cek KVM
    kvm_flag=""
    [ -w /dev/kvm ] && kvm_flag="-enable-kvm"
    
    # Build command
    cmd="qemu-system-x86_64 $kvm_flag"
    cmd="$cmd -name $vm"
    cmd="$cmd -m $mem"
    cmd="$cmd -smp $cpu"
    cmd="$cmd -drive file=$img,format=qcow2,if=virtio"
    cmd="$cmd -netdev user,id=net0,hostfwd=tcp::$port-:22"
    cmd="$cmd -device virtio-net-pci,netdev=net0"
    
    # GUI atau console
    if [ "$gui" = "true" ]; then
        cmd="$cmd -vga virtio -display gtk"
    else
        cmd="$cmd -nographic"
    fi
    
    echo -e "${GREEN}✅ VM $vm started${NC}"
    echo "SSH: ssh -p $port $user@localhost"
    
    # Run
    if [ "$gui" = "true" ]; then
        # Background kalo pake GUI
        eval "$cmd" &
        echo $! > "$VM_DIR/$vm.pid"
    else
        # Foreground kalo console
        eval "$cmd"
    fi
}

# Stop VM
stop_vm() {
    local vm="$1"
    
    if ! is_running "$vm"; then
        echo -e "${YELLOW}VM $vm gak running${NC}"
        return
    fi
    
    echo -e "${BLUE}⏹️  Stopping $vm...${NC}"
    
    # Coba pake PID
    if [ -f "$VM_DIR/$vm.pid" ]; then
        pid=$(cat "$VM_DIR/$vm.pid")
        kill $pid 2>/dev/null
        rm -f "$VM_DIR/$vm.pid"
    fi
    
    # Force kill kalo masih ada
    sleep 2
    if is_running "$vm"; then
        pkill -f "qemu.*$vm"
    fi
    
    echo -e "${GREEN}✅ VM $vm stopped${NC}"
}

# Show VM info
show_info() {
    local vm="$1"
    
    load_config "$vm" || {
        echo -e "${RED}VM $vm gak ditemukan${NC}"
        return
    }
    
    running="No"
    is_running "$vm" && running="Yes"
    
    echo
    echo "╔════════════════════════════════════╗"
    echo "║ VM: $vm"
    echo "╠════════════════════════════════════╣"
    printf "║ %-15s : %s\n" "OS" "$os"
    printf "║ %-15s : %s\n" "Status" "$running"
    printf "║ %-15s : %s\n" "RAM" "$mem MB"
    printf "║ %-15s : %s\n" "CPU" "$cpu core(s)"
    printf "║ %-15s : %s\n" "Disk" "$disk"
    printf "║ %-15s : %s\n" "SSH Port" "$port"
    printf "║ %-15s : %s\n" "Username" "$user"
    printf "║ %-15s : %s\n" "Password" "$pass"
    printf "║ %-15s : %s\n" "Created" "$created"
    echo "╚════════════════════════════════════╝"
    echo
}

# Delete VM
delete_vm() {
    local vm="$1"
    
    if is_running "$vm"; then
        echo -e "${YELLOW}VM $vm masih running, stop dulu${NC}"
        return
    fi
    
    echo -e "${RED}⚠️  Hapus VM $vm? (data akan hilang)${NC}"
    read -p "Ketik 'DELETE' untuk konfirmasi: " confirm
    [ "$confirm" != "DELETE" ] && return
    
    # Hapus file
    rm -f "$VM_DIR/$vm.conf" "$VM_DIR/$vm.qcow2" "$VM_DIR/$vm.pid" 2>/dev/null
    
    echo -e "${GREEN}✅ VM $vm dihapus${NC}"
}

# Edit VM config
edit_vm() {
    local vm="$1"
    
    if is_running "$vm"; then
        echo -e "${YELLOW}VM $vm masih running, stop dulu${NC}"
        return
    fi
    
    load_config "$vm" || return
    
    echo
    echo "Edit VM $vm:"
    echo "1) RAM: $mem MB"
    echo "2) CPU: $cpu core(s)"
    echo "3) SSH Port: $port"
    echo "4) GUI Mode: $gui"
    echo "5) Password"
    echo "0) Selesai"
    echo
    
    read -p "Pilih [0-5]: " choice
    
    case $choice in
        1)
            read -p "RAM baru (MB): " new_mem
            validate "number" "$new_mem" && mem=$new_mem
            ;;
        2)
            read -p "CPU baru: " new_cpu
            validate "number" "$new_cpu" && cpu=$new_cpu
            ;;
        3)
            read -p "SSH port baru: " new_port
            validate "port" "$new_port" && port=$new_port
            ;;
        4)
            [ "$gui" = "true" ] && gui="false" || gui="true"
            ;;
        5)
            read -s -p "Password baru: " pass1
            echo
            read -s -p "Ulangi: " pass2
            echo
            [ "$pass1" = "$pass2" ] && [ ${#pass1} -ge 6 ] && pass="$pass1"
            ;;
        0) return ;;
        *) echo -e "${RED}Pilihan salah${NC}" ;;
    esac
    
    save_config "$vm"
    echo -e "${GREEN}✅ Config updated${NC}"
}

# Resize disk
resize_disk() {
    local vm="$1"
    
    if is_running "$vm"; then
        echo -e "${YELLOW}VM $vm masih running${NC}"
        return
    fi
    
    load_config "$vm" || return
    
    echo "Ukuran sekarang: $disk"
    read -p "Ukuran baru (contoh: 50G): " new_disk
    
    if validate "size" "$new_disk"; then
        if qemu-img resize "$img" "$new_disk" >/dev/null 2>&1; then
            disk="$new_disk"
            save_config "$vm"
            echo -e "${GREEN}✅ Disk resized${NC}"
        else
            echo -e "${RED}Gagal resize${NC}"
        fi
    fi
}

# ==============================================
# MAIN PROGRAM
# ==============================================

# Check dependencies dulu
check_deps

# Main loop
while true; do
    show_header
    
    # List VM yang ada
    vms=($(get_vms))
    
    echo -e "${CYAN}📋 Daftar VM:${NC}"
    if [ ${#vms[@]} -eq 0 ]; then
        echo "  (belum ada VM)"
    else
        i=1
        for vm in "${vms[@]}"; do
            if is_running "$vm"; then
                status="${GREEN}[RUNNING]${NC}"
            else
                status="${RED}[STOPPED]${NC}"
            fi
            printf "  %2d) %-20s %s\n" $i "$vm" "$status"
            ((i++))
        done
    fi
    
    echo
    echo "Menu:"
    echo "  a) Buat VM baru"
    if [ ${#vms[@]} -gt 0 ]; then
        echo "  b) Start VM"
        echo "  c) Stop VM"
        echo "  d) Info VM"
        echo "  e) Edit VM"
        echo "  f) Hapus VM"
        echo "  g) Resize disk"
    fi
    echo "  x) Keluar"
    echo
    
    read -p "Pilih menu: " menu
    
    case $menu in
        a|A)
            create_vm
            ;;
        b|B)
            if [ ${#vms[@]} -gt 0 ]; then
                read -p "Pilih nomor VM: " num
                if [ "$num" -ge 1 ] && [ "$num" -le ${#vms[@]} ]; then
                    start_vm "${vms[$((num-1))]}"
                fi
            fi
            ;;
        c|C)
            if [ ${#vms[@]} -gt 0 ]; then
                read -p "Pilih nomor VM: " num
                if [ "$num" -ge 1 ] && [ "$num" -le ${#vms[@]} ]; then
                    stop_vm "${vms[$((num-1))]}"
                fi
            fi
            ;;
        d|D)
            if [ ${#vms[@]} -gt 0 ]; then
                read -p "Pilih nomor VM: " num
                if [ "$num" -ge 1 ] && [ "$num" -le ${#vms[@]} ]; then
                    show_info "${vms[$((num-1))]}"
                fi
            fi
            ;;
        e|E)
            if [ ${#vms[@]} -gt 0 ]; then
                read -p "Pilih nomor VM: " num
                if [ "$num" -ge 1 ] && [ "$num" -le ${#vms[@]} ]; then
                    edit_vm "${vms[$((num-1))]}"
                fi
            fi
            ;;
        f|F)
            if [ ${#vms[@]} -gt 0 ]; then
                read -p "Pilih nomor VM: " num
                if [ "$num" -ge 1 ] && [ "$num" -le ${#vms[@]} ]; then
                    delete_vm "${vms[$((num-1))]}"
                fi
            fi
            ;;
        g|G)
            if [ ${#vms[@]} -gt 0 ]; then
                read -p "Pilih nomor VM: " num
                if [ "$num" -ge 1 ] && [ "$num" -le ${#vms[@]} ]; then
                    resize_disk "${vms[$((num-1))]}"
                fi
            fi
            ;;
        x|X)
            echo -e "${GREEN}Bye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Menu salah!${NC}"
            ;;
    esac
    
    echo
    read -p "Tekan Enter untuk lanjut..."
done

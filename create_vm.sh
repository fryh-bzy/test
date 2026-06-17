#!/bin/bash
#
# 创建 trunk VM 脚本（含创建前后状态检查，幂等可重复执行）
# 用法: ./create_vm.sh <vm_id>   vm_id 范围: 1-99（会自动补零为两位，如 01、15、99）
#

set -uo pipefail

# ----------------------------- 参数检查 -----------------------------
vm_id_raw="${1:-}"

if [ -z "$vm_id_raw" ]; then
  echo "必须输入 vm_id，范围 1-99"
  exit 1
fi

if ! [[ "$vm_id_raw" =~ ^[0-9]{1,2}$ ]] || [ "$vm_id_raw" -lt 1 ] || [ "$vm_id_raw" -gt 99 ]; then
  echo "vm_id 格式错误，必须是 1-99 之间的数字，当前输入: $vm_id_raw"
  exit 1
fi

# 统一补零为两位，例如 1 -> 01，9 -> 09，15 -> 15
vm_id=$(printf "%02d" "$vm_id_raw")

vm_name="vm-${vm_id}"
mac_address="fa:16:3e:00:01:${vm_id}"
trunk_ip_address="192.168.3.1${vm_id}"
vlan1_ip_address="192.168.2.1${vm_id}"
vlan1_vip_address="192.168.2.2${vm_id}"
vlan4001_ip_address="10.30.1.1${vm_id}"

echo "vm_name: $vm_name"
echo "mac_address: $mac_address"
echo "trunk_ip_address: $trunk_ip_address"
echo "vlan1_ip_address: $vlan1_ip_address"
echo "vlan1_vip_address: $vlan1_vip_address"
echo "vlan4001_ip_address: $vlan4001_ip_address"
echo "----------------------------------------"

# ----------------------------- 日志函数 -----------------------------
log_info()  { echo "[INFO]  $*"; }
log_ok()    { echo "[OK]    $*"; }
log_skip()  { echo "[SKIP]  $*"; }
log_wait()  { echo "[WAIT]  $*"; }
log_error() { echo "[ERROR] $*" >&2; }

# ----------------------------- volume -----------------------------
volume_exists() {
  openstack volume show "$1" >/dev/null 2>&1
}

wait_volume_available() {
  local name="$1" status retries=30 i
  for ((i = 1; i <= retries; i++)); do
    status=$(openstack volume show "$name" -f value -c status 2>/dev/null)
    case "$status" in
      available | in-use)
        log_ok "volume $name 状态: $status"
        return 0
        ;;
      error*)
        log_error "volume $name 创建失败，状态: $status"
        exit 1
        ;;
    esac
    log_wait "volume $name 状态: ${status:-未知} ($i/$retries)"
    sleep 2
  done
  log_error "volume $name 等待超时，仍未 available"
  exit 1
}

create_volume_if_not_exists() {
  local name="$1"
  shift
  if volume_exists "$name"; then
    log_skip "volume $name 已存在，跳过创建"
  else
    log_info "创建 volume $name"
    if ! openstack volume create "$@" "$name"; then
      log_error "volume $name 创建命令执行失败"
      exit 1
    fi
  fi
  wait_volume_available "$name"
}

# ----------------------------- port -----------------------------
port_exists() {
  openstack port show "$1" >/dev/null 2>&1
}

create_port_if_not_exists() {
  local name="$1"
  shift
  if port_exists "$name"; then
    log_skip "port $name 已存在，跳过创建"
  else
    log_info "创建 port $name"
    if ! openstack port create "$@" "$name"; then
      log_error "port $name 创建命令执行失败"
      exit 1
    fi
  fi
  if port_exists "$name"; then
    log_ok "port $name 确认创建成功"
  else
    log_error "port $name 创建后校验失败，未找到该端口"
    exit 1
  fi
}

# ----------------------------- trunk / subport -----------------------------
trunk_exists() {
  openstack network trunk show "$1" >/dev/null 2>&1
}

create_trunk_if_not_exists() {
  local trunk_name="$1" parent_port="$2"
  if trunk_exists "$trunk_name"; then
    log_skip "trunk $trunk_name 已存在，跳过创建"
  else
    log_info "创建 trunk $trunk_name (parent-port: $parent_port)"
    if ! openstack network trunk create --parent-port "$parent_port" "$trunk_name"; then
      log_error "trunk $trunk_name 创建失败"
      exit 1
    fi
  fi
  if trunk_exists "$trunk_name"; then
    log_ok "trunk $trunk_name 确认创建成功"
  else
    log_error "trunk $trunk_name 创建后校验失败"
    exit 1
  fi
}

subport_attached() {
  local port_name="$1" device_owner
  device_owner=$(openstack port show "$port_name" -f value -c device_owner 2>/dev/null)
  [ "$device_owner" = "trunk:subport" ]
}

add_subport_if_needed() {
  local trunk_name="$1" port_name="$2" segmentation_id="$3"
  if subport_attached "$port_name"; then
    log_skip "subport $port_name 已挂载到某个 trunk，跳过添加"
  else
    log_info "向 trunk $trunk_name 添加 subport $port_name (vlan $segmentation_id)"
    if ! openstack network trunk set \
      --subport port="$port_name",segmentation-type=vlan,segmentation-id="$segmentation_id" \
      "$trunk_name"; then
      log_error "添加 subport $port_name 到 trunk $trunk_name 失败"
      exit 1
    fi
  fi
  if subport_attached "$port_name"; then
    log_ok "subport $port_name 确认已挂载"
  else
    log_error "subport $port_name 挂载后校验失败"
    exit 1
  fi
}

# ----------------------------- allowed-address-pair -----------------------------
add_allowed_address_pair_if_needed() {
  local port_name="$1" ip_address="$2" existing
  existing=$(openstack port show "$port_name" -f value -c allowed_address_pairs 2>/dev/null)
  if echo "$existing" | grep -q "$ip_address"; then
    log_skip "port $port_name 已包含 allowed-address-pair $ip_address，跳过"
  else
    log_info "为 port $port_name 添加 allowed-address-pair $ip_address"
    if ! openstack port set --allowed-address ip-address="$ip_address" "$port_name"; then
      log_error "添加 allowed-address-pair $ip_address 到 port $port_name 失败"
      exit 1
    fi
  fi
}

# ----------------------------- server -----------------------------
server_exists() {
  openstack server show "$1" >/dev/null 2>&1
}

wait_server_active() {
  local name="$1" status retries=60 i
  for ((i = 1; i <= retries; i++)); do
    status=$(openstack server show "$name" -f value -c status 2>/dev/null)
    case "$status" in
      ACTIVE)
        log_ok "server $name 状态: ACTIVE"
        return 0
        ;;
      ERROR)
        log_error "server $name 创建失败，状态: ERROR"
        exit 1
        ;;
    esac
    log_wait "server $name 状态: ${status:-未知} ($i/$retries)"
    sleep 5
  done
  log_error "server $name 等待超时，仍未 ACTIVE"
  exit 1
}

create_server_if_not_exists() {
  local name="$1"
  shift
  if server_exists "$name"; then
    log_skip "server $name 已存在，跳过创建"
  else
    log_info "创建 server $name"
    if ! openstack server create "$@" "$name"; then
      log_error "server $name 创建命令执行失败"
      exit 1
    fi
  fi
  wait_server_active "$name"
}

volume_attached_to_server() {
  local server_name="$1" volume_name="$2" volume_id
  volume_id=$(openstack volume show "$volume_name" -f value -c id 2>/dev/null)
  [ -n "$volume_id" ] && openstack server show "$server_name" -f value -c volumes_attached 2>/dev/null | grep -q "$volume_id"
}

add_volume_if_needed() {
  local server_name="$1" volume_name="$2"
  if volume_attached_to_server "$server_name" "$volume_name"; then
    log_skip "volume $volume_name 已挂载到 $server_name，跳过"
  else
    log_info "为 server $server_name 挂载 volume $volume_name"
    if ! openstack server add volume "$server_name" "$volume_name"; then
      log_error "挂载 volume $volume_name 到 server $server_name 失败"
      exit 1
    fi
  fi
}

port_attached_to_server() {
  local server_name="$1" port_name="$2" server_id port_device_id
  server_id=$(openstack server show "$server_name" -f value -c id 2>/dev/null)
  port_device_id=$(openstack port show "$port_name" -f value -c device_id 2>/dev/null)
  [ -n "$server_id" ] && [ "$server_id" = "$port_device_id" ]
}

add_port_if_needed() {
  local server_name="$1" port_name="$2"
  if port_attached_to_server "$server_name" "$port_name"; then
    log_skip "port $port_name 已挂载到 $server_name，跳过"
  else
    log_info "为 server $server_name 挂载 port $port_name"
    if ! openstack server add port "$server_name" "$port_name"; then
      log_error "挂载 port $port_name 到 server $server_name 失败"
      exit 1
    fi
  fi
}

# ===================== 1. 创建系统盘/数据盘 volume =====================

create_volume_if_not_exists "sys-volume-${vm_name}" \
  --image image-vds \
  --size 100

create_volume_if_not_exists "volume-${vm_name}" \
  --type ssd_4024f33fd90a4db6a43f8501c3078a2e \
  --availability-zone nova \
  --size 50

# ===================== 2. 创建 trunk-port / vlan1-port / vlan4001-port =====================

create_port_if_not_exists "${vm_name}-trunk-port" \
  --network flat-net \
  --fixed-ip ip-address="${trunk_ip_address}",subnet=flat-subnet \
  --mac-address "${mac_address}"

create_port_if_not_exists "${vm_name}-vlan1-port" \
  --network vlan1-net \
  --fixed-ip ip-address="${vlan1_ip_address}",subnet=vlan1-subnet \
  --mac-address "${mac_address}"

create_port_if_not_exists "${vm_name}-vlan4001-port" \
  --network vlan4001-net \
  --fixed-ip ip-address="${vlan4001_ip_address}",subnet=vlan4001-subnet \
  --mac-address "${mac_address}"

# ===================== 3. 创建 trunk 并挂载 subport =====================

create_trunk_if_not_exists "${vm_name}-trunk" "${vm_name}-trunk-port"

add_subport_if_needed "${vm_name}-trunk" "${vm_name}-vlan1-port" 1
add_subport_if_needed "${vm_name}-trunk" "${vm_name}-vlan4001-port" 4001

# ===================== 4. 配置 allowed-address-pairs =====================

add_allowed_address_pair_if_needed "${vm_name}-vlan1-port" "${vlan1_vip_address}"
add_allowed_address_pair_if_needed "${vm_name}-vlan1-port" "192.168.2.240"

# ===================== 5. 创建虚拟机并挂载第二块数据盘 =====================

create_server_if_not_exists "${vm_name}" \
  --flavor custom.8c32g \
  --volume "sys-volume-${vm_name}" \
  --port "${vm_name}-trunk-port" \
  --security-group default_white_init

add_volume_if_needed "${vm_name}" "volume-${vm_name}"

# ===================== 6. 创建额外的 flat-net 端口并挂载 =====================

create_port_if_not_exists "port-${vm_name}-1" \
  --network flat-net \
  --no-fixed-ip \
  --security-group default_white_init

create_port_if_not_exists "port-${vm_name}-2" \
  --network flat-net \
  --no-fixed-ip \
  --security-group default_white_init

add_port_if_needed "${vm_name}" "port-${vm_name}-1"
add_port_if_needed "${vm_name}" "port-${vm_name}-2"

# ===================== 7. 最终状态汇总 =====================

echo "----------------------------------------"
echo "最终状态检查:"
echo "server 状态: $(openstack server show "${vm_name}" -f value -c status 2>/dev/null)"
echo "sys-volume 状态: $(openstack volume show "sys-volume-${vm_name}" -f value -c status 2>/dev/null)"
echo "volume 状态: $(openstack volume show "volume-${vm_name}" -f value -c status 2>/dev/null)"
echo "全部步骤完成: $vm_name"

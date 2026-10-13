#!/usr/bin/env bash
# code-master:title win-box · Looking Glass 宿主侧（lib/lg.sh）
#
# 契约：docs/interfaces/04-lib-api.md ／ 链路：docs/calltrees/04-lg-chain.md
#
# 三件事：
#   1. KVMFR 内核模块（把帧缓冲导出成 DMA-BUF，宿主 GPU 零拷贝导入）
#   2. 客户端构建与启动
#   3. 让 QEMU 有权限打开 /dev/kvmfr0 —— **两层都要放开**，缺一层就起不来：
#        AppArmor：/etc/apparmor.d/local/abstractions/libvirt-qemu 里没写 /dev/kvmfr0
#                  → open 被拒（EACCES / "Permission denied"）
#        cgroup v2 设备白名单（eBPF）：qemu.conf 的 cgroup_device_acl 没登记
#                  → 内核返回 EPERM / "Operation not permitted"
#      （判据就是这两个 errno：EACCES 找 AppArmor，EPERM 找 cgroup）

[[ -n ${WB_LIB_LG_LOADED:-} ]] && return 0
WB_LIB_LG_LOADED=1

WB_LIB_DIR=${WB_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./log.sh
[[ -n ${WB_LIB_LOG_LOADED:-} ]] || source "$WB_LIB_DIR/log.sh"
# shellcheck source=./sys.sh
[[ -n ${WB_LIB_SYS_LOADED:-} ]] || source "$WB_LIB_DIR/sys.sh"
# shellcheck source=./conf.sh
[[ -n ${WB_LIB_CONF_LOADED:-} ]] || source "$WB_LIB_DIR/conf.sh"
# shellcheck source=./guest.sh
[[ -n ${WB_LIB_GUEST_LOADED:-} ]] || source "$WB_LIB_DIR/guest.sh"

KVMFR_DEV=/dev/kvmfr0

# 构建依赖（分成两组，便于报错时说清"缺哪一组"）
WB_LG_RUNTIME_DEPS=(
  cmake pkg-config make build-essential dkms
  libgmp-dev libspice-protocol-dev nettle-dev
  libdw-dev libunwind-dev libxss-dev libxpresent-dev
  libpipewire-0.3-dev libpulse-dev libsamplerate0-dev
  libusbredirparser-dev libfuse3-dev
)
# 官方依赖清单没写、但 CMake 配置阶段真的要的模块（踩过）
WB_LG_PKGCONFIG_DEPS=(fontconfig samplerate libpipewire-0.3)

wb_lg_src_dir() {
  local d
  d=$(wb_conf_get_default WB_LG_SRC 'third_party/LookingGlass')
  [[ $d == /* ]] || d="$WB_ROOT/$d"
  printf '%s\n' "$d"
}

wb_lg_client_bin() {
  wb_conf_get_default WB_LG_CLIENT "$HOME/.local/bin/looking-glass-client"
}

# ── KVMFR ─────────────────────────────────────────────────────────────────

# stdout: ok | missing | notchardev
wb_kvmfr_state() {
  if [[ ! -e $KVMFR_DEV ]]; then printf 'missing\n'; return 0; fi
  if [[ ! -c $KVMFR_DEV ]]; then printf 'notchardev\n'; return 0; fi
  printf 'ok\n'
}

# 检查设备可用；不可用 → 码 3（带具体修法）
wb_kvmfr_check() {
  case $(wb_kvmfr_state) in
    ok) : ;;
    missing)
      wb_fail 3 lg "$KVMFR_DEV 不存在：kvmfr 模块未加载（sudo winbox lg-prepare）" \
        "docs/calltrees/04-lg-chain.md" ;;
    notchardev)
      wb_fail 3 lg "$KVMFR_DEV 不是字符设备（曾被 QEMU 创造成普通文件）：关机后 rm -f $KVMFR_DEV && modprobe kvmfr" \
        "docs/zh/07-踩坑大全.md" ;;
  esac
  [[ -r /sys/module/kvmfr/parameters/static_size_mb ]] || return 0
  return 0
}

# 模块报告的共享内存大小（MB）
#   1) sysfs 参数（有些版本的 kvmfr 用 module_param_array(..., 0000) 声明，
#      权限为 0000 → sysfs 里根本不会出现该文件，读不到很正常）
#   2) /etc/modprobe.d/kvmfr.conf（这是**配置值**，模块未重载时可能不是当前生效值）
#   读不到就输出空，由调用方决定是警告还是失败。
wb_kvmfr_size_mb() {
  local f=/sys/module/kvmfr/parameters/static_size_mb
  if [[ -r $f ]]; then cat "$f"; return 0; fi
  local conf=/etc/modprobe.d/kvmfr.conf
  if [[ -r $conf ]]; then
    awk '/^[[:space:]]*options[[:space:]]+kvmfr/ {
           for (i = 1; i <= NF; i++) if ($i ~ /^static_size_mb=/) { sub(/^static_size_mb=/, "", $i); print $i }
         }' "$conf" | head -1
  fi
  return 0
}

# 安装/重装 KVMFR 模块（DKMS）+ 模块参数 + 开机加载 + udev 权限；幂等
wb_kvmfr_install() {
  local size=${1:-}
  wb_require_root
  wb_require_cmd dkms make modprobe
  size=${size:-$(wb_conf_get_default WB_SHM_SIZE_MB 128)}

  local src
  src=$(wb_lg_src_dir)
  [[ -f $src/module/dkms.conf ]] || wb_fail 3 lg \
    "找不到 KVMFR 模块源码: $src/module（git submodule update --init --recursive）" \
    "docs/calltrees/04-lg-chain.md"

  # ★ 已知坑：QEMU 若先于模块启动，会把 /dev/kvmfr0 创造成**普通文件**，
  #   之后模块再也建不出字符设备（modprobe 会静默失败）。
  if [[ -e $KVMFR_DEV && ! -c $KVMFR_DEV ]]; then
    wb_warn "$KVMFR_DEV 存在但不是字符设备（被 QEMU 创造成普通文件了）"
    local running
    running=$(virsh -c qemu:///system list --name 2>/dev/null | grep -c . || true)
    (( running == 0 )) || wb_fail 3 lg "有域在运行，先全部关机再修 $KVMFR_DEV" \
      "docs/calltrees/04-lg-chain.md"
    wb_run rm -f -- "$KVMFR_DEV"
  fi

  wb_log "  安装 DKMS 模块（源码: $src/module）"
  wb_run sh -c "cd '$src/module' && make clean >/dev/null 2>&1 || true; dkms install ." \
    || wb_fail 1 lg "dkms install 失败（内核头文件装了? 源码是干净的吗?）" "docs/zh/07-踩坑大全.md"

  wb_log '  写模块参数 / 开机加载 / 设备权限'
  wb_run mkdir -p /etc/modprobe.d /etc/modules-load.d /etc/udev/rules.d
  wb_write /etc/modprobe.d/kvmfr.conf "options kvmfr static_size_mb=$size"
  wb_write /etc/modules-load.d/kvmfr.conf 'kvmfr'
  wb_write /etc/udev/rules.d/70-kvmfr.rules \
    'SUBSYSTEM=="kvmfr", GROUP="kvm", MODE="0660", TAG+="uaccess"'

  if wb_is_dry_run; then
    wb_log "  [dry-run] udevadm control --reload-rules && modprobe kvmfr"
  else
    udevadm control --reload-rules 2>/dev/null || true
    modprobe kvmfr || wb_fail 1 lg "modprobe kvmfr 失败（dkms status 看看模块是否为本内核构建）" \
      "docs/zh/07-踩坑大全.md"
    sleep 1
  fi

  case $(wb_kvmfr_state) in
    ok) wb_ok "$KVMFR_DEV 就绪（$(ls -l "$KVMFR_DEV" | awk '{print $1, $3, $4}')，size=$(wb_kvmfr_size_mb)MB）" ;;
    *) wb_fail 1 lg "$KVMFR_DEV 仍未出现或类型不对（dmesg | grep kvmfr 看原因）" \
         "docs/zh/07-踩坑大全.md" ;;
  esac
}

# ── 客户端 ────────────────────────────────────────────────────────────────

wb_lg_deps_install() {
  wb_require_root
  wb_require_cmd apt-get dpkg
  export DEBIAN_FRONTEND=noninteractive
  local missing=() p
  for p in "${WB_LG_RUNTIME_DEPS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if (( ${#missing[@]} )); then
    wb_log "  安装缺失依赖: ${missing[*]}"
    wb_run apt-get install -y --no-install-recommends "${missing[@]}" \
      || wb_fail 1 lg "apt-get install 失败" "docs/zh/07-踩坑大全.md"
  else
    wb_ok '构建依赖齐备'
  fi
}

# 检查 CMake 真的要用的 pkg-config 模块（官方依赖清单漏了这几个）
wb_lg_build_check() {
  wb_require_cmd cmake pkg-config make
  local missing=() m
  for m in "${WB_LG_PKGCONFIG_DEPS[@]}"; do
    pkg-config --exists "$m" 2>/dev/null || missing+=("$m")
  done
  # 版本约束在 pkg-config 里不能当模块名写（'fuse3>=3.10' 会找不到），必须用 --atleast-version
  pkg-config --atleast-version=3.10 fuse3 2>/dev/null || missing+=("fuse3(>=3.10)")
  if (( ${#missing[@]} )); then
    wb_fail 3 lg "缺少 pkg-config 模块: ${missing[*]}（sudo winbox lg-prepare 会装）" \
      "docs/calltrees/04-lg-chain.md"
  fi
  return 0
}

# 构建并安装客户端到 $HOME/.local（不需要 root）
wb_lg_build() {
  local src=${1:-}
  src=${src:-$(wb_lg_src_dir)}
  [[ -f $src/client/CMakeLists.txt ]] || wb_fail 3 lg \
    "找不到客户端源码: $src/client（submodule 初始化了吗？）" "docs/calltrees/04-lg-chain.md"
  wb_lg_build_check

  local build="$src/client/build" prefix="$HOME/.local"
  wb_log "  cmake 配置（源码 $src/client，prefix $prefix）"
  wb_run cmake -S "$src/client" -B "$build" -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_BUILD_TYPE=Release \
    || wb_fail 1 lg "cmake 配置失败（看上面报错）" "docs/zh/07-踩坑大全.md"
  wb_log '  编译'
  wb_run cmake --build "$build" -j "$(nproc)" \
    || wb_fail 1 lg "编译失败" "docs/zh/07-踩坑大全.md"
  wb_log '  安装'
  wb_run cmake --install "$build" \
    || wb_fail 1 lg "安装失败" "docs/zh/07-踩坑大全.md"

  if wb_is_dry_run; then
    wb_log "  [dry-run] 客户端 → $(wb_lg_client_bin)"
    return 0
  fi
  local bin
  bin=$(wb_lg_client_bin)
  [[ -x $bin ]] || bin="$HOME/.local/bin/looking-glass-client"
  [[ -x $bin ]] || wb_fail 1 lg "构建完成但找不到客户端二进制" "docs/zh/07-踩坑大全.md"
  wb_ok "客户端就绪: $bin"
  "$bin" --version 2>&1 | head -3 | sed 's/^/      /' || true
}

# 写客户端配置（默认 lgmp + DMA + 抓取模式）；已存在则不覆盖（除非 --force）
wb_lg_client_ini_write() {
  local force=${1:-}
  local cfg_dir="$HOME/.config/looking-glass"
  local cfg="$cfg_dir/client.ini"
  if [[ -f $cfg && $force != --force ]]; then
    wb_log "  已存在配置，不覆盖: $cfg（要重置加 --force）"
    return 0
  fi
  if wb_is_dry_run; then
    wb_log "  [dry-run] 写客户端配置 $cfg"
    return 0
  fi
  wb_run mkdir -p -- "$cfg_dir"
  cat > "$cfg" <<'INI'
; Looking Glass 客户端配置（由 winbox lg 生成；已存在则不覆盖）

[app]
; 主传输：LGMP（共享内存直连）；SPICE 仅作兜底/剪贴板
transport=lgmp

[lgmp]
; ★ 必须写具体路径：留空会让 lgmp_deviceValidator 段错误
shmDevice=/dev/kvmfr0
; 允许把帧直接导入宿主 GPU（KVMFR 的 DMA-BUF 零拷贝）；不支持时自动回退
allowDMA=yes

[win]
; autoResize 与 setGuestRes 互斥（LG 不允许同时开）：让窗口决定客机分辨率
autoResize=no
setGuestRes=yes
keepAspect=yes
size=1600x900

[input]
; ★ 多显示器下必须用抓取模式：绝对定位走 SetCursorPos(桌面坐标)，
;   有第二块屏时指针会跳到别的屏上去
captureOnFocus=yes
grabKeyboard=yes
mouseRedraw=no
INI
  wb_ok "已生成客户端配置: $cfg"
}

wb_lg_run() {
  local bin
  bin=$(wb_lg_client_bin)
  [[ -x $bin ]] || wb_fail 3 lg "客户端未构建: $bin（先 sudo winbox lg-prepare）" \
    "docs/calltrees/04-lg-chain.md"
  case $(wb_kvmfr_state) in
    missing) wb_warn "$KVMFR_DEV 不存在——客户端会退回探测，若连不上请跑 winbox lg-prepare" ;;
    notchardev) wb_warn "$KVMFR_DEV 不是字符设备——LGMP 会失败（见 winbox lg-prepare）" ;;
  esac
  [[ -f $HOME/.config/looking-glass/client.ini ]] || wb_lg_client_ini_write
  exec "$bin" "$@"
}

# ── 权限双闸 ──────────────────────────────────────────────────────────────

# 在 qemu.conf 的 cgroup_device_acl 里确保有 /dev/kvmfr0（保留用户已有的其它条目）
# 渲染到 stdout —— 与写盘分开，这样这段“改配置”的逻辑可以用样本文件离线测
wb_lg__qemu_conf_acl_render() {
  local conf=${1:-}
  wb_require_file "$conf"
  awk -v want="/dev/kvmfr0" '
    BEGIN { in_block = 0; found = 0; n = 0 }
    function add(e,   i) {
      if (e == "") return
      for (i = 1; i <= n; i++) if (entries[i] == e) return
      entries[++n] = e
    }
    function emit(   i) {
      print "cgroup_device_acl = ["
      for (i = 1; i <= n; i++) printf "    \"%s\"%s\n", entries[i], (i == n ? "" : ",")
      print "    ]"
    }
    function harvest(line,   s) {
      while (match(line, /"[^"]+"/)) { add(substr(line, RSTART + 1, RLENGTH - 2)); line = substr(line, RSTART + RLENGTH) }
    }
    {
      if (!found && $0 ~ /^[ \t]*#?[ \t]*cgroup_device_acl[ \t]*=/) {
        found = 1
        harvest($0)
        if (index($0, "]") > 0) { add(want); emit() } else { in_block = 1 }
        next
      }
      if (in_block) {
        harvest($0)
        if (index($0, "]") > 0) { in_block = 0; add(want); emit() }
        next
      }
      print
    }
    END {
      if (!found) {
        add("/dev/null"); add("/dev/full"); add("/dev/zero")
        add("/dev/random"); add("/dev/urandom")
        add("/dev/ptmx"); add("/dev/kvm"); add("/dev/userfaultfd")
        add("/dev/vhost-net"); add("/dev/net/tun")
        add(want)
        print ""
        print "# 由 winbox lg-shmem 追加：Looking Glass IVSHMEM（kvmfr）设备白名单"
        emit()
      }
    }
  ' "$conf"
}

wb_lg__qemu_conf_acl() {
  local conf=/etc/libvirt/qemu.conf tmp
  tmp=$(mktemp)
  wb_lg__qemu_conf_acl_render "$conf" > "$tmp" \
    || { rm -f -- "$tmp"; wb_fail 1 lg "重写 qemu.conf 的 cgroup_device_acl 失败" "docs/calltrees/04-lg-chain.md"; }
  wb_run cp -a -- "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
  wb_run install -m 644 -- "$tmp" "$conf"
  rm -f -- "$tmp"
}

# 两层闸门各自的状态：ok / missing / unknown（只读）
#   unknown = 无权限读取该文件（qemu.conf 是 600 root）——不能把"读不到"当成"没配"
#   stdout 形如: apparmor=ok cgroup=unknown
wb_lg_permissions_state() {
  local aa=/etc/apparmor.d/local/abstractions/libvirt-qemu
  local acl=/etc/libvirt/qemu.conf
  local a c

  if [[ ! -e $aa ]]; then a=missing
  elif [[ ! -r $aa ]]; then a=unknown
  elif grep -q '^/dev/kvmfr0' "$aa"; then a=ok
  else a=missing; fi

  if [[ ! -e $acl ]]; then c=missing
  elif [[ ! -r $acl ]]; then c=unknown
  elif wb_lg__acl_has_dev "$acl" /dev/kvmfr0; then c=ok
  else c=missing; fi

  printf 'apparmor=%s cgroup=%s\n' "$a" "$c"
}

# 在 qemu.conf 的 cgroup_device_acl 块里查一个设备（块感知：不用“行窗口”猜测）
wb_lg__acl_has_dev() {
  local conf=${1:-} dev=${2:-}
  [[ -r $conf ]] || return 1
  awk -v dev="$dev" '
    BEGIN { in_block = 0 }
    {
      if (!in_block && $0 ~ /^[ \t]*#?[ \t]*cgroup_device_acl[ \t]*=/) {
        if (index($0, "]") > 0) { if (index($0, "\"" dev "\"") > 0) found = 1; next }
        in_block = 1
        if (index($0, "\"" dev "\"") > 0) found = 1
        next
      }
      if (in_block) {
        if (index($0, "\"" dev "\"") > 0) found = 1
        if (index($0, "]") > 0) in_block = 0
        next
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$conf"
}

# 两层权限 + 重启 libvirtd；幂等
wb_lg_permissions_fix() {
  wb_require_root

  wb_step '1/3' 'AppArmor：放行 /dev/kvmfr0（否则 EACCES）'
  local aa=/etc/apparmor.d/local/abstractions/libvirt-qemu
  if wb_is_dry_run; then
    wb_log "  [dry-run] 向 $aa 追加 /dev/kvmfr0 rw,"
  elif [[ -f $aa ]] && grep -q '^/dev/kvmfr0' "$aa"; then
    wb_ok '已有规则'
  else
    wb_run mkdir -p -- "$(dirname -- "$aa")"
    if wb_write "$aa" "$(cat "$aa" 2>/dev/null || true)
# Looking Glass：QEMU 需要打开 kvmfr 字符设备作为 IVSHMEM 内存后端
/dev/kvmfr0 rw,"; then
      wb_ok "已追加规则: $aa"
    else
      wb_fail 1 lg "写 AppArmor 规则失败: $aa" "docs/calltrees/04-lg-chain.md"
    fi
  fi

  wb_step '2/3' 'cgroup v2 设备白名单：qemu.conf（否则 EPERM）'
  if wb_is_dry_run; then
    wb_log '  [dry-run] 在 /etc/libvirt/qemu.conf 的 cgroup_device_acl 里加入 /dev/kvmfr0'
  elif wb_lg__acl_has_dev /etc/libvirt/qemu.conf /dev/kvmfr0; then
    wb_ok '/dev/kvmfr0 已在白名单里'
  else
    wb_lg__qemu_conf_acl
    wb_ok '已更新 cgroup_device_acl'
  fi

  wb_step '3/3' '重启 libvirtd 让规则生效'
  local running
  running=$(virsh -c qemu:///system list --name 2>/dev/null | grep -c . || true)
  if (( running > 0 )); then
    wb_warn '有域在运行——libvirtd 未重启，权限在下次 libvirtd 重启后生效'
    wb_hint '先把虚拟机全部关机（winbox vm shutdown），再跑 winbox lg-shmem'
  else
    wb_run systemctl restart libvirtd
    wb_ok 'libvirtd 已重启'
  fi
}

# ── 客机侧：IDD 偏好 ──────────────────────────────────────────────────────

# 三个偏好各有其必要性（都是实测结论）：
#   ExclusiveMonitor=0  否则 IDD 会把其它显示器主动关掉（物理屏与 LG 不能共存）
#   ForceIndirectCopy=1 否则走 D3D12 直传路径会让 AMD 驱动 Device Removed（0x887A0007）
#   ForceFullDirectCopy=0  设为 1 会加重物理屏白方块
wb_idd_prefs_apply() {
  wb_guest_ready || wb_fail 3 lg \
    "没有可用的客机 SSH 通道（配置 WB_GUEST_USER/WB_GUEST_HOST/WB_GUEST_KEY，并装好服务端）" \
    "docs/zh/04-客机SSH直连通道.md"

  wb_log '  写入 IDD 偏好（注册表）'
  wb_guest_ps '$k="HKLM:\SOFTWARE\LookingGlass\IDD"; New-Item -Path $k -Force | Out-Null;
    Set-ItemProperty -Path $k -Name ExclusiveMonitor    -Value 0 -Type DWord;
    Set-ItemProperty -Path $k -Name ForceIndirectCopy   -Value 1 -Type DWord;
    Set-ItemProperty -Path $k -Name ForceFullDirectCopy -Value 0 -Type DWord;
    Get-ItemProperty $k | Select-Object ExclusiveMonitor,ForceIndirectCopy,ForceFullDirectCopy | Format-List'

  wb_log '  重载 IDD 驱动（画面会闪断几秒）'
  wb_guest_ps '$d=(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
      Where-Object { $_.InstanceId -like "ROOT\DISPLAY*" } | Select-Object -First 1).InstanceId;
    if (-not $d) { $d="ROOT\DISPLAY\0000" }
    try { Disable-PnpDevice -InstanceId $d -Confirm:$false -ErrorAction Stop; Start-Sleep 4;
          Enable-PnpDevice  -InstanceId $d -Confirm:$false -ErrorAction Stop; "reloaded: $d" }
    catch { "ERR: " + $_.Exception.Message }'
}

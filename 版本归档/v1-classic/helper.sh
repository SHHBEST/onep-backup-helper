#!/bin/bash
# ============================================================
# 1P备份助手 —— age 加解密后端
# 由 1P备份助手.app 或 快捷指令 调用，不面向人直接使用。
# ============================================================
set -uo pipefail
umask 077

# 关键：macOS 自带 bash 3.2 在 UTF-8 locale 下，会把 "$变量" 后面紧跟的
# 全角字符（如 "）"）误并入变量名，报 "unbound variable"。强制 C locale
# 让 bash 按字节处理，即可避开；中文文件名/错误信息不受影响（字节原样传递）。
export LC_ALL=C

RES_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 90
AGE="$RES_DIR/age"
AGEKEYGEN="$RES_DIR/age-keygen"

SUPPORT="${SUPPORT_DIR:-$HOME/Library/Application Support/1P备份}"
PUB="$SUPPORT/public.key"
PRIV="$SUPPORT/private.key"

fail() { echo "$2" >&2; exit "$1"; }

[ -x "$AGE" ] || fail 90 "内部错误：找不到 age 程序（${AGE}）"
[ -x "$AGEKEYGEN" ] || fail 91 "内部错误：找不到 age-keygen 程序（${AGEKEYGEN}）"

cmd="${1:-}"
[ -n "$cmd" ] || fail 1 "用法：helper.sh {encrypt|decrypt|keygen|public|status|selftest|verify} <文件>"

tmp=""
lock=""
cleanup() {
  [ -z "$tmp" ] || rm -rf "$tmp"
  [ -z "$lock" ] || rmdir "$lock" 2>/dev/null
  return 0
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

require_absent() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    fail 4 "目标已存在，没有覆盖：$1"
  fi
}

acquire_lock() {
  # App 和快捷指令共用目录锁，避免两个任务同时提交同一输出。
  mkdir "$1" 2>/dev/null || fail 22 "无法取得操作锁：$1。可能有任务正在处理，或目录不可写；若上次被强制退出，请确认无任务运行后删除此空锁目录。"
  lock="$1"
}

make_temp() {
  tmp="$(mktemp -d "$1/.1p-backup.XXXXXXXX")" || fail 21 "无法创建临时目录：$1"
}

publish() {
  require_absent "$2"
  /bin/mv -n "$1" "$2" || fail 21 "无法保存文件：$2"
  [ ! -e "$1" ] || fail 4 "目标已存在，没有覆盖：$2"
}

read_source() {
  src="${2:-}"
  [ -n "$src" ] || fail 2 "没有指定文件"
  case "$src" in /*) ;; *) src="$PWD/$src" ;; esac
  # GUI 的结果协议按行分隔，拒绝会截断返回路径的文件名。
  case "$src" in *$'\n'*|*$'\r'*) fail 24 "文件路径含换行符，请改名后重试" ;; esac
  [ -f "$src" ] || fail 2 "文件不存在：$src"
}

hash_file() {
  local result
  result="$(shasum -a 256 < "$1")" || fail 21 "无法计算 SHA256：$1"
  sum="${result%% *}"
  case "$sum" in ''|*[!0-9a-f]*) fail 21 "SHA256 计算结果异常" ;; esac
  [ "${#sum}" -eq 64 ] || fail 21 "SHA256 计算结果异常"
}

secure_private() {
  [ ! -L "$PRIV" ] || fail 23 "私钥不能是符号链接，请放入实际的 private.key 文件"
  [ -s "$PRIV" ] && [ -f "$PRIV" ] || fail 7 "本机没有有效私钥，请把私钥放到：$PRIV"
  chmod 600 "$PRIV" || fail 23 "无法收紧私钥权限：$PRIV"
}

ensure_support() {
  if [ ! -d "$SUPPORT" ]; then
    mkdir -p "$SUPPORT" || fail 92 "无法创建密钥目录：$SUPPORT"
  fi
  chmod 700 "$SUPPORT" || fail 92 "无法收紧密钥目录权限：$SUPPORT"
}

is_age_file() {
  local header
  [ -f "$1" ] || return 1
  # 只读固定长度，避免无换行的大文件被整个读入内存；兼容 age ASCII armor。
  header="$(head -c 36 < "$1" 2>/dev/null)" || return 1
  case "$header" in
    "age-encryption.org/v1"$'\n'*|"-----BEGIN AGE ENCRYPTED FILE-----"*) return 0 ;;
    *) return 1 ;;
  esac
}

case "$cmd" in

  # ---------- 加密：只需要公钥 ----------
  encrypt)
    read_source "$@"
    [ -s "$PUB" ] || fail 3 "尚未生成密钥，请先点「生成密钥」"
    [ -s "$src" ] || fail 11 "文件是空的，没有可加密的内容"

    # 防止把已经是密文的文件再加密一遍，产出 .age.age 的混乱文件
    is_age_file "$src" && fail 19 "这个文件已经是加密过的（age 格式），不需要再加密"

    recipient="$(tr -d '[:space:]' < "$PUB")" || fail 12 "无法读取公钥：$PUB"
    case "$recipient" in
      age1*) : ;;
      *) fail 12 "公钥文件内容异常：$PUB" ;;
    esac

    out="$src.age"
    require_absent "$out"
    require_absent "$out.sha256"
    acquire_lock "$out.1p-lock"
    require_absent "$out"
    require_absent "$out.sha256"
    make_temp "$(dirname "$out")"

    "$AGE" -r "$recipient" -o "$tmp/data" "$src" || fail 5 "加密失败"
    is_age_file "$tmp/data" || fail 6 "加密产物校验失败"
    hash_file "$tmp/data"
    # 通过 stdin 计算摘要，文件名中的反斜杠不会污染摘要字段。
    printf '%s  %s\n' "$sum" "$(basename "$out")" > "$tmp/checksum" || fail 21 "无法写入校验文件"
    publish "$tmp/data" "$out"
    publish "$tmp/checksum" "$out.sha256"

    echo "OK_PATH=$out"
    echo "OK_SHA256=$sum"
    ;;

  # ---------- 解密：读本机私钥 ----------
  decrypt)
    read_source "$@"
    secure_private
    is_age_file "$src" || fail 6 "这不是有效的 age 加密文件"

    case "$src" in
      *.age) out="${src%.age}" ;;
      *)     out="$src.decrypted" ;;
    esac
    require_absent "$out"
    acquire_lock "$out.1p-lock"
    require_absent "$out"
    make_temp "$(dirname "$out")"

    "$AGE" -d -i "$PRIV" -o "$tmp/data" "$src" || fail 8 "解密失败：私钥不匹配，或文件已损坏"
    publish "$tmp/data" "$out"

    echo "OK_PATH=$out"
    ;;

  # ---------- 生成密钥 ----------
  keygen)
    ensure_support
    acquire_lock "$SUPPORT/.keygen.1p-lock"
    [ ! -L "$PRIV" ] && [ ! -L "$PUB" ] || fail 23 "密钥文件不能是符号链接"
    if [ -f "$PRIV" ]; then
      # 私钥还在、但公钥丢了或为空 → 从私钥重新导出，避免"既不能加密也不能重新生成"的死锁
      if [ ! -s "$PUB" ]; then
        secure_private
        [ ! -e "$PUB" ] || [ -f "$PUB" ] || fail 10 "公钥路径不是普通文件：$PUB"
        make_temp "$SUPPORT"
        "$AGEKEYGEN" -y "$PRIV" > "$tmp/public.key" || fail 10 "无法从已有私钥导出公钥"
        chmod 644 "$tmp/public.key" || fail 23 "无法设置公钥权限"
        /bin/mv -f "$tmp/public.key" "$PUB" || fail 10 "无法保存恢复的公钥"
        echo "OK_PUB=$(cat "$PUB")"
        echo "NOTE=公钥已根据现有私钥重新生成"
        exit 0
      fi
      fail 9 "已经存在私钥，拒绝覆盖：$PRIV"
    fi

    [ ! -e "$PUB" ] || fail 20 "公钥还在，但私钥缺失。为防止误换密钥，已停止；请先找回原 private.key，不要删除公钥后重新生成来恢复旧备份。"
    require_absent "$PRIV"
    make_temp "$SUPPORT"
    "$AGEKEYGEN" -o "$tmp/private.key" 2>/dev/null || fail 10 "生成密钥失败"
    chmod 600 "$tmp/private.key" || fail 23 "无法设置私钥权限"
    "$AGEKEYGEN" -y "$tmp/private.key" > "$tmp/public.key" || fail 10 "无法导出公钥"
    chmod 644 "$tmp/public.key" || fail 23 "无法设置公钥权限"
    publish "$tmp/private.key" "$PRIV"
    publish "$tmp/public.key" "$PUB"

    echo "OK_PUB=$(cat "$PUB")"
    ;;

  # ---------- 查询 ----------
  public)
    [ -s "$PUB" ] || fail 3 "尚未生成密钥"
    cat "$PUB"
    ;;

  status)
    if [ -s "$PUB" ]; then
      echo "HAS_KEY=1"
      echo "PUB=$(cat "$PUB")"
    else
      echo "HAS_KEY=0"
    fi
    [ -f "$PRIV" ] && echo "HAS_PRIV=1" || echo "HAS_PRIV=0"
    echo "SUPPORT=$SUPPORT"
    ;;

  # ---------- 自检：加密再解密，确认整条链路可用 ----------
  selftest)
    ensure_support
    [ -s "$PUB" ] || fail 3 "尚未生成密钥"
    secure_private
    make_temp "$SUPPORT"
    printf 'selftest %s\n' "$(date)" > "$tmp/probe.txt" || fail 13 "无法写入自检文件"
    "$AGE" -r "$(tr -d '[:space:]' < "$PUB")" -o "$tmp/probe.age" "$tmp/probe.txt" || fail 13 "加密自检失败"
    "$AGE" -d -i "$PRIV" -o "$tmp/probe.out" "$tmp/probe.age" || fail 14 "解密自检失败：私钥与公钥不匹配"
    cmp -s "$tmp/probe.txt" "$tmp/probe.out" || fail 15 "自检结果不一致：文件被改动"
    echo "SELFTEST=OK"
    ;;

  # ---------- 校验：不解密，只核对密文的 SHA256，用于定期体检备份 ----------
  verify)
    read_source "$@"
    side="$src.sha256"
    [ -f "$side" ] || fail 16 "旁边没有找到校验文件：$side"
    want="$(cut -d' ' -f1 < "$side")" || fail 17 "无法读取校验文件"
    case "$want" in
      ''|*[!0-9a-f]*) fail 17 "校验文件内容异常" ;;
    esac
    [ "${#want}" -eq 64 ] || fail 17 "校验文件内容异常"
    hash_file "$src"
    got="$sum"
    if [ "$want" = "$got" ]; then
      echo "VERIFY=OK"
      echo "SHA256=$got"
    else
      fail 18 "校验失败：文件与记录不符，可能已损坏或被改动"
    fi
    ;;

  *)
    fail 1 "未知命令：$cmd"
    ;;
esac

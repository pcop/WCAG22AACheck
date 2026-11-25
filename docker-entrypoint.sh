#!/usr/bin/env bash
set -euo pipefail

# 無參數或 --help / -h 不需寫入目錄，直接執行
if [[ $# -eq 0 ]]; then
    exec /usr/local/bin/wcag22-check.sh --help
fi

out_dir="."
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
        -h|--help) exec /usr/local/bin/wcag22-check.sh "$@" ;;
        -o|--out)
            if (( i + 1 < ${#args[@]} )); then
                out_dir="${args[$((i + 1))]}"
            fi
            ;;
    esac
done

# 向上尋找最深已存在的目錄作為寫入權限檢查目標
check_dir="$out_dir"
while [[ ! -e "$check_dir" && "$check_dir" != "/" && "$check_dir" != "." ]]; do
    check_dir="$(dirname "$check_dir")"
done

if [[ -d "$check_dir" && ! -w "$check_dir" ]]; then
    dir_owner="$(stat -c '%u:%g (%A)' "$check_dir" 2>/dev/null || echo '未知')"
    cat >&2 <<EOF
錯誤：輸出目錄（${check_dir}）無法寫入（目前執行身份：$(id -u):$(id -g)，目錄權限：${dir_owner}）。
常見原因與解決方式：
  1. 若目錄擁有者為 0:0（root），通常是執行 docker run 前未先建立掛載目錄，被 Docker 自動以 root 建立。
     請於宿主機移除該空目錄後重新建立：rmdir ./reports && mkdir -p ./reports
  2. 若宿主機帳號 UID 非 1000（例如網域帳號），請在 docker run 加上：--user "\$(id -u):\$(id -g)"
EOF
    exit 1
fi

exec /usr/local/bin/wcag22-check.sh "$@"

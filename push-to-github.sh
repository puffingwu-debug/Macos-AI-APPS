#!/bin/bash
#
# 在这台机器上推送代码到 GitHub。
#
# 为什么需要它：本机到 github.com 的 git HTTPS 端点不通（连接超时），
# 但 api.github.com 正常。所以这里走 GitHub 的 Git Data API 手动建
# tree / commit / ref，等价于一次 git push，只是绕开了被阻断的端点。
#
#   ./push-to-github.sh "提交说明"
#
# 说明：
#   - 以 git 索引为准（脚本会先 git add -A），.gitignore 依然生效
#   - 会读取远端当前 main 作为父提交，因此历史是正常累积的，不是覆盖
#   - 需要 gh 已登录（gh auth status）
#
set -euo pipefail

REPO="${REPO:-puffingwu-debug/Macos-AI-APPS}"
BRANCH="${BRANCH:-main}"
MESSAGE="${1:-Update $(date '+%Y-%m-%d %H:%M')}"

cd "$(dirname "$0")"

if ! gh auth status >/dev/null 2>&1; then
  echo "!! gh 未登录，先执行：gh auth login" >&2
  exit 1
fi

echo "==> 暂存改动"
git add -A

COUNT=$(git ls-files | wc -l | tr -d ' ')
if [ "$COUNT" = "0" ]; then
  echo "!! 没有可提交的文件" >&2
  exit 1
fi

echo "==> 通过 API 提交 $COUNT 个文件到 $REPO ($BRANCH)"
python3 - "$REPO" "$BRANCH" "$MESSAGE" <<'PY'
import subprocess, json, sys

repo, branch, message = sys.argv[1], sys.argv[2], sys.argv[3]

def gh(args, payload=None):
    cmd = ["gh", "api"] + args
    if payload is not None:
        with open("/tmp/gh-push-payload.json", "w") as f:
            json.dump(payload, f, ensure_ascii=True)
        cmd += ["--input", "/tmp/gh-push-payload.json"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.exit(1)
    return json.loads(r.stdout) if r.stdout.strip() else {}

# 父提交：远端当前 head（仓库为空时没有）
parent = None
try:
    parent = gh([f"repos/{repo}/git/ref/heads/{branch}"])["object"]["sha"]
except SystemExit:
    print("   （远端分支不存在，将创建首个提交）")

# 以 git 索引为准，保留可执行位
entries = []
for line in subprocess.run(["git", "ls-files", "-s"], capture_output=True, text=True).stdout.splitlines():
    meta, path = line.split("\t", 1)
    entries.append({
        "path": path,
        "mode": meta.split()[0],
        "type": "blob",
        "content": open(path, "rb").read().decode("utf-8"),
    })

tree = gh([f"repos/{repo}/git/trees"], {"tree": entries})
commit_body = {
    "message": message,
    "tree": tree["sha"],
    "author": {"name": "puffingwu-debug", "email": "puffingwu@gmail.com"},
    "committer": {"name": "puffingwu-debug", "email": "puffingwu@gmail.com"},
}
if parent:
    commit_body["parents"] = [parent]
commit = gh([f"repos/{repo}/git/commits"], commit_body)

if parent:
    gh([f"repos/{repo}/git/refs/heads/{branch}", "-X", "PATCH", "-f", f"sha={commit['sha']}"])
else:
    gh([f"repos/{repo}/git/refs", "-f", f"ref=refs/heads/{branch}", "-f", f"sha={commit['sha']}"])

print(f"   {parent[:10] if parent else '(root)'} → {commit['sha'][:10]}  {len(entries)} files")
PY

echo "==> 完成：https://github.com/$REPO"

import os
import sys
import tarfile
import shutil
import subprocess
import datetime
from huggingface_hub import HfApi, hf_hub_download, CommitOperationAdd, CommitOperationDelete

api = HfApi()
repo_id = os.getenv("HF_DATASET")
token = os.getenv("H_TOKEN")
FILENAME = "latest_backup.tar.gz"

# rclone 目标配置
RCLONE_DEST = os.getenv("RCLONE_BACKUP_DEST", "nvsu:latest_backup.tar.gz")

# ==================== 配置 ====================
LFS_KEEP_COUNT = int(os.getenv("LFS_KEEP_COUNT", "5")) # 保留最近 N 个 LFS 对象（存储层面）
LFS_DRY_RUN = os.getenv("LFS_DRY_RUN", "false").lower() in ("true", "1", "yes")
# ================================================

def upload_to_rclone(local_path, remote_path):
    """尝试用 rclone 上传文件到远程存储，失败时仅打印警告"""
    if not shutil.which("rclone"):
        print("rclone 命令不存在，跳过 rclone 上传")
        return False

    try:
        cmd = ["rclone", "copy", local_path, remote_path, "--progress"]
        print(f"正在使用 rclone 上传到 {remote_path} ...")
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        if result.returncode == 0:
            print(f"rclone 上传成功: {remote_path}")
            return True
        else:
            print(f"rclone 上传失败 (返回码 {result.returncode}): {result.stderr}")
            return False
    except Exception as e:
        print(f"rclone 上传异常: {str(e)}")
        return False

def clean_lfs_objects():
    """永久删除旧版本的 LFS 对象以释放存储配额（针对 latest_backup.tar.gz）"""
    try:
        print("\n🧹 开始清理冗余 LFS 存储对象...")
        lfs_files = list(api.list_lfs_files(repo_id=repo_id, repo_type="dataset", token=token))
        candidates = [f for f in lfs_files if f.filename == FILENAME]
        print(f" 匹配到 {len(candidates)} 个 '{FILENAME}' 的 LFS 版本")

        if not candidates:
            print(" 没有发现可清理的 LFS 对象。")
            return True

        candidates.sort(key=lambda x: x.pushed_at, reverse=True)
        to_delete = candidates[LFS_KEEP_COUNT:]

        if not to_delete:
            print(f" 备份数量 ({len(candidates)}) 未超过保留阈值 ({LFS_KEEP_COUNT})，无需清理。")
            return True

        print(f" 计划删除 {len(to_delete)} 个旧 LFS 对象：")
        for f in to_delete:
            print(f"  • OID: {f.oid} | Pushed: {f.pushed_at} | Size: {f.size / 1024 / 1024:.2f} MB")

        if LFS_DRY_RUN:
            print(" [DRY-RUN] 未执行实际删除操作。")
        else:
            api.permanently_delete_lfs_files(
                repo_id=repo_id,
                lfs_files=to_delete,
                repo_type="dataset",
                token=token
            )
            print(f"✅ 已永久删除 {len(to_delete)} 个旧 LFS 对象。")

        return True
    except Exception as e:
        print(f"LFS 清理异常: {str(e)}")
        return False

def safe_merge_files(src_root, dst_root):
    """
    递归地将 src_root 的内容合并到 dst_root。
    - 目录：使用 dirs_exist_ok=True 进行合并。
    - 文件：如果目标文件已存在，先将其备份为 .bak，再覆盖。
    """
    for item in os.listdir(src_root):
        src_path = os.path.join(src_root, item)
        dst_path = os.path.join(dst_root, item)

        if os.path.isdir(src_path):
            os.makedirs(dst_path, exist_ok=True)
            # 递归处理子目录，以便对子目录中的文件也能执行 .bak 备份
            safe_merge_files(src_path, dst_path)
        elif os.path.isfile(src_path):
            if os.path.exists(dst_path):
                bak_path = dst_path + ".bak"
                shutil.copy2(dst_path, bak_path)
                print(f"  [保护] 已将现有文件备份至: {os.path.basename(bak_path)}")
            shutil.copy2(src_path, dst_path)
            print(f"  [恢复] {item}")

def restore():
    try:
        if not repo_id or not token:
            print("Skip Restore: HF_DATASET or H_TOKEN not set")
            return False

        print(f"正在从 Hugging Face 下载备份文件 {FILENAME} (repo: {repo_id}) ...")
        downloaded_path = hf_hub_download(
            repo_id=repo_id,
            filename=FILENAME,
            repo_type="dataset",
            token=token
        )

        temp_dir = "/root/.openclaw/restore_temp"
        if os.path.exists(temp_dir):
            shutil.rmtree(temp_dir)
        os.makedirs(temp_dir, exist_ok=True)

        print(f"解压备份到临时目录: {temp_dir}")
        with tarfile.open(downloaded_path, "r:gz") as tar:
            tar.extractall(path=temp_dir)

        # 1. 处理 /app/data (合并)
        temp_data = os.path.join(temp_dir, "data")
        target_data = "/app/data"
        if os.path.exists(temp_data):
            os.makedirs(target_data, exist_ok=True)
            shutil.copytree(temp_data, target_data, dirs_exist_ok=True)
            print(f"✅ 已合并备份中的 data 目录到 {target_data}")
        else:
            print("备份包中未找到 data 目录，跳过 /app/data 恢复")

        # 2. 处理 /root/.openclaw 下的其他配置 (安全合并)
        print("\n🛡️ 开始安全合并配置到 /root/.openclaw ...")
        # 排除 data 目录，因为它已经处理过了
        for item in os.listdir(temp_dir):
            if item == "data":
                continue
            
            src_path = os.path.join(temp_dir, item)
            dst_path = os.path.join("/root/.openclaw", item)

            if os.path.isdir(src_path):
                os.makedirs(dst_path, exist_ok=True)
                safe_merge_files(src_path, dst_path)
            elif os.path.isfile(src_path):
                if os.path.exists(dst_path):
                    shutil.copy2(dst_path, dst_path + ".bak")
                    print(f"  [保护] 已将现有文件备份至: {item}.bak")
                shutil.copy2(src_path, dst_path)
                print(f"  [恢复] {item}")

        shutil.rmtree(temp_dir, ignore_errors=True)
        print(f"\n✅ 恢复完成！所有冲突文件已备份为 .bak，请检查必要配置。")
        return True
    except Exception as e:
        print(f"恢复失败: {str(e)}")
        return False

def backup():
    try:
        if not repo_id or not token:
            print("Skip Backup: HF_DATASET or H_TOKEN not set")
            return False

        print("开始创建备份文件...")
        timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")

        # 1. 创建压缩包
        with tarfile.open(FILENAME, "w:gz") as tar:
            paths_to_backup = [
                "/app/data",
                "/root/.openclaw/agents",
                "/root/.openclaw/canvas",
                "/root/.openclaw/credentials",
                "/root/.openclaw/cron",
                "/root/.openclaw/identity",
                "/root/.openclaw/openclaw.json",
                "/root/.openclaw/sessions",
                "/root/.openclaw/skills",
                "/root/.openclaw/update-check.json",
                "/root/.openclaw/workspace",
            ]
            for path in paths_to_backup:
                if os.path.exists(path):
                    # 针对不同路径生成合适的 arcname（压缩包内路径）
                    if path.startswith("/root/.openclaw/"):
                        arcname = path.replace("/root/.openclaw/", "")
                    elif path.startswith("/app/"):
                        arcname = path.replace("/app/", "")
                    elif path == "/ql/data":
                        arcname = "ql/data"
                    else:
                        arcname = path.lstrip('/')
                    tar.add(path, arcname=arcname)
                    print(f"已加入: {arcname}")

        print(f"本地备份文件创建完成: {FILENAME}")

        # 2. 原子 commit (覆盖 latest_backup.tar.gz)
        operations = []
        repo_files = api.list_repo_files(repo_id=repo_id, repo_type="dataset", token=token)

        if FILENAME in repo_files:
            operations.append(CommitOperationDelete(path_in_repo=FILENAME))

        operations.append(CommitOperationAdd(path_in_repo=FILENAME, path_or_fileobj=FILENAME))

        api.create_commit(
            repo_id=repo_id,
            repo_type="dataset",
            operations=operations,
            commit_message=f"Update latest backup {timestamp}",
            token=token
        )
        print(f"✅ HF 备份成功！已更新 {FILENAME}")

        # 3. 执行 LFS 存储清理（彻底释放空间）
        clean_lfs_objects()

        # 4. rclone 次要备份
        upload_to_rclone(FILENAME, RCLONE_DEST)

        # 5. 清理本地临时文件
        if os.path.exists(FILENAME):
            os.remove(FILENAME)

        return True
    except Exception as e:
        print(f"备份失败: {str(e)}")
        if os.path.exists(FILENAME) and os.path.isfile(FILENAME):
            os.remove(FILENAME)
        return False

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "backup":
        success = backup()
        sys.exit(0 if success else 1)
    else:
        success = restore()
        sys.exit(0 if success else 1)

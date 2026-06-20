import sys
import os
for path in ['', '/root', os.getcwd()]:
    while path in sys.path:
        sys.path.remove(path)

from github import Github, Auth, GithubException
import requests

def main():
    GITHUB_TOKEN = os.getenv("GITHUB_T")
    auth = Auth.Token(GITHUB_TOKEN)
    g = Github(auth=auth)

    repo_name = "serezha750/Binance"
    workflow_filename = "Binance.yml"
    branch = "main"

    try:
        repo = g.get_repo(repo_name)
        print(f"✅ 已连接到仓库: {repo.full_name}")
        workflow = repo.get_workflow(workflow_filename)
        print(f"✅ 找到工作流: {workflow.name} (ID: {workflow.id})")
        inputs = {}  # 例如: {"environment": "production"}
        print(f"🚀 正在触发工作流 '{workflow.name}' on branch '{branch}' ...")
        workflow.create_dispatch(ref=branch, inputs=inputs)
        print("✅ 工作流已成功触发！")
    except GithubException as e:
        print(f"❌ GitHub API 错误: {e}")
    except Exception as e:
        print(f"❌ 发生未知错误: {e}")

if __name__ == "__main__":
    main()
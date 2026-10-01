# GitHub Organization 招待 & チーム振り分けスクリプト

`gh` (GitHub CLI) を使用して、CSVファイルに記載された学生のGitHubアカウントをOrganizationに一括招待し、指定のチームに自動振り分け（存在しないチームは自動作成）するスクリプトです。

---

## 📁 ディレクトリ構成

```text
github-org-inviter/
├── invite_and_assign.sh    # メンバー招待＆チーム振り分けスクリプト
├── students.csv.example    # メンバー招待用のサンプルCSV
├── create_team_repos.sh    # チームリポジトリ作成スクリプト (新規)
├── repos.csv.example       # リポジトリ作成用のサンプルCSV (新規)
└── README.md               # 本ドキュメント
```

---

## 準備

### 1. GitHub CLI の認証と権限の確認

GitHub CLI でログインし、Organizationの管理権限（`admin:org` スコープ）を付与します。

```bash
# ログインしていない場合
gh auth login

# Organization招待・チーム作成に必要なスコープを付与
gh auth refresh -s admin:org
```

### 2. CSVファイルの作成

`students.csv.example` を参考に、`students.csv` を作成します。

```csv
username,team
student-alice,team-a
student-bob,team-b
student-charlie,
```

- **`username`**: 学生のGitHubユーザー名（必須）
- **`team`**: 振り分け先のチーム名（空欄の場合はOrganizationへの招待のみ行われます）

---

## 使い方

### 1. スクリプトの実行権限を付与
```bash
chmod +x invite_and_assign.sh
```

### 2. ドライラン（シミュレーション確認）
実際に招待やチーム作成を行わずに、アカウントの存在確認やシミュレーションのみを実行します。

```bash
# スクリプト内の ORG を編集している場合
./invite_and_assign.sh --dry-run

# または環境変数でOrganization名を指定する場合
ORG_NAME="your-org-name" ./invite_and_assign.sh --dry-run
```

### 3. 本番実行
```bash
ORG_NAME="your-org-name" ./invite_and_assign.sh
```

---

## 主な機能・仕様

1. **GitHubアカウントの実在チェック**
   - 学生のタイポ等でGitHub上に存在しないアカウント名を事前に検知してエラー表示します。
2. **既存メンバー・招待中チェック**
   - 既にOrganizationに参加している、または既に招待状を送信中の場合は二重送信を防止します。
3. **チームの自動作成 (`AUTO_CREATE_TEAM=true`)**
   - CSVに書かれたチームが存在しない場合、自動的に `POST /orgs/{org}/teams` で新規作成（デフォルト: `closed`）して追加します。
4. **レートリミット対策**
   - リクエスト間にウェイト（デフォルト: 0.5秒）を挟み、API制限を回避します。
5. **Excel/CRLF改行対応**
   - Windows環境のExcel等で保存された改行コード（`\r\n`）を自動除去します。

---

## チームリポジトリの一括作成 (`create_team_repos.sh`)

学生チームごとのリポジトリを作成し、対象チームへアクセス権限（書き込み権限 `push` 等）を一括付与するスクリプトです。

### 1. CSVファイルの準備 (`repos.csv`)
`repos.csv.example` を参考に `repos.csv` を作成します。

```csv
repo,team,description,visibility
project-team-alpha,team-alpha,Team Alpha Project Repository,private
project-team-beta,team-beta,Team Beta Project Repository,private
assignment-team-gamma,team-gamma,,private
```
- **`repo`**: リポジトリ名（必須）
- **`team`**: アクセス権限を付与するチーム名（任意）
- **`description`**: リポジトリの説明文（任意・空欄可）
- **`visibility`**: `private` または `public`（省略時はデフォルトで `private`）

### 2. ドライラン実行
```bash
ORG_NAME="your-org-name" ./create_team_repos.sh --dry-run
```

### 3. 本番実行
```bash
ORG_NAME="your-org-name" ./create_team_repos.sh
```

> **Tips:**
> テンプレートリポジトリから複製して作成したい場合は、環境変数 `TEMPLATE_REPO` を指定できます。
> ```bash
> TEMPLATE_REPO="your-org/template-repo" ORG_NAME="your-org-name" ./create_team_repos.sh
> ```

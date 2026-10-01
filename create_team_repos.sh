#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# 設定項目
# ==============================================================================
ORG="${ORG_NAME:-YOUR_ORGANIZATION_NAME}"
CSV_FILE="${REPOS_CSV_PATH:-repos.csv}"
DEFAULT_VISIBILITY="private"
TEAM_PERMISSION="push"
TEMPLATE_REPO="${TEMPLATE_REPO:-}"
SLEEP_INTERVAL=0.5

# ==============================================================================
# ターミナルカラー設定 (見やすさ向上)
# ==============================================================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="\033[0m"
  C_BOLD="\033[1m"
  C_GREEN="\033[32m"
  C_BLUE="\033[34m"
  C_CYAN="\033[36m"
  C_YELLOW="\033[33m"
  C_RED="\033[31m"
  C_GRAY="\033[90m"
else
  C_RESET=""
  C_BOLD=""
  C_GREEN=""
  C_BLUE=""
  C_CYAN=""
  C_YELLOW=""
  C_RED=""
  C_GRAY=""
fi

# ==============================================================================
# オプション解析・引数チェック
# ==============================================================================
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    -h|--help)
      echo "使用方法: $0 [--dry-run]"
      echo ""
      echo "オプション:"
      echo "  --dry-run         実際にリポジトリ作成や権限付与を行わず、シミュレーションを実行します"
      echo ""
      echo "環境変数:"
      echo "  ORG_NAME          Organization名を指定 (デフォルト: $ORG)"
      echo "  REPOS_CSV_PATH    CSVファイルのパスを指定 (デフォルト: $CSV_FILE)"
      echo "  TEMPLATE_REPO     テンプレートリポジトリを指定 (例: org/template)"
      exit 0
      ;;
    *)
      echo "未知のオプション: $arg" >&2
      exit 1
      ;;
  esac
done

if [ "$ORG" = "YOUR_ORGANIZATION_NAME" ]; then
  echo -e "${C_RED}【エラー】スクリプト内の ORG を設定するか、ORG_NAME環境変数を指定してください。${C_RESET}" >&2
  echo "例: ORG_NAME=my-org $0" >&2
  exit 1
fi

if [ ! -f "$CSV_FILE" ]; then
  echo -e "${C_RED}【エラー】CSVファイル '$CSV_FILE' が見つかりません。${C_RESET}" >&2
  exit 1
fi

echo "=================================================="
echo -e "${C_BOLD} GitHub チームリポジトリ一括作成スクリプト${C_RESET}"
echo "=================================================="
echo " Organization   : $ORG"
echo " CSVファイル    : $CSV_FILE"
echo " デフォルト公開 : $DEFAULT_VISIBILITY"
echo " チーム付与権限 : $TEAM_PERMISSION"
if [ -n "$TEMPLATE_REPO" ]; then
  echo " テンプレート   : $TEMPLATE_REPO"
fi
if [ "$DRY_RUN" = true ]; then
  echo -e " 実行モード     : ${C_YELLOW}${C_BOLD}【DRY-RUN (シミュレーション)】※ 実際の変更は行われません${C_RESET}"
else
  echo -e " 実行モード     : ${C_GREEN}${C_BOLD}【本番実行】${C_RESET}"
fi
echo "=================================================="
echo ""

# カウンター初期化
total_repos=0
repo_already_exists=0
repo_newly_created=0
team_already_has_permission=0
team_permission_granted=0
skip_count=0
fail_count=0

# CSVの各行を読み込み処理 (CRLF / LF 両対応)
line_number=0
while IFS=, read -r raw_repo raw_team raw_desc raw_vis rest || [ -n "$raw_repo" ]; do
  ((line_number++))

  # 前後の空白・改行・引用符を除去
  repo=$(echo "$raw_repo" | tr -d '\r\n ' | sed 's/^"//;s/"$//')
  team=$(echo "${raw_team:-}" | tr -d '\r\n ' | sed 's/^"//;s/"$//')
  desc=$(echo "${raw_desc:-}" | tr -d '\r\n' | sed 's/^"//;s/"$//')
  vis=$(echo "${raw_vis:-}" | tr -d '\r\n ' | sed 's/^"//;s/"$//')

  # 空行やコメント行 (#) をスキップ
  if [[ -z "$repo" || "$repo" =~ ^# ]]; then
    continue
  fi

  # ヘッダー行 (repo, name, repository) の完全一致スキップ
  if [[ "$repo" == "repo" || "$repo" == "name" || "$repo" == "repository" ]]; then
    continue
  fi

  # 公開設定の判定
  visibility="${vis:-$DEFAULT_VISIBILITY}"
  if [[ "$visibility" != "public" && "$visibility" != "private" && "$visibility" != "internal" ]]; then
    visibility="$DEFAULT_VISIBILITY"
  fi

  ((total_repos++))
  echo "--------------------------------------------------"
  echo -e "${C_BOLD}[${line_number}行目] リポジトリ: $repo (チーム: ${team:-なし})${C_RESET}"

  # 1. リポジトリの存在チェック
  repo_exists=false
  if gh repo view "$ORG/$repo" --json nameWithOwner >/dev/null 2>&1; then
    repo_exists=true
  fi

  if [ "$repo_exists" = true ]; then
    echo -e "  - リポジトリ作成 : ${C_CYAN}[既存リポジトリ] すでに作成済みです (何もしません)${C_RESET}"
    ((repo_already_exists++))
  else
    if [ "$DRY_RUN" = true ]; then
      desc_info=""
      if [ -n "$desc" ]; then desc_info=", 説明='$desc'"; fi
      echo -e "  - リポジトリ作成 : ${C_GREEN}${C_BOLD}[★ 予定] 新規作成します (公開: $visibility$desc_info)${C_RESET}"
      ((repo_newly_created++))
    else
      echo -n "  - リポジトリ作成 : 作成中 ($visibility)... "
      create_args=("$ORG/$repo" "--$visibility")
      if [ -n "$desc" ]; then
        create_args+=("--description" "$desc")
      fi

      if [ -n "$TEMPLATE_REPO" ]; then
        create_args+=("--template" "$TEMPLATE_REPO")
      fi

      if create_output=$(gh repo create "${create_args[@]}" 2>&1); then
        echo -e "${C_GREEN}[作成完了]${C_RESET}"
        ((repo_newly_created++))
        repo_exists=true
      else
        echo -e "${C_RED}[作成失敗]${C_RESET}"
        echo -e "    ${C_RED}詳細: $create_output${C_RESET}"
        ((fail_count++))
        continue
      fi
    fi
  fi

  # 2. チームへの権限付与処理 (チーム指定がある場合)
  if [ -n "$team" ]; then
    # チーム名を小文字スラッグに変換 (GitHub API用)
    team_slug=$(echo "$team" | tr '[:upper:]' '[:lower:]')

    # チームの存在確認 (スラッグまたは元の名前で確認)
    actual_team=""
    if gh api "orgs/$ORG/teams/$team_slug" --silent 2>/dev/null; then
      actual_team="$team_slug"
    elif gh api "orgs/$ORG/teams/$team" --silent 2>/dev/null; then
      actual_team="$team"
    fi

    if [ -z "$actual_team" ]; then
      echo -e "  - チーム権限     : ${C_RED}[✕ エラー] チーム '$team' がOrganization内に存在しません${C_RESET}"
      ((skip_count++))
      continue
    fi

    # 既に権限が付与されているかチェック
    has_perm=false
    if [ "$repo_exists" = true ]; then
      if gh api "orgs/$ORG/teams/$actual_team/repos/$ORG/$repo" --silent 2>/dev/null; then
        has_perm=true
      fi
    fi

    if [ "$has_perm" = true ]; then
      echo -e "  - チーム権限     : ${C_CYAN}[権限設定済み] チーム '$actual_team' には既に権限が付与されています (何もしません)${C_RESET}"
      ((team_already_has_permission++))
    else
      if [ "$DRY_RUN" = true ]; then
        echo -e "  - チーム権限     : ${C_GREEN}${C_BOLD}[★ 予定] チーム '$actual_team' に '$TEAM_PERMISSION' (書き込み) 権限を付与します${C_RESET}"
        ((team_permission_granted++))
      else
        echo -n "  - チーム権限     : チーム '$actual_team' に権限 '$TEAM_PERMISSION' を付与中... "
        if perm_output=$(gh api --method PUT \
          -H "Accept: application/vnd.github+json" \
          "/orgs/$ORG/teams/$actual_team/repos/$ORG/$repo" \
          -f permission="$TEAM_PERMISSION" 2>&1); then
          echo -e "${C_GREEN}[付与完了]${C_RESET}"
          ((team_permission_granted++))
        else
          echo -e "${C_RED}[付与失敗]${C_RESET}"
          echo -e "    ${C_RED}詳細: $perm_output${C_RESET}"
          ((fail_count++))
          continue
        fi
      fi
    fi
  fi

  sleep "$SLEEP_INTERVAL"
done < "$CSV_FILE"

echo ""
echo "=================================================="
if [ "$DRY_RUN" = true ]; then
  echo -e "${C_BOLD} 📋 DRY-RUN シミュレーション結果サマリー (対象: ${total_repos} 件)${C_RESET}"
  echo "=================================================="
  echo -e "${C_GREEN}${C_BOLD} 【本番実行時に行われるアクション】${C_RESET}"
  echo "   ★ リポジトリ新規作成     : ${repo_newly_created} 件"
  echo "   ★ チーム権限付与         : ${team_permission_granted} 件"
  echo ""
  echo -e "${C_CYAN} 【スキップされる対象 (変更不要)】${C_RESET}"
  echo "   - 既存リポジトリ          : ${repo_already_exists} 件"
  echo "   - 権限設定済み            : ${team_already_has_permission} 件"
  if [ "$skip_count" -gt 0 ] || [ "$fail_count" -gt 0 ]; then
    echo ""
    echo -e "${C_RED} 【要確認・エラー】${C_RESET}"
    if [ "$skip_count" -gt 0 ]; then
      echo "   - スキップ (未存在チーム) : ${skip_count} 件"
    fi
    if [ "$fail_count" -gt 0 ]; then
      echo "   - 作成失敗等のエラー      : ${fail_count} 件"
    fi
  fi
  echo "=================================================="
  echo -e " ${C_BOLD}👉 本番実行を行うには、--dry-run を外して実行してください:${C_RESET}"
  echo "    ORG_NAME=\"$ORG\" ./create_team_repos.sh"
  echo "=================================================="
else
  echo -e "${C_BOLD} 処理結果サマリー (対象: ${total_repos} 件)${C_RESET}"
  echo "=================================================="
  echo " [リポジトリ]"
  echo "   - 新規作成完了            : ${repo_newly_created} 件"
  echo "   - 既存 (スキップ)         : ${repo_already_exists} 件"
  echo " [チーム権限]"
  echo "   - 権限付与完了            : ${team_permission_granted} 件"
  echo "   - 設定済み (スキップ)     : ${team_already_has_permission} 件"
  if [ "$skip_count" -gt 0 ] || [ "$fail_count" -gt 0 ]; then
    echo " [エラー・スキップ]"
    if [ "$skip_count" -gt 0 ]; then
      echo "   - チーム未存在スキップ    : ${skip_count} 件"
    fi
    if [ "$fail_count" -gt 0 ]; then
      echo "   - エラー/失敗            : ${fail_count} 件"
    fi
  fi
  echo "=================================================="
fi

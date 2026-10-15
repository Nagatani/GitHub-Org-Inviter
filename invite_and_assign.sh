#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# 設定項目
# ==============================================================================
ORG="${ORG_NAME:-YOUR_ORGANIZATION_NAME}"
CSV_FILE="${CSV_PATH:-students.csv}"
ROLE="member"
AUTO_CREATE_TEAM=true
TEAM_PRIVACY="closed"
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
      echo "  --dry-run   実際にAPIによる変更を行わず、シミュレーションのみ実行します"
      echo ""
      echo "環境変数:"
      echo "  ORG_NAME    Organization名を指定 (デフォルト: $ORG)"
      echo "  CSV_PATH    CSVファイルのパスを指定 (デフォルト: $CSV_FILE)"
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
echo -e "${C_BOLD} GitHub Organization & チーム一括招待スクリプト${C_RESET}"
echo "=================================================="
echo " Organization   : $ORG"
echo " CSVファイル    : $CSV_FILE"
echo " チーム自動作成 : $AUTO_CREATE_TEAM"
if [ "$DRY_RUN" = true ]; then
  echo -e " 実行モード     : ${C_YELLOW}${C_BOLD}【DRY-RUN (シミュレーション)】※ 実際の変更は行われません${C_RESET}"
else
  echo -e " 実行モード     : ${C_GREEN}${C_BOLD}【本番実行】${C_RESET}"
fi
echo "=================================================="
echo ""

# カウンター初期化
total_users=0
org_already_member=0
org_already_invited=0
org_newly_invited=0
team_already_member=0
team_already_invited=0
team_newly_assigned=0
team_newly_created=0
skip_count=0
fail_count=0

# CSVの各行を読み込み処理 (CRLF / LF 両対応)
line_number=0
while IFS=, read -r raw_username raw_team rest || [ -n "$raw_username" ]; do
  ((line_number++))

  # 前後の空白・改行・引用符を除去
  username=$(echo "$raw_username" | tr -d '\r\n ' | sed 's/^"//;s/"$//')
  team=$(echo "${raw_team:-}" | tr -d '\r\n ' | sed 's/^"//;s/"$//')

  # 空行やコメント行 (#) をスキップ
  if [[ -z "$username" || "$username" =~ ^# ]]; then
    continue
  fi

  # ヘッダー行 (username, github, user) の完全一致スキップ
  if [[ "$username" == "username" || "$username" == "github" || "$username" == "user" ]]; then
    continue
  fi

  ((total_users++))
  echo "--------------------------------------------------"
  echo -e "${C_BOLD}[${line_number}行目] ユーザー: $username${C_RESET}"

  # 1. GitHub上にユーザーが存在するかチェック
  if ! gh api "users/$username" --silent 2>/dev/null; then
    echo -e "  ${C_RED}[✕ エラー] GitHubアカウント '$username' が存在しません (ユーザー名の誤字の可能性)${C_RESET}"
    ((fail_count++))
    continue
  fi

  # 2. Organizationの現在の所属状態をチェック
  org_status="none"
  if membership_info=$(gh api "orgs/$ORG/memberships/$username" 2>/dev/null); then
    org_status=$(echo "$membership_info" | gh json '.state' 2>/dev/null || echo "unknown")
  fi

  if [ "$org_status" = "active" ]; then
    echo -e "  - Organization : ${C_CYAN}[既存メンバー] すでにOrganizationに参加済みです (何もしません)${C_RESET}"
    ((org_already_member++))
  elif [ "$org_status" = "pending" ]; then
    echo -e "  - Organization : ${C_CYAN}[招待済み] すでに招待状を送信済みです (承認待ち / 何もしません)${C_RESET}"
    ((org_already_invited++))
  else
    if [ "$DRY_RUN" = true ]; then
      echo -e "  - Organization : ${C_GREEN}${C_BOLD}[★ 予定] 招待状を送信します (ロール: $ROLE)${C_RESET}"
      ((org_newly_invited++))
    else
      echo -n "  - Organization : 招待を送信中... "
      if invite_output=$(gh api --method PUT \
        -H "Accept: application/vnd.github+json" \
        "/orgs/$ORG/memberships/$username" \
        -f role="$ROLE" 2>&1); then
        echo -e "${C_GREEN}[送信完了] 招待状を送信しました${C_RESET}"
        ((org_newly_invited++))
      else
        echo -e "${C_RED}[送信失敗] 招待の送信に失敗しました${C_RESET}"
        echo -e "    ${C_RED}詳細: $invite_output${C_RESET}"
        ((fail_count++))
        continue
      fi
    fi
  fi

  # 3. チームへの所属処理 (チーム指定がある場合)
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
      if [ "$AUTO_CREATE_TEAM" = true ]; then
        if [ "$DRY_RUN" = true ]; then
          echo -e "  - チーム作成   : ${C_GREEN}${C_BOLD}[★ 予定] チーム '$team' は未作成のため、新規作成します${C_RESET}"
          ((team_newly_created++))
          actual_team="$team_slug"
        else
          echo -n "  - チーム作成   : チーム '$team' を新規作成中... "
          if team_create_output=$(gh api --method POST \
            -H "Accept: application/vnd.github+json" \
            "/orgs/$ORG/teams" \
            -f name="$team" \
            -f privacy="$TEAM_PRIVACY" 2>&1); then
            echo -e "${C_GREEN}[作成完了]${C_RESET}"
            ((team_newly_created++))
            actual_team="$team_slug"
          else
            echo -e "${C_RED}[作成失敗] (権限等を確認してください)${C_RESET}"
            echo -e "    ${C_RED}詳細: $team_create_output${C_RESET}"
            ((fail_count++))
            continue
          fi
        fi
      else
        echo -e "  - チーム作成   : ${C_YELLOW}[スキップ] チーム '$team' は存在しません (AUTO_CREATE_TEAM=false)${C_RESET}"
        ((skip_count++))
        continue
      fi
    fi

    # チーム所属状態のチェック
    team_status="none"
    if [ -n "$actual_team" ]; then
      if team_membership_info=$(gh api "orgs/$ORG/teams/$actual_team/memberships/$username" 2>/dev/null); then
        team_status=$(echo "$team_membership_info" | gh json '.state' 2>/dev/null || echo "unknown")
      fi
    fi

    if [ "$team_status" = "active" ]; then
      echo -e "  - チーム($actual_team) : ${C_CYAN}[所属済み] すでにこのチームのメンバーです (何もしません)${C_RESET}"
      ((team_already_member++))
    elif [ "$team_status" = "pending" ]; then
      echo -e "  - チーム($actual_team) : ${C_CYAN}[参加待ち] すでにチームへの参加が保留中です (何もしません)${C_RESET}"
      ((team_already_invited++))
    else
      if [ "$DRY_RUN" = true ]; then
        echo -e "  - チーム($actual_team) : ${C_GREEN}${C_BOLD}[★ 予定] チームに追加します${C_RESET}"
        ((team_newly_assigned++))
      else
        echo -n "  - チーム($actual_team) : チームに追加中... "
        if team_assign_output=$(gh api --method PUT \
          -H "Accept: application/vnd.github+json" \
          "/orgs/$ORG/teams/$actual_team/memberships/$username" \
          -f role="member" 2>&1); then
          echo -e "${C_GREEN}[追加完了]${C_RESET}"
          ((team_newly_assigned++))
        else
          echo -e "${C_RED}[追加失敗]${C_RESET}"
          echo -e "    ${C_RED}詳細: $team_assign_output${C_RESET}"
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
  echo -e "${C_BOLD} 📋 DRY-RUN シミュレーション結果サマリー (対象: ${total_users} 名)${C_RESET}"
  echo "=================================================="
  echo -e "${C_GREEN}${C_BOLD} 【本番実行時に行われるアクション】${C_RESET}"
  echo "   ★ Organization新規招待   : ${org_newly_invited} 名"
  echo "   ★ チーム新規作成         : ${team_newly_created} チーム"
  echo "   ★ チーム新規追加         : ${team_newly_assigned} 名"
  echo ""
  echo -e "${C_CYAN} 【スキップされる対象 (変更不要)】${C_RESET}"
  echo "   - Org参加済み (既存)      : ${org_already_member} 名"
  echo "   - Org招待中 (承認待ち)    : ${org_already_invited} 名"
  echo "   - チーム所属済み (既存)   : ${team_already_member} 名"
  if [ "$team_already_invited" -gt 0 ]; then
    echo "   - チーム参加保留中        : ${team_already_invited} 名"
  fi
  if [ "$skip_count" -gt 0 ] || [ "$fail_count" -gt 0 ]; then
    echo ""
    echo -e "${C_RED} 【要確認・エラー】${C_RESET}"
    if [ "$skip_count" -gt 0 ]; then
      echo "   - スキップ (未存在チーム) : ${skip_count} 件"
    fi
    if [ "$fail_count" -gt 0 ]; then
      echo "   - アカウント不明等エラー  : ${fail_count} 件"
    fi
  fi
  echo "=================================================="
  echo -e " ${C_BOLD}👉 本番実行を行うには、--dry-run を外して実行してください:${C_RESET}"
  echo "    ORG_NAME=\"$ORG\" ./invite_and_assign.sh"
  echo "=================================================="
else
  echo -e "${C_BOLD} 処理結果サマリー (対象: ${total_users} 名)${C_RESET}"
  echo "=================================================="
  echo " [Organization]"
  echo "   - 招待送信完了            : ${org_newly_invited} 名"
  echo "   - 参加済み (スキップ)     : ${org_already_member} 名"
  echo "   - 招待済み (スキップ)     : ${org_already_invited} 名"
  echo " [チーム]"
  echo "   - 新規追加完了            : ${team_newly_assigned} 名"
  echo "   - 新規チーム作成          : ${team_newly_created} チーム"
  echo "   - 所属済み (スキップ)     : ${team_already_member} 名"
  if [ "$skip_count" -gt 0 ] || [ "$fail_count" -gt 0 ]; then
    echo " [エラー・スキップ]"
    if [ "$skip_count" -gt 0 ]; then
      echo "   - スキップ               : ${skip_count} 件"
    fi
    if [ "$fail_count" -gt 0 ]; then
      echo "   - エラー/失敗            : ${fail_count} 件"
    fi
  fi
  echo "=================================================="
fi

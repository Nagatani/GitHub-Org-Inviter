#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# 設定項目
# ==============================================================================
# 招待先の GitHub Organization 名 (環境変数 ORG_NAME でも上書き可能)
ORG="${ORG_NAME:-YOUR_ORGANIZATION_NAME}"

# 対象のCSVファイルパス (環境変数 CSV_PATH でも上書き可能)
CSV_FILE="${CSV_PATH:-students.csv}"

# Organization招待時のロール ("member" または "admin")
ROLE="member"

# チームが存在しない場合に自動で作成するかどうか (true / false)
AUTO_CREATE_TEAM=true

# チーム新規作成時の公開設定 ("closed": 組織全員に表示, "secret": メンバーのみに表示)
TEAM_PRIVACY="closed"

# APIリクエスト間の待機時間 (秒) - レートリミット回避用
SLEEP_INTERVAL=0.5

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
      echo "  --dry-run   実際にAPIによる変更を行わず、チェックとシミュレーションのみ実行します"
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
  echo "【エラー】スクリプト内の ORG を設定するか、ORG_NAME環境変数を指定してください。" >&2
  echo "例: ORG_NAME=my-org $0" >&2
  exit 1
fi

if [ ! -f "$CSV_FILE" ]; then
  echo "【エラー】CSVファイル '$CSV_FILE' が見つかりません。" >&2
  exit 1
fi

echo "=================================================="
echo " GitHub Organization & チーム一括招待スクリプト"
echo "=================================================="
echo " Organization : $ORG"
echo " CSVファイル  : $CSV_FILE"
echo " チーム自動作成: $AUTO_CREATE_TEAM"
if [ "$DRY_RUN" = true ]; then
  echo " 実行モード   : 【DRY-RUN (シミュレーション)】※変更は行われません"
else
  echo " 実行モード   : 【本番実行】"
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

  # 前後の空白・改行・引用符 (ダブルクォート) を除去
  username=$(echo "$raw_username" | tr -d '\r\n ' | sed 's/^"//;s/"$//')
  team=$(echo "${raw_team:-}" | tr -d '\r\n ' | sed 's/^"//;s/"$//')

  # ヘッダー行 (username等) や空行、コメント行 (#) をスキップ
  if [[ -z "$username" || "$username" =~ ^(#|username|github) ]]; then
    continue
  fi

  ((total_users++))
  echo "--------------------------------------------------"
  echo "[${line_number}行目] ユーザー: $username"

  # 1. GitHub上にユーザーが存在するかチェック
  if ! gh api "users/$username" --silent 2>/dev/null; then
    echo "  [エラー] GitHubアカウント '$username' が存在しません (ユーザー名の誤字の可能性)。"
    ((fail_count++))
    continue
  fi

  # 2. Organizationの現在の所属状態をチェック
  org_status="none"
  if membership_info=$(gh api "orgs/$ORG/memberships/$username" 2>/dev/null); then
    org_status=$(echo "$membership_info" | gh json '.state' 2>/dev/null || echo "unknown")
  fi

  if [ "$org_status" = "active" ]; then
    echo "  - Organization : [参加済み] 既にOrganizationのメンバーです。"
    ((org_already_member++))
  elif [ "$org_status" = "pending" ]; then
    echo "  - Organization : [招待済み] 既に招待状を送信済みです (承認待ち)。"
    ((org_already_invited++))
  else
    if [ "$DRY_RUN" = true ]; then
      echo "  - Organization : [要・招待] (DRY-RUN: ロール '$ROLE' で招待対象)"
      ((org_newly_invited++))
    else
      echo -n "  - Organization : 招待を送信中... "
      if gh api --method PUT \
        -H "Accept: application/vnd.github+json" \
        "/orgs/$ORG/memberships/$username" \
        -f role="$ROLE" --silent 2>/dev/null; then
        echo "[招待完了] 招待状を送信しました。"
        ((org_newly_invited++))
      else
        echo "[失敗] 招待の送信に失敗しました。"
        ((fail_count++))
        continue
      fi
    fi
  fi

  # 3. チームへの所属処理 (チーム指定がある場合)
  if [ -n "$team" ]; then
    # チームの存在確認
    if ! gh api "orgs/$ORG/teams/$team" --silent 2>/dev/null; then
      if [ "$AUTO_CREATE_TEAM" = true ]; then
        if [ "$DRY_RUN" = true ]; then
          echo "  - チーム作成   : [要・作成] チーム '$team' が未作成のため、新規作成対象です。"
          ((team_newly_created++))
        else
          echo -n "  - チーム作成   : チーム '$team' を新規作成中... "
          if gh api --method POST \
            -H "Accept: application/vnd.github+json" \
            "/orgs/$ORG/teams" \
            -f name="$team" \
            -f privacy="$TEAM_PRIVACY" --silent 2>/dev/null; then
            echo "[作成完了]"
            ((team_newly_created++))
          else
            echo "[作成失敗] (権限等を確認してください)"
            ((fail_count++))
            continue
          fi
        fi
      else
        echo "  - チーム作成   : [スキップ] チーム '$team' は存在しません (AUTO_CREATE_TEAM=false)。"
        ((skip_count++))
        continue
      fi
    fi

    # チームの所属状態チェック
    team_status="none"
    if team_membership_info=$(gh api "orgs/$ORG/teams/$team/memberships/$username" 2>/dev/null); then
      team_status=$(echo "$team_membership_info" | gh json '.state' 2>/dev/null || echo "unknown")
    fi

    if [ "$team_status" = "active" ]; then
      echo "  - チーム($team) : [所属済み] 既にこのチームのメンバーです。"
      ((team_already_member++))
    elif [ "$team_status" = "pending" ]; then
      echo "  - チーム($team) : [招待済み] 既にチームへの参加が承認待ちです。"
      ((team_already_invited++))
    else
      if [ "$DRY_RUN" = true ]; then
        echo "  - チーム($team) : [要・追加] (DRY-RUN: チームに追加対象)"
        ((team_newly_assigned++))
      else
        echo -n "  - チーム($team) : チームに追加中... "
        if gh api --method PUT \
          -H "Accept: application/vnd.github+json" \
          "/orgs/$ORG/teams/$team/memberships/$username" \
          -f role="member" --silent 2>/dev/null; then
          echo "[追加完了]"
          ((team_newly_assigned++))
        else
          echo "[失敗]"
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
echo " 処理サマリー (対象: ${total_users} 名)"
echo "=================================================="
echo " [Organization]"
echo "   - 参加済み (既存)        : ${org_already_member} 名"
echo "   - 招待済み (承認待ち)    : ${org_already_invited} 名"
if [ "$DRY_RUN" = true ]; then
  echo "   - 新規招待 (要・送信)    : ${org_newly_invited} 名"
else
  echo "   - 新規招待 (送信完了)    : ${org_newly_invited} 名"
fi
echo " [チーム]"
echo "   - 所属済み (既存)        : ${team_already_member} 名"
if [ "$team_already_invited" -gt 0 ]; then
  echo "   - 招待済み (承認待ち)    : ${team_already_invited} 名"
fi
if [ "$DRY_RUN" = true ]; then
  echo "   - 新規追加 (要・追加)    : ${team_newly_assigned} 名"
  echo "   - 新規作成 (要・作成)    : ${team_newly_created} チーム"
else
  echo "   - 新規追加 (追加完了)    : ${team_newly_assigned} 名"
  echo "   - 新規作成 (作成完了)    : ${team_newly_created} チーム"
fi
if [ "$skip_count" -gt 0 ] || [ "$fail_count" -gt 0 ]; then
  echo " [その他]"
  if [ "$skip_count" -gt 0 ]; then
    echo "   - スキップ               : ${skip_count} 件"
  fi
  if [ "$fail_count" -gt 0 ]; then
    echo "   - エラー/失敗            : ${fail_count} 件"
  fi
fi
echo "=================================================="

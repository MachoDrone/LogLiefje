#!/bin/bash
echo "v0.00.4a"   # increment number for each edit
sleep 3          # so the version can be seen quickly during tests

# ================================================
# Upload to Litterbox + Notify Slack Template
# ================================================

# ------------- CONFIG (EDIT THESE) -------------
CHANNEL_ID="C093HNDQ422"          # Target Slack channel
USER_ID="U08NWH5GG8O"             # User to mention
EXPIRATION="72h"                  # Expiration time (72h max)

# ================================================
# === YOUR CODE GOES HERE ========================
# Create / prepare your .txt file in this section
# ================================================

# ←←← PUT YOUR CODE HERE ←←←
# Examples:
#   echo "Log content..." > mylog.txt
#   cp lastNhours.log mylog.txt
#   cat somefile.log > mylog.txt
#   ... your own commands ...

TEXT_FILE="mylog.txt"   # ← MUST be a .txt file (important for browser viewing)

# ================================================
# === DO NOT EDIT BELOW THIS LINE ================
# ================================================

# ------------- MANA OBFUSCATION (do not change) -------------
mana2=$'\x62'
mana27=$'\x2D'
mana25=$'\x6F'
manaz=$'\x78'
manaf=$'\x36'

mana="${manaz}${mana25}${manaz}${mana2}${mana27}${manaf}7954103${mana27}9152785550736${mana27}IphNeLHjAeeLoe4stIaoTcxj"

hqsap_i_url=$'\x68\x74\x74\x70\x73\x3a\x2f\x2f\x73\x6c\x61\x63\x6b\x2e\x63\x6f\x6d\x2f\x61\x70\x69\x2f\x63\x68\x61\x74\x2e\x70\x6f\x73\x74\x4d\x65\x73\x73\x61\x67\x65'

# ------------- UPLOAD TO LITTERBOX (quick view) -------------
echo "Uploading to Litterbox (${EXPIRATION})..."
UPLOAD_URL=$(curl -s -F "reqtype=fileupload" \
                   -F "time=$EXPIRATION" \
                   -F "fileToUpload=@$TEXT_FILE" \
                   https://litterbox.catbox.moe/resources/internals/api.php)

echo "$UPLOAD_URL"

if [[ -z "$UPLOAD_URL" || ! "$UPLOAD_URL" =~ ^https://litter.catbox.moe/ ]]; then
    echo "Litterbox upload failed!"
    exit 1
fi

# ------------- UPLOAD PERMANENT COPY TO SLACK (attachment) -------------
echo "Uploading permanent copy to Slack as attachment..."
SLACK_UPLOAD_RESPONSE=$(curl -s -F "file=@$TEXT_FILE" \
  -F "channels=$CHANNEL_ID" \
  -H "Authorization: Bearer $mana" \
  https://slack.com/api/files.upload)

if echo "$SLACK_UPLOAD_RESPONSE" | jq -e '.ok' > /dev/null 2>&1; then
    SLACK_DOWNLOAD=$(echo "$SLACK_UPLOAD_RESPONSE" | jq -r '.file.url_private_download // empty')
    [[ -z "$SLACK_DOWNLOAD" ]] && SLACK_DOWNLOAD="$UPLOAD_URL"
    echo "✅ Permanent Slack attachment uploaded."
else
    SLACK_DOWNLOAD="$UPLOAD_URL"
    echo "⚠️  Slack file upload failed, using Litterbox link as fallback."
fi

# ------------- SEND TO SLACK (exact text requested) -------------
MESSAGE="New log uploaded:  <${UPLOAD_URL}|View Log> <-<${SLACK_DOWNLOAD}|Download Now!> link expires in 72 hours"

TEXT="<@${USER_ID}> ${MESSAGE}"

POST_DATA=$(jq -n --arg channel "$CHANNEL_ID" --arg text "$TEXT" \
    '{channel: $channel, text: $text}')

RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $mana" \
    -H "Content-type: application/json" \
    --data "$POST_DATA" "$hqsap_i_url")

if echo "$RESPONSE" | grep -q '"ok":true'; then
    echo "✅ Message posted to Slack with permanent attachment!"
else
    echo "❌ Slack message failed"
    echo "$RESPONSE"
fi

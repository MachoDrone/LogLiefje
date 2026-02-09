#!/bin/bash
echo "v0.00.7"   # increment number for each edit
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

# ------------- UPLOAD TO LITTERBOX -------------
echo "Uploading to Litterbox (${EXPIRATION})..."
UPLOAD_URL=$(curl -s -F "reqtype=fileupload" \
                   -F "time=$EXPIRATION" \
                   -F "fileToUpload=@$TEXT_FILE" \
                   https://litterbox.catbox.moe/resources/internals/api.php)

echo "$UPLOAD_URL"

if [[ -z "$UPLOAD_URL" || ! "$UPLOAD_URL" =~ ^https://litter.catbox.moe/ ]]; then
    echo "Upload failed!"
    exit 1
fi

# ------------- TRY TO UPLOAD TO SLACK AS PERMANENT ATTACHMENT -------------
echo "Uploading file to Slack as permanent attachment..."
INITIAL_COMMENT="<@${USER_ID}> New log uploaded:  <${UPLOAD_URL}|View Log> <-Download Now! link expires in 72 hours>"

SLACK_RESPONSE=$(curl -s -F file=@"$TEXT_FILE" \
  -F channels="$CHANNEL_ID" \
  -F filename="$(basename "$TEXT_FILE")" \
  -F title="Log file - $(date '+%Y-%m-%d %H:%M:%S')" \
  -F initial_comment="$INITIAL_COMMENT" \
  -H "Authorization: Bearer $mana" \
  https://slack.com/api/files.upload )

if echo "$SLACK_RESPONSE" | grep -q '"ok":true'; then
    echo "✅ File uploaded to Slack as permanent attachment!"
else
    echo "⚠️  Slack file upload failed (falling back to normal message)"
    echo "Debug response: $SLACK_RESPONSE"
    
    # Fallback: post normal message with link
    MESSAGE="New log uploaded:  <${UPLOAD_URL}|View Log> <-Download Now! link expires in 72 hours>"
    TEXT="<@${USER_ID}> ${MESSAGE}"
    POST_DATA=$(jq -n --arg channel "$CHANNEL_ID" --arg text "$TEXT" '{channel: $channel, text: $text}')
    
    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer $mana" \
        -H "Content-type: application/json" \
        --data "$POST_DATA" \
        https://slack.com/api/chat.postMessage)
    
    if echo "$RESPONSE" | grep -q '"ok":true'; then
        echo "✅ Fallback message posted successfully"
    else
        echo "❌ Fallback also failed"
        echo "$RESPONSE"
    fi
fi

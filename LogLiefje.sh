#!/bin/bash
echo "v0.00.13"   # ← incremented
sleep 3

# ================================================
# Upload to Litterbox + Notify Slack Template
# ================================================

# ------------- CONFIG (EDIT THESE) -------------
CHANNEL_ID="C093HNDQ422"
USER_ID="U08NWH5GG8O"
EXPIRATION="72h"

# ================================================
# === YOUR CODE GOES HERE ========================
# Create / prepare your .txt file in this section
# ================================================

# ←←← PUT YOUR CODE HERE ←←←
# Examples:
#   echo "Log content..." > mylog.txt
#   cp lastNhours.log mylog.txt
#   cat somefile.log > mylog.txt

TEXT_FILE="mylog.txt"   # ← must exist

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

# ------------- UPLOAD TO SLACK (permanent) -------------
echo "Uploading to Slack (permanent attachment)..."

if [[ ! -f "$TEXT_FILE" ]]; then
    echo "Error: $TEXT_FILE not found!"
    exit 1
fi
LENGTH=$(wc -c < "$TEXT_FILE")
echo "File size: $LENGTH bytes"

# Step 1: Get upload URL + tell Slack it's a text file
GET_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $mana" \
  -F "filename=$(basename "$TEXT_FILE")" \
  -F "length=$LENGTH" \
  -F "snippet_type=text" \
  https://slack.com/api/files.getUploadURLExternal)

UPLOAD_URL_SLACK=$(echo "$GET_RESPONSE" | jq -r '.upload_url // empty')
FILE_ID=$(echo "$GET_RESPONSE" | jq -r '.file_id // empty')

if [[ -z "$UPLOAD_URL_SLACK" || -z "$FILE_ID" ]]; then
    echo "Failed to get Slack upload URL"
    echo "$GET_RESPONSE"
    exit 1
fi

echo "Got upload_url and file_id"

# Step 2: Upload with explicit text/plain type
curl -s -H "Content-Type: text/plain" -T "$TEXT_FILE" "$UPLOAD_URL_SLACK" > /dev/null

# Step 3: Complete upload (no channel needed)
COMPLETE_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $mana" \
  -H "Content-type: application/json; charset=utf-8" \
  --data "{\"files\":[{\"id\":\"$FILE_ID\",\"title\":\"$(basename "$TEXT_FILE")\"}]}" \
  https://slack.com/api/files.completeUploadExternal)

SLACK_PERMALINK=$(echo "$COMPLETE_RESPONSE" | jq -r '.files[0].permalink // "not_found"')

# Post notification
echo "Posting notification message..."
MESSAGE_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $mana" \
  -H "Content-type: application/json; charset=utf-8" \
  --data "{\"channel\":\"$CHANNEL_ID\",\"text\":\"<@${USER_ID}> New log uploaded\n\nLitterbox (72h): ${UPLOAD_URL}\nSlack permanent: ${SLACK_PERMALINK}\"}" \
  https://slack.com/api/chat.postMessage)

echo "Message response:"
echo "$MESSAGE_RESPONSE"
echo "Slack permanent link: $SLACK_PERMALINK"
echo "✅ Done! Check the new message in Slack."

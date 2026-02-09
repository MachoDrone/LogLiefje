#!/bin/bash
echo "v0.00.9"   # ← incremented
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

# Safety check + debug
if [[ ! -f "$TEXT_FILE" ]]; then
    echo "Error: $TEXT_FILE not found!"
    exit 1
fi
LENGTH=$(wc -c < "$TEXT_FILE")
echo "File size: $LENGTH bytes"

# Step 1: Get upload URL (using form data - this is the reliable way in bash)
GET_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $mana" \
  -F "filename=$(basename "$TEXT_FILE")" \
  -F "length=$LENGTH" \
  https://slack.com/api/files.getUploadURLExternal)

UPLOAD_URL_SLACK=$(echo "$GET_RESPONSE" | jq -r '.upload_url // empty')
FILE_ID=$(echo "$GET_RESPONSE" | jq -r '.file_id // empty')

if [[ -z "$UPLOAD_URL_SLACK" || -z "$FILE_ID" ]]; then
    echo "Failed to get Slack upload URL"
    echo "Response was:"
    echo "$GET_RESPONSE"
    exit 1
fi

echo "Got upload_url and file_id"

# Step 2: PUT the file to the temporary URL
curl -s -T "$TEXT_FILE" "$UPLOAD_URL_SLACK" > /dev/null

# Step 3: Complete the upload
INITIAL_COMMENT="<@${USER_ID}> New log uploaded:  <${UPLOAD_URL}|View Log> <-Download Now! link expires in 72 hours>"

COMPLETE_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $mana" \
  -H "Content-type: application/json" \
  --data "{\"files\":[{\"id\":\"$FILE_ID\"}],\"channel_id\":\"$CHANNEL_ID\",\"initial_comment\":\"$INITIAL_COMMENT\"}" \
  https://slack.com/api/files.completeUploadExternal)

if echo "$COMPLETE_RESPONSE" | grep -q '"ok":true'; then
    echo "✅ Permanent file uploaded to Slack!"
else
    echo "❌ Slack upload failed"
    echo "$COMPLETE_RESPONSE"
fi

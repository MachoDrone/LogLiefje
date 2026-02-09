#!/bin/bash
echo "v0.00.15"   # ← incremented
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

# ------------- PRE-CHECKS -------------
if [[ ! -f "$TEXT_FILE" ]]; then
    echo "Error: $TEXT_FILE not found!"
    exit 1
fi

FILE_SIZE=$(wc -c < "$TEXT_FILE" | tr -d ' ')

# ------------- UPLOAD (with progress bars) -------------
echo "Uploading ($FILE_SIZE bytes)..."

# Litterbox upload — progress bar on stderr, URL captured in stdout
UPLOAD_URL=$(curl -# -F "reqtype=fileupload" \
                   -F "time=$EXPIRATION" \
                   -F "fileToUpload=@$TEXT_FILE" \
                   https://litterbox.catbox.moe/resources/internals/api.php)

if [[ -z "$UPLOAD_URL" || ! "$UPLOAD_URL" =~ ^https://litter.catbox.moe/ ]]; then
    echo "Litterbox upload failed!"
    exit 1
fi

# Slack Step 1: Get upload URL (silent, fast API call)
GET_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $mana" \
  -F "filename=$(basename "$TEXT_FILE")" \
  -F "length=$FILE_SIZE" \
  -F "snippet_type=text" \
  https://slack.com/api/files.getUploadURLExternal)

UPLOAD_URL_SLACK=$(echo "$GET_RESPONSE" | jq -r '.upload_url // empty')
FILE_ID=$(echo "$GET_RESPONSE" | jq -r '.file_id // empty')

if [[ -z "$UPLOAD_URL_SLACK" || -z "$FILE_ID" ]]; then
    echo "Slack upload URL request failed!"
    exit 1
fi

# Slack Step 2: Upload file content — progress bar on stderr
curl -# -X POST \
  -F "file=@$TEXT_FILE" \
  "$UPLOAD_URL_SLACK" > /dev/null

# Slack Step 3: Complete upload and share to channel
COMPLETE_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $mana" \
  -H "Content-type: application/json; charset=utf-8" \
  --data "{
    \"files\": [{\"id\":\"$FILE_ID\",\"title\":\"$(basename "$TEXT_FILE")\"}],
    \"channel_id\": \"$CHANNEL_ID\",
    \"initial_comment\": \"<@${USER_ID}> New log uploaded\n\n(link expires in ${EXPIRATION}): ${UPLOAD_URL}\"
  }" \
  https://slack.com/api/files.completeUploadExternal)

SLACK_OK=$(echo "$COMPLETE_RESPONSE" | jq -r '.ok // "false"')
SLACK_PERMALINK=$(echo "$COMPLETE_RESPONSE" | jq -r '.files[0].permalink // empty')

# ------------- VERIFY LINKS -------------
printf "Verifying... "
ERRORS=""

# Confirm Litterbox link returns HTTP 200
LB_HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$UPLOAD_URL")
if [[ "$LB_HTTP" != "200" ]]; then
    ERRORS="${ERRORS}  Litterbox: HTTP $LB_HTTP (expected 200)\n"
fi

# Confirm Slack upload succeeded and permalink exists
if [[ "$SLACK_OK" != "true" ]]; then
    ERRORS="${ERRORS}  Slack: upload not confirmed\n"
elif [[ -z "$SLACK_PERMALINK" ]]; then
    ERRORS="${ERRORS}  Slack: no permalink returned\n"
fi

if [[ -z "$ERRORS" ]]; then
    echo "OK"
else
    echo "FAILED"
    echo -e "$ERRORS"
fi

echo "Done!"

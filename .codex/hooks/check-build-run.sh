#!/bin/bash
# Sets a flag when the user ends their prompt with "build and run".
# The stop hook (xcode-run.sh) reads this flag before triggering Cmd+R.

input=$(cat)
prompt=$(echo "$input" | jq -r '.prompt // empty')
generation_id=$(echo "$input" | jq -r '.generation_id // empty')
flag_file=".cursor/.xcode-build-run-pending"

trimmed=$(echo "$prompt" | sed 's/[[:space:]]*$//')

if echo "$trimmed" | grep -qiE 'build and run[[:space:]]*$'; then
  echo "$generation_id" > "$flag_file"
else
  rm -f "$flag_file"
fi

echo '{"continue": true}'
exit 0

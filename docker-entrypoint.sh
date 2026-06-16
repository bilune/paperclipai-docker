#!/bin/sh
set -e

# Match container user UID/GID to host for volume permissions
PUID=${USER_UID:-1000}
PGID=${USER_GID:-1000}

changed=0

if [ "$(id -u node)" -ne "$PUID" ]; then
    echo "Updating node UID to $PUID"
    usermod -o -u "$PUID" node
    changed=1
fi

if [ "$(id -g node)" -ne "$PGID" ]; then
    echo "Updating node GID to $PGID"
    groupmod -o -g "$PGID" node
    usermod -g "$PGID" node
    changed=1
fi

# Always ensure /paperclip is owned by node (first run or after UID/GID change)
chown -R node:node /paperclip

# --- Aerolab: git auth (GitHub App) + workspace auto-clone (runs as node) ---
gosu node sh -s <<'AEROLAB_SETUP'
set -e
export HOME=/paperclip

# 1) GitHub App credential helper (mints a fresh installation token per git op)
if [ -n "$GH_APP_ID" ] && [ -n "$GH_APP_KEY_B64" ] && [ -n "$GH_APP_INSTALLATION_ID" ]; then
  mkdir -p /paperclip/bin
  cat > /paperclip/bin/git-credential-aerolab <<'EOF'
#!/usr/bin/env node
const crypto = require('crypto');
const appId = Number(process.env.GH_APP_ID);
const pem = Buffer.from(process.env.GH_APP_KEY_B64, 'base64').toString('utf8');
const inst = process.env.GH_APP_INSTALLATION_ID;
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const now = Math.floor(Date.now()/1000);
const data = b64({alg:'RS256',typ:'JWT'}) + '.' + b64({iat:now-60, exp:now+540, iss:appId});
const sig = crypto.sign('RSA-SHA256', Buffer.from(data), pem).toString('base64url');
const jwt = data + '.' + sig;
fetch(`https://api.github.com/app/installations/${inst}/access_tokens`, {
  method:'POST',
  headers:{Authorization:'Bearer '+jwt, Accept:'application/vnd.github+json', 'User-Agent':'aerolab-ai'}
}).then(r=>r.json()).then(j=>{
  if(!j.token){ process.stderr.write('no token: '+JSON.stringify(j)); process.exit(1); }
  process.stdout.write(`username=x-access-token\npassword=${j.token}\n`);
}).catch(e=>{ process.stderr.write(String(e)); process.exit(1); });
EOF
  chmod +x /paperclip/bin/git-credential-aerolab
  git config --global credential.helper /paperclip/bin/git-credential-aerolab
  git config --global user.name "${GIT_AUTHOR_NAME:-Aerolab AI}"
  git config --global user.email "${GIT_AUTHOR_EMAIL:-294312903+aerolab-ai[bot]@users.noreply.github.com}"
  git config --global --add safe.directory '*'
  git config --global init.defaultBranch main
  echo "aerolab: git auth configured (aerolab-ai[bot])"
fi

# 2) Auto-clone configured repos into the workspace (idempotent)
if [ -n "$WORKSPACE_REPOS" ]; then
  mkdir -p /paperclip/workspace
  echo "$WORKSPACE_REPOS" | tr ',' '\n' | while IFS= read -r repo; do
    repo=$(echo "$repo" | tr -d '[:space:]')
    [ -z "$repo" ] && continue
    name=$(basename "$repo")
    dest="/paperclip/workspace/$name"
    if [ -d "$dest/.git" ]; then
      echo "aerolab: workspace '$name' already present, skip"
    else
      echo "aerolab: cloning $repo -> $dest"
      git clone "https://github.com/$repo" "$dest" || echo "aerolab: FAILED to clone $repo"
    fi
  done
fi
AEROLAB_SETUP
# --- end Aerolab block ---

exec gosu node "$@"

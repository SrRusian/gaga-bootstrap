#!/usr/bin/env bash
# GAGA Platform server setup. As root on Ubuntu 24.04:  bash bootstrap.sh  (menu) or one step: full | system | repo | perms | deploy | admin | ssh | reset
# "full" runs protected (Ctrl+C ignored, inside tmux) and resumes where it stopped; "reset" undoes an unfinished one.
# The same by hand is at the end.
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-gaga-deploy}"
DEPLOY_DIR="${DEPLOY_DIR:-/srv/gaga-platform}"
SHARED_GROUP="${SHARED_GROUP:-gaga}"
TIER2_GROUP="${TIER2_GROUP:-gaga-t2}"
TIER3_GROUP="${TIER3_GROUP:-gaga-t3}"
MENU_SCRIPT="$DEPLOY_DIR/manage.sh"
REPO_URL_DEFAULT="${REPO_URL:-git@github.com:SrRusian/gaga-platform.git}"
# the branch to download is asked in the repository step (empty = the default branch, main); REPO_BRANCH presets it
REPO_BRANCH="${REPO_BRANCH:-}"
STATE_DIR=/var/lib/gaga-bootstrap
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
KEY_REGEX='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+) [A-Za-z0-9+/=]+( .*)?$'

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
. /etc/os-release
[ "$ID" = "ubuntu" ] || echo "WARNING: made for Ubuntu, this is $PRETTY_NAME."
install -d -m 755 "$STATE_DIR"

say() { printf '\n== %s\n' "$*"; }
cancel_run() { echo; echo "Cancelled on purpose. Run the full installation again to resume where it stopped."; exit 130; }
ask() { local __var="$1" __reply; printf '%s ' "$2"; read -r __reply || __reply=""; [ "$__reply" != cancel ] || cancel_run; printf -v "$__var" '%s' "${__reply:-${3:-}}"; }
yes() { local reply; printf '%s (si/no) ' "$1"; read -r reply || reply=""; [ "$reply" != cancel ] || cancel_run; [[ "$reply" =~ ^(si|s|yes|y)$ ]]; }
wait_for() { yes "$1" || { echo "Stopped. Run the full installation again to resume here."; exit 1; }; }

done_step() { grep -qx "$1" "$STATE_DIR/progress" 2>/dev/null; }
run_step() { if done_step "$1"; then echo "[skip] $1 was already done"; else "$2"; echo "$1" >>"$STATE_DIR/progress"; fi; }

ask_valid() { # ask_valid VAR "prompt" "regex" "what is wrong"
  local tries=0
  while [ "$tries" -lt 3 ]; do
    ask "$1" "$2"
    [[ "${!1}" =~ $3 ]] && return 0
    echo "  $4"
    tries=$((tries + 1))
  done
  echo "Too many wrong answers, stopping."
  exit 1
}

# a real public key (the regex alone accepts nonsense in the middle)
valid_key() {
  local tmp ok=1
  [[ "$1" =~ $KEY_REGEX ]] || return 1
  tmp="$(mktemp)"
  printf '%s
' "$1" >"$tmp"
  ssh-keygen -l -f "$tmp" >/dev/null 2>&1 && ok=0
  rm -f "$tmp"
  return "$ok"
}

server_ip() { { ip -4 route get 1.1.1.1 2>/dev/null || true; } | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1) }'; }

step_system() {
  say "System and Docker"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y dist-upgrade
  apt-get install -y ca-certificates curl git unattended-upgrades
  [ -f "$STATE_DIR/prev-timezone" ] || timedatectl show -p Timezone --value >"$STATE_DIR/prev-timezone" 2>/dev/null || true
  timedatectl set-timezone America/Mexico_City || echo "WARNING: could not set the time zone America/Mexico_City"
  if ! command -v docker >/dev/null 2>&1; then
    touch "$STATE_DIR/installed-docker"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
      >/etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  docker --version
  docker compose version
}

# deploy account: key login only, own read-only git key
ensure_deploy_account() {
  groupadd -f "$SHARED_GROUP"
  id "$DEPLOY_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "GAGA automatic deploy" "$DEPLOY_USER"
  usermod -aG "docker,$SHARED_GROUP" "$DEPLOY_USER"
  DEPLOY_HOME="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
  SSH_DIR="$DEPLOY_HOME/.ssh"
  GIT_KEY="$SSH_DIR/id_gaga_git"
  install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$SSH_DIR"
  [ -f "$GIT_KEY" ] || sudo -u "$DEPLOY_USER" ssh-keygen -q -t ed25519 -N "" -C "$DEPLOY_USER@$(hostname)" -f "$GIT_KEY"
  printf 'Host github.com\n  IdentityFile %s\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n' "$GIT_KEY" >"$SSH_DIR/config"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$SSH_DIR/config"
  chmod 600 "$SSH_DIR/config"
}

# /srv is root's and the group edits it; the .env stays group-only
fix_perms() {
  local top
  groupadd -f "$SHARED_GROUP"
  install -d -m 2775 -o root -g "$SHARED_GROUP" "$DEPLOY_DIR"
  for top in /srv "$DEPLOY_DIR"; do
    chown -R "root:$SHARED_GROUP" "$top"
    chmod -R g+rwX "$top"
    find "$top" -type d -exec chmod g+s {} +
  done
  chmod 2775 /srv
  if [ ! -f "$DEPLOY_DIR/deploy/cloud/.env" ] && [ -f "$DEPLOY_DIR/deploy/cloud/.env.example" ]; then
    cp "$DEPLOY_DIR/deploy/cloud/.env.example" "$DEPLOY_DIR/deploy/cloud/.env"
    echo "Created $DEPLOY_DIR/deploy/cloud/.env from its .env.example: fill in its values later (nano $DEPLOY_DIR/deploy/cloud/.env)."
  fi
  [ ! -f "$DEPLOY_DIR/deploy/cloud/.env" ] || { chown "root:$SHARED_GROUP" "$DEPLOY_DIR/deploy/cloud/.env"; chmod 660 "$DEPLOY_DIR/deploy/cloud/.env"; }
  git config --system --get-all safe.directory | grep -qxF "$DEPLOY_DIR" || git config --system --add safe.directory "$DEPLOY_DIR"
}

step_repo() {
  say "Repository access and clone"
  ensure_deploy_account
  echo "Add this key in GitHub: repo, Settings, Deploy keys, Add deploy key (leave 'Allow write access' OFF):"
  echo
  cat "$GIT_KEY.pub"
  echo
  wait_for "Did you add the key in GitHub?"
  ask REPO_URL "Repository (ssh address):" "$REPO_URL_DEFAULT"
  ask REPO_BRANCH "Branch to download (empty = main):" "$REPO_BRANCH"
  local ssh_cmd="ssh -i $GIT_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  until GIT_SSH_COMMAND="$ssh_cmd" git ls-remote "$REPO_URL" HEAD >/dev/null; do
    echo "GitHub did not accept the key for $REPO_URL (check the repository address and that the key was added there)."
    wait_for "Try again?"
  done
  if [ -d "$DEPLOY_DIR/.git" ]; then
    echo "The code is already in $DEPLOY_DIR, nothing to clone."
  else
    install -d -m 2775 -o root -g "$SHARED_GROUP" "$DEPLOY_DIR"
    GIT_SSH_COMMAND="$ssh_cmd" sh -c 'umask 002; git clone ${3:+-b "$3"} "$1" "$2"' _ "$REPO_URL" "$DEPLOY_DIR" "$REPO_BRANCH"
  fi
  fix_perms
}

step_perms() {
  say "Shared permissions on /srv (and the .env of $DEPLOY_DIR)"
  ensure_deploy_account
  fix_perms
  ls -ld "$DEPLOY_DIR"
  [ ! -f "$DEPLOY_DIR/deploy/cloud/.env" ] || ls -l "$DEPLOY_DIR/deploy/cloud/.env"
}

step_deploy() {
  say "Deploy account for GitHub Actions: $DEPLOY_USER"
  ensure_deploy_account
  echo "GitHub Actions needs its own SSH key pair. On YOUR PC (PowerShell or terminal), if you do not have it yet:"
  echo "    ssh-keygen -t ed25519 -f gaga_actions -C gaga-actions        (Enter twice: no passphrase)"
  echo "    then show the public part:  Get-Content gaga_actions.pub     (or: cat gaga_actions.pub)"
  local actions_key blob
  ask_valid actions_key "Paste the PUBLIC key (gaga_actions.pub, one line):" "$KEY_REGEX" "That is not a public SSH key (it starts with ssh-ed25519)."
  blob="$(awk '{ print $2 }' <<<"$actions_key")"
  { grep -vF "$blob" "$SSH_DIR/authorized_keys" 2>/dev/null || true
    echo "restrict,command=\"bash $DEPLOY_DIR/deploy/server/deploy.sh\" $actions_key"; } >"$SSH_DIR/authorized_keys.new"
  mv "$SSH_DIR/authorized_keys.new" "$SSH_DIR/authorized_keys"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$SSH_DIR/authorized_keys"
  chmod 600 "$SSH_DIR/authorized_keys"
  for file in /home/*/.ssh/authorized_keys; do # an older setup may have put the same key on another account
    [ "$file" = "$SSH_DIR/authorized_keys" ] || ! grep -qF "$blob" "$file" 2>/dev/null || sed -i "\|$blob|d" "$file"
  done
  local ip
  ip="$(server_ip)"
  echo
  echo "Add these in GitHub: repo, Settings, Secrets and variables, Actions, New repository secret:"
  echo "  DEPLOY_HOST         $ip"
  echo "  DEPLOY_USER         $DEPLOY_USER"
  echo "  DEPLOY_KNOWN_HOSTS  $ip $(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || echo '<run: ssh-keyscan -t ed25519 '"$ip"'>')"
  echo "  DEPLOY_SSH_KEY      on your PC run  Get-Content gaga_actions -Raw  (or: cat gaga_actions) and paste ALL of it, BEGIN and END lines included"
  echo "  TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID_PROD, TELEGRAM_CHAT_ID_DEV   for the notifications (docs/deployment.md)"
  echo
  wait_for "Did you add the secrets in GitHub?"
  echo "Checking what this server can check:"
  sudo -u "$DEPLOY_USER" docker ps >/dev/null && echo "  [ok] $DEPLOY_USER runs docker" || echo "  [FAIL] $DEPLOY_USER cannot run docker"
  grep -q "command=\"bash $DEPLOY_DIR/deploy/server/deploy.sh\"" "$SSH_DIR/authorized_keys" && echo "  [ok] Actions key limited to deploy.sh" || echo "  [FAIL] key line missing"
  if [ -d "$DEPLOY_DIR/.git" ]; then
    sudo -u "$DEPLOY_USER" git -C "$DEPLOY_DIR" fetch --quiet origin "${REPO_BRANCH:-main}" && echo "  [ok] $DEPLOY_USER can fetch the repository" || echo "  [FAIL] $DEPLOY_USER cannot fetch (is the deploy key added in GitHub?)"
  else
    echo "  [skip] the code is not cloned yet (run the 'repo' step)"
  fi
  echo "The rest is checked from GitHub: Actions, Deploy, Run workflow with mode = check."
}

# Access tiers (see manage.sh): 1 = full (sudo), 2 and 3 only run the server menu through sudo. They are not in the group
# that edits the repository, so the menu script they run as root is not theirs to change.
install_tier_rules() {
  local kind="$1" tmp
  groupadd -f "$TIER2_GROUP"
  groupadd -f "$TIER3_GROUP"
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
Cmnd_Alias GAGA_MENU = /usr/bin/bash $MENU_SCRIPT, /usr/bin/bash $MENU_SCRIPT cloud, /usr/bin/bash $MENU_SCRIPT local
%$TIER2_GROUP ALL=(root) GAGA_MENU
%$TIER3_GROUP ALL=(root) NOPASSWD: GAGA_MENU
EOF
  visudo -cf "$tmp" >/dev/null || { echo "The sudo rules did not pass visudo, nothing was changed."; rm -f "$tmp"; exit 1; }
  install -m 440 -o root -g root "$tmp" /etc/sudoers.d/91-gaga-tiers
  rm -f "$tmp" /etc/sudoers.d/90-gaga-staff
  # tier 3 lands straight in the menu (no shell); passwords are allowed for it only on a local server
  tmp="$(mktemp)"
  {
    echo "Match Group $TIER3_GROUP"
    echo "  ForceCommand /usr/bin/sudo /usr/bin/bash $MENU_SCRIPT"
    echo "  AllowTcpForwarding no"
    echo "  X11Forwarding no"
    echo "  AllowAgentForwarding no"
    echo "  PermitTunnel no"
    [ "$kind" != local ] || echo "  PasswordAuthentication yes"
  } >"$tmp"
  install -d /etc/ssh/sshd_config.d
  install -m 644 -o root -g root "$tmp" /etc/ssh/sshd_config.d/10-gaga-tier3.conf
  rm -f "$tmp"
  sshd -t || { rm -f /etc/ssh/sshd_config.d/10-gaga-tier3.conf; echo "sshd rejected the tier 3 rules, removed."; exit 1; }
  systemctl restart ssh 2>/dev/null || true
}

step_admin() {
  say "New user"
  local owner="" kind tier name user_key="" password home groups label
  [ ! -f "$STATE_DIR/owner" ] || owner="$(cat "$STATE_DIR/owner")"
  if [ ! -s "$STATE_DIR/kind" ]; then
    ask_valid kind "Is this server the cloud or a local one? (cloud/local):" '^(cloud|local)$' "Write cloud or local."
    echo "$kind" >"$STATE_DIR/kind"
  fi
  kind="$(cat "$STATE_DIR/kind")"
  echo "Access tiers:"
  echo "  1) Full: everything, including accounts, clean start and restore (sudo, SSH key)"
  echo "  2) Operate: update, rebuild, restart, logs, back up now. Nothing destructive (SSH key, menu only)"
  echo "  3) Basic: status, logs, restart a service (menu only; password allowed only on a local server)"
  if [ -z "$owner" ]; then
    tier=1
    echo "This is the first user, so it is tier 1 (the owner)."
  else
    ask_valid tier "Tier (1, 2 or 3):" '^[123]$' "Write 1, 2 or 3."
  fi
  ask_valid name "Username (lowercase, digits, - and _):" '^[a-z][a-z0-9_-]{0,31}$' "Not valid."
  id "$name" >/dev/null 2>&1 && { echo "The user '$name' already exists."; exit 1; }
  echo "The person logs in with an SSH key. On THEIR PC: ssh-keygen -t ed25519 -C name@pc  then show the .pub file"
  echo "(Windows: Get-Content \$env:USERPROFILE\\.ssh\\id_ed25519.pub). Never the private file."
  if [ "$tier" = 3 ] && [ "$kind" = local ]; then
    ask user_key "Paste their PUBLIC key (one line), or leave empty to use a password:"
    [ -z "$user_key" ] || valid_key "$user_key" || { echo "That is not a valid public SSH key."; exit 1; }
  else
    local tries=0
    while ! valid_key "$user_key"; do
      tries=$((tries + 1))
      [ "$tries" -le 3 ] || { echo "Too many wrong answers, stopping."; exit 1; }
      ask user_key "Paste their PUBLIC key (one line, starts with ssh-ed25519):"
    done
  fi
  groupadd -f "$SHARED_GROUP"
  adduser --disabled-password --gecos "" "$name"
  case "$tier" in
    1) groups="sudo,$SHARED_GROUP"; label="tier 1" ;;
    2) install_tier_rules "$kind"; groups="$TIER2_GROUP"; label="tier 2" ;;
    3) install_tier_rules "$kind"; groups="$TIER3_GROUP"; label="tier 3" ;;
  esac
  usermod -aG "$groups" "$name"
  home="/home/$name"
  install -d -m 700 -o "$name" -g "$name" "$home/.ssh"
  if [ -n "$user_key" ]; then
    echo "$user_key" >"$home/.ssh/authorized_keys"
    chown "$name:$name" "$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"
  fi
  # a temporary password, forced to change at the first login (tier 3 with a key does not use one)
  password=""
  if [ "$tier" != 3 ] || [ -z "$user_key" ]; then
    password="$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 14)"
    echo "$name:$password" | chpasswd
    chage -d 0 "$name"
  fi
  [ -n "$owner" ] || echo "$name" >"$STATE_DIR/owner"
  echo "$name" >>"$STATE_DIR/admins"
  echo "$name $tier" >>"$STATE_DIR/users"
  echo
  echo "Created '$name' ($label, $kind server). Checks:"
  local member
  member() { id -nG "$name" | tr ' ' '
' | grep -qx "$1"; }
  if [ "$tier" = 1 ]; then
    member "$SHARED_GROUP" && echo "  [ok] in group $SHARED_GROUP (edits $DEPLOY_DIR)" || echo "  [FAIL] group $SHARED_GROUP"
    if sudo -l -U "$name" >/dev/null 2>&1; then echo "  [ok] has sudo"; else echo "  [FAIL] no sudo"; fi
  else
    member "$SHARED_GROUP" && echo "  [FAIL] in group $SHARED_GROUP: could edit the menu script" || echo "  [ok] not in group $SHARED_GROUP"
    { member sudo || member docker; } && echo "  [FAIL] has sudo or docker" || echo "  [ok] no sudo or docker group"
    sudo -l -U "$name" 2>/dev/null | grep -q "manage.sh" && echo "  [ok] may run only the server menu with sudo" || echo "  [FAIL] cannot run the server menu"
  fi
  if [ -s "$home/.ssh/authorized_keys" ]; then echo "  [ok] SSH key installed"; else echo "  [ok] no key: password login (local server)"; fi
  echo
  if [ -n "$password" ]; then
    echo "Temporary password (shown once, hand it over by another channel):  $password"
    echo "At the first login (ssh $name@$(server_ip)) the system asks for it and forces a new one that nobody else knows."
  fi
  [ "$tier" = 1 ] || echo "This person lands in the server menu: sudo bash $MENU_SCRIPT"
}

step_ssh() {
  say "Close root and password login over SSH"
  local owner=""
  [ ! -f "$STATE_DIR/owner" ] || owner="$(cat "$STATE_DIR/owner")"
  [ -n "$owner" ] || { echo "Create an administrator first: without one this would lock you out."; exit 1; }
  echo "Test in ANOTHER window before closing anything:"
  echo "    ssh -i <their key> $owner@$(server_ip)     (it asks for the temporary password and a new one)"
  echo "    sudo whoami                                 (must print root)"
  wait_for "Did $owner log in, change the password and run sudo?"
  sudo -l -U "$owner" >/dev/null 2>&1 || { echo "$owner has no sudo, not closing root."; exit 1; }
  [ -s "/home/$owner/.ssh/authorized_keys" ] || { echo "$owner has no SSH key, not closing root."; exit 1; }
  install -d /etc/ssh/sshd_config.d
  printf 'PermitRootLogin no\nPasswordAuthentication no\n' >/etc/ssh/sshd_config.d/00-hardening.conf
  sshd -t
  systemctl restart ssh
  sshd -T | grep -E "^(permitrootlogin|passwordauthentication)" || true
  echo "Root and password login are closed."
}

# the public copy this script was started from is no longer needed: the same script is in the repository now
remove_bootstrap_clone() {
  local dir
  dir="$(dirname "$SELF")"
  [ "$dir" != "$DEPLOY_DIR" ] && [ "$dir" != "$DEPLOY_DIR/deploy/server" ] || return 0
  git -C "$dir" remote get-url origin 2>/dev/null | grep -q "gaga-bootstrap" || return 0
  if yes "Delete this copy of the script ($dir)? The same one is in $DEPLOY_DIR/deploy/server."; then
    rm -rf "$dir" && echo "Deleted $dir."
  fi
}

step_full() {
  if [ -f "$STATE_DIR/full-install.done" ]; then
    echo "The full installation was already completed on this server. Use the individual steps, or 'reset' to start from zero."
    exit 1
  fi
  if [ -d "$DEPLOY_DIR/.git" ] && [ ! -f "$STATE_DIR/progress" ]; then
    echo "$DEPLOY_DIR already has code and was not set up by this installer. Use the individual steps, or 'reset' to start from zero."
    exit 1
  fi
  trap '' INT TERM HUP QUIT TSTP
  echo "Protected run: Ctrl+C is ignored and progress is saved, so it resumes if it stops. To stop on purpose type 'cancel' at a question."
  [ ! -s "$STATE_DIR/progress" ] || echo "Resuming. Already done: $(paste -sd' ' "$STATE_DIR/progress")"
  touch "$STATE_DIR/progress"
  run_step system step_system
  run_step repo step_repo
  run_step perms step_perms
  run_step deploy step_deploy
  run_step admin step_admin
  run_step ssh step_ssh
  touch "$STATE_DIR/full-install.done"
  remove_bootstrap_clone
  say "Done"
  echo "Fill in the values of $DEPLOY_DIR/deploy/cloud/.env (any administrator: nano $DEPLOY_DIR/deploy/cloud/.env), with COMPOSE_PROFILES=proxy, BASE_DOMAIN and APP_SUBDOMAIN."
  echo "Then start the application:  sudo bash $DEPLOY_DIR/manage.sh   (first deployment)"
  echo "In DigitalOcean: firewall with 22, 80 and 443 (15432 and 16379 only if you use the remote database access)."
}

# undo the full install
step_reset() {
  say "Reset: undo the full installation"
  if [ -f "$STATE_DIR/full-install.done" ]; then
    echo "The full installation completed correctly, so there is nothing to undo: reset is not available."
    echo "Change what you need with the individual steps."
    exit 1
  fi
  local users=("$DEPLOY_USER") u file stamp
  for file in "$STATE_DIR/admins" "$STATE_DIR/owner"; do
    [ ! -f "$file" ] || while IFS= read -r u; do [ -z "$u" ] || users+=("$u"); done <"$file"
  done
  mapfile -t users < <(printf '%s\n' "${users[@]}" | sort -u)
  for u in "${users[@]}"; do
    [ "${SUDO_USER:-}" != "$u" ] || { echo "You are logged in as '$u', which this would delete. Run it from the root console or another account."; exit 1; }
  done
  echo "This undoes what the full installation did:"
  echo "  - reopens root and password login over SSH (removes the hardening file)"
  echo "  - deletes the accounts: ${users[*]} (with their home folders), the groups $SHARED_GROUP, $TIER2_GROUP and $TIER3_GROUP and their sudo and SSH rules"
  echo "  - stops the containers (docker compose down) and moves $DEPLOY_DIR to $DEPLOY_DIR.removed-<date> (the .env stays there)"
  [ ! -f "$STATE_DIR/installed-docker" ] || echo "  - removes Docker, which the installer put there (only if it has no containers or volumes)"
  [ ! -f "$STATE_DIR/prev-timezone" ] || echo "  - puts the time zone back to $(cat "$STATE_DIR/prev-timezone")"
  [ ! -f "$STATE_DIR/installed-tmux" ] || echo "  - removes tmux, installed for the protected run"
  echo "  - forgets the saved progress, so the full installation can run again"
  echo "Not undone: the system updates (apt dist-upgrade cannot be reverted) and the tools curl, git and unattended-upgrades."
  local reply
  printf "Type RESET to continue: "
  read -r reply || reply=""
  [ "$reply" = "RESET" ] || { echo "Nothing was changed."; exit 1; }
  [ -n "${TMUX:-}" ] || tmux kill-session -t gaga-setup 2>/dev/null || true
  rm -f /etc/ssh/sshd_config.d/00-hardening.conf /etc/ssh/sshd_config.d/10-gaga-tier3.conf
  systemctl restart ssh || true
  for u in "${users[@]}"; do
    id "$u" >/dev/null 2>&1 || continue
    pkill -KILL -u "$u" 2>/dev/null || true
    userdel -r "$u" 2>/dev/null || userdel "$u" || true
  done
  rm -f /etc/sudoers.d/90-gaga-staff /etc/sudoers.d/91-gaga-tiers
  groupdel "$TIER2_GROUP" 2>/dev/null || true
  groupdel "$TIER3_GROUP" 2>/dev/null || true
  if [ -d "$DEPLOY_DIR" ]; then
    if command -v docker >/dev/null 2>&1 && [ -f "$DEPLOY_DIR/deploy/cloud/compose.yml" ]; then (cd "$DEPLOY_DIR/deploy/cloud" && docker compose down) || true; fi
    stamp="$(date +%Y%m%d-%H%M%S)"
    mv "$DEPLOY_DIR" "$DEPLOY_DIR.removed-$stamp"
    chown -R root:root "$DEPLOY_DIR.removed-$stamp"
    echo "The old folder is kept at $DEPLOY_DIR.removed-$stamp (delete it with rm -rf when you are sure)."
  fi
  groupdel "$SHARED_GROUP" 2>/dev/null || true
  chown root:root /srv
  chmod g-s /srv
  chmod 755 /srv
  git config --system --unset-all safe.directory "^$DEPLOY_DIR\$" 2>/dev/null || true
  if [ -f "$STATE_DIR/installed-docker" ]; then
    if [ -z "$(docker ps -aq 2>/dev/null)" ] && [ -z "$(docker volume ls -q 2>/dev/null)" ]; then
      apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
      rm -rf /var/lib/docker /var/lib/containerd
      echo "Docker removed."
    else
      echo "Docker was kept: it has containers or volumes (data). Remove them first if you really want it gone."
    fi
  fi
  if [ -s "$STATE_DIR/prev-timezone" ]; then timedatectl set-timezone "$(cat "$STATE_DIR/prev-timezone")" || true; fi
  [ ! -f "$STATE_DIR/installed-tmux" ] || [ -n "${TMUX:-}" ] || apt-get purge -y tmux
  rm -rf "$STATE_DIR"
  echo "Reset done. Run  bash bootstrap.sh  and choose the full installation to start again."
}

# runs inside tmux so a dropped connection does not stop it
protected_full() {
  if [ -z "${TMUX:-}" ] && [ -z "${GAGA_NO_TMUX:-}" ] && [ -t 0 ]; then
    command -v tmux >/dev/null 2>&1 || { touch "$STATE_DIR/installed-tmux"; apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux; }
    echo "Starting inside tmux (session gaga-setup). If the connection drops, log in again and run this script: it re-attaches."
    exec tmux new-session -A -s gaga-setup "GAGA_NO_TMUX=1 REPO_BRANCH='$REPO_BRANCH' bash '$SELF' full; printf '\nPress Enter to close this window. '; read -r _"
  fi
  step_full
}

choice="${1:-}"
if [ -z "$choice" ]; then
  cat <<EOF
GAGA Platform server setup
  1) Full installation (new server; protected and resumable)
  2) System update and Docker
  3) Repository access and clone
  4) Shared permissions on /srv
  5) Deploy account for GitHub Actions
  6) New user (access tier 1, 2 or 3)
  7) Close root and password login
  8) Reset: undo an unfinished full installation
  0) Exit
EOF
  ask choice "Choose:"
fi
case "$choice" in
  1 | full) protected_full ;;
  2 | system) step_system ;;
  3 | repo) step_repo ;;
  4 | perms) step_perms ;;
  5 | deploy) step_deploy ;;
  6 | admin) step_admin ;;
  7 | ssh) step_ssh ;;
  8 | reset) step_reset ;;
  0 | "") echo "Nothing done." ;;
  *) echo "Unknown option '$choice'."; exit 1 ;;
esac
exit 0

# ============================ THE SAME BY HAND (copy and paste, as root) ============================
# System and Docker
#   apt-get update && apt-get -y dist-upgrade
#   apt-get install -y ca-certificates curl git unattended-upgrades
#   timedatectl set-timezone America/Mexico_City
#   install -m 0755 -d /etc/apt/keyrings
#   curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && chmod a+r /etc/apt/keyrings/docker.asc
#   echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
#   apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
#
# Deploy account and its read-only git key (its .pub goes in GitHub Deploy keys, without write access)
#   groupadd -f gaga
#   adduser --disabled-password --gecos "GAGA automatic deploy" gaga-deploy
#   usermod -aG docker,gaga gaga-deploy
#   install -d -m 700 -o gaga-deploy -g gaga-deploy /home/gaga-deploy/.ssh
#   sudo -u gaga-deploy ssh-keygen -t ed25519 -N "" -f /home/gaga-deploy/.ssh/id_gaga_git
#   printf 'Host github.com\n  IdentityFile /home/gaga-deploy/.ssh/id_gaga_git\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n' > /home/gaga-deploy/.ssh/config
#   chown gaga-deploy:gaga-deploy /home/gaga-deploy/.ssh/config && chmod 600 /home/gaga-deploy/.ssh/config
#
# Code and permissions: everything under /srv is root's and the group gaga edits it
#   install -d -m 2775 -o root -g gaga /srv/gaga-platform
#   GIT_SSH_COMMAND="ssh -i /home/gaga-deploy/.ssh/id_gaga_git -o IdentitiesOnly=yes" sh -c 'umask 002; git clone git@github.com:<owner>/<repo>.git /srv/gaga-platform'
#   cp /srv/gaga-platform/deploy/cloud/.env.example /srv/gaga-platform/deploy/cloud/.env   # empty on purpose, filled in later
#   chown -R root:gaga /srv && chmod -R g+rwX /srv && find /srv -type d -exec chmod g+s {} + && chmod 2775 /srv
#   chmod 660 /srv/gaga-platform/.env
#   git config --system --add safe.directory /srv/gaga-platform
#
# Key of GitHub Actions (PUBLIC key), limited to the deploy script
#   echo 'restrict,command="bash /srv/gaga-platform/deploy/server/deploy.sh" ssh-ed25519 AAAA... gaga-actions' >> /home/gaga-deploy/.ssh/authorized_keys
#   chown gaga-deploy:gaga-deploy /home/gaga-deploy/.ssh/authorized_keys && chmod 600 /home/gaga-deploy/.ssh/authorized_keys
#
# First user (tier 1, full sudo). Tier 2 and 3 go in the groups gaga-t2 / gaga-t3 with the sudo rule of step "admin" instead
#   adduser --disabled-password --gecos "" admin1
#   usermod -aG sudo,gaga admin1
#   install -d -m 700 -o admin1 -g admin1 /home/admin1/.ssh
#   echo "ssh-ed25519 AAAA... emmanuel@pc" > /home/admin1/.ssh/authorized_keys
#   chown admin1:admin1 /home/admin1/.ssh/authorized_keys && chmod 600 /home/admin1/.ssh/authorized_keys
#   echo "admin1:<temporary password>" | chpasswd && chage -d 0 admin1      # forces a new password at the first login
#
# Close root and passwords (test the administrator login from another window first, then sudo whoami)
#   printf 'PermitRootLogin no\nPasswordAuthentication no\n' > /etc/ssh/sshd_config.d/00-hardening.conf
#   sshd -t && systemctl restart ssh

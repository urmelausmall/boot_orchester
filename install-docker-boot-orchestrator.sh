#!/usr/bin/env bash
set -euo pipefail

# Wo kommt was hin?
INSTALL_SCRIPT_PATH="/usr/local/sbin/docker-boot-start.sh"
SERVICE_PATH="/etc/systemd/system/docker-boot-start.service"
CONFIG_DIR="/docker/boot_order"
CONFIG_FILE="$CONFIG_DIR/docker-boot-config.env"

echo "=== Docker Boot Orchestrator Installer ==="

# Root-Check
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Bitte als root ausführen (sudo ...)." >&2
  exit 1
fi

echo "→ Erstelle Config-Verzeichnis: $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

echo "→ Schreibe Boot-Skript nach: $INSTALL_SCRIPT_PATH"

cat > "$INSTALL_SCRIPT_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ─── BASISPFAD ────────────────────────────────────────────────────────────────
# Hier liegen auf dem Pi deine Boot-Config-Dateien:
BASE_DIR="/docker/boot_order"

DEPENDENCY_FILE="$BASE_DIR/dependencies.txt"
PRIORITY_FILE="$BASE_DIR/first_boot_container.txt"
CONFIG_FILE="$BASE_DIR/docker-boot-config.env"

# ─── DEFAULT-KONFIG ──────────────────────────────────────────────────────────
# Diese Defaults können über CONFIG_FILE überschrieben werden.
GOTIFY_ENABLED=0
GOTIFY_URL=""
GOTIFY_TOKEN=""
GOTIFY_TITLE="Docker-Start-Skript (Pi)"
GOTIFY_PRIORITY=5

# Config einlesen (falls vorhanden)
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

# ─── GOTIFY ───────────────────────────────────────────────────────────────────
send_gotify_message() {
  local msg="$1"

  # Deaktiviert? Dann sofort raus.
  if [ "${GOTIFY_ENABLED:-0}" != "1" ]; then
    return 0
  fi

  if [ -z "${GOTIFY_URL:-}" ] || [ -z "${GOTIFY_TOKEN:-}" ]; then
    echo "⚠️ Gotify aktiviert, aber URL oder Token leer – keine Nachricht gesendet."
    return 0
  fi

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$GOTIFY_URL" \
      -H "X-Gotify-Key: $GOTIFY_TOKEN" \
      -F "title=${GOTIFY_TITLE:-Docker-Start-Skript (Pi)}" \
      -F "message=$msg" \
      -F "priority=${GOTIFY_PRIORITY:-5}" 2>/dev/null || echo "000")

  if [ "$http_code" != "200" ]; then
    echo "⚠️ Gotify-Fehler: HTTP $http_code"
  fi
}

# ─── Logging ─────────────────────────────────────────────────────────────────
log_messages="🚀 Docker-Start-Skript (Pi) gestartet\n\n"
log() {
  echo "$1"
  log_messages+="$1\n"
}

# ─── Timeouts & Delay ────────────────────────────────────────────────────────
DEP_TIMEOUT=60          # Max Wartezeit auf Dependencies (Sekunden)
START_TEST_TIMEOUT=30   # Max Wartezeit auf frisch gestarteten Container
INTERVAL=2              # Poll-Intervall
MIN_DELAY=10            # Pause zwischen Container-Starts

DOCKER_BIN="$(command -v docker || echo /usr/bin/docker)"

if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
  log "❌ docker nicht gefunden – breche ab."
  send_gotify_message "$(printf '%b' "$log_messages")"
  exit 1
fi

wait_for_container() {
  local c="$1" timeout="${2:-$START_TEST_TIMEOUT}" elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    local health status
    health=$($DOCKER_BIN inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo "")
    status=$($DOCKER_BIN inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "")
    if [ "$health" = "healthy" ] || { [ "$health" = "none" ] && [ "$status" = "running" ]; }; then
      return 0
    fi
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
  done
  return 1
}

# ─── Dependencies einlesen ────────────────────────────────────────────────────
declare -A deps=()

if [ -f "$DEPENDENCY_FILE" ]; then
  log "🔗 Dependencies laden aus $DEPENDENCY_FILE:"
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    case "$l" in \#*) continue ;; esac

    # Format: name depends on a & b & c
    local name rest
    name="$(echo "${l%%depends on*}" | xargs)"
    rest="${l#*depends on}"
    rest="$(echo "${rest//&/,}" | xargs)"

    IFS=',' read -ra arr <<< "$rest"
    deps["$name"]="${arr[*]}"

    log "  • $name:"
    for dep in "${arr[@]}"; do
      dep="$(echo "$dep" | xargs)"
      [ -z "$dep" ] && continue
      log "      - $dep"
    done
  done < "$DEPENDENCY_FILE"
  log ""
else
  log "ℹ️ Keine Dependency-Datei gefunden: $DEPENDENCY_FILE (ok, dann ohne)"
fi

# ─── Priorisierte Container ──────────────────────────────────────────────────
if [ ! -f "$PRIORITY_FILE" ]; then
  log "⚠️ Prioritäten-Datei fehlt: $PRIORITY_FILE – breche ab."
  send_gotify_message "$(printf '%b' "$log_messages")"
  exit 1
fi

declare -a priority_containers=()

log "📋 Boot-Prioritäten aus $PRIORITY_FILE:"
while IFS= read -r l; do
  [ -z "$l" ] && continue
  case "$l" in \#*) continue ;; esac
  local cname
  cname="$(echo "$l" | xargs)"
  [ -z "$cname" ] && continue
  priority_containers+=("$cname")
  log "  - $cname"
done < "$PRIORITY_FILE"
log ""

# ─── Start-Funktion mit Dependencies ─────────────────────────────────────────
start_with_deps() {
  local c="$1"
  log "▶️ Starte $c"

  IFS=' ' read -r -a arr <<< "${deps[$c]:-}"
  if [ ${#arr[@]} -gt 0 ]; then
    log "  Abhängigkeiten:"
    for dep in "${arr[@]}"; do
      dep="$(echo "$dep" | xargs)"
      [ -z "$dep" ] && continue
      log "    ├─ $dep"

      if wait_for_container "$dep" "$DEP_TIMEOUT"; then
        log "    │  ✓ ready"
      else
        log "    │  ✗ Timeout – starte $dep"
        $DOCKER_BIN start "$dep" >/dev/null 2>&1 || :
        if wait_for_container "$dep" "$START_TEST_TIMEOUT"; then
          log "    │  ✓ ready (nach Start)"
        else
          log "    │  ✗ unready"
        fi
      fi
    done
    log ""
  fi

  $DOCKER_BIN start "$c" >/dev/null 2>&1 || :
  if wait_for_container "$c"; then
    log "└─ ✓ $c läuft"
  else
    log "└─ ✗ $c unready"
  fi

  log "    ⏳ Warte $MIN_DELAY s"
  sleep "$MIN_DELAY"
  log ""
}

# ─── Priorisierte Container starten ──────────────────────────────────────────
log "== 🚀 Starte priorisierte Container =="
for c in "${priority_containers[@]}"; do
  start_with_deps "$c"
done

# ─── Restliche Container ─────────────────────────────────────────────────────
log "== 🚀 Starte restliche Container =="
mapfile -t all_names < <($DOCKER_BIN ps -a --format '{{.Names}}')
for c in "${all_names[@]}"; do
  [[ " ${priority_containers[*]} " =~ " $c " ]] && continue
  start_with_deps "$c"
done

# ─── Abschluss ───────────────────────────────────────────────────────────────
log "✅ Alle Container gestartet"
send_gotify_message "$(printf '%b' "$log_messages")"
EOF

chmod +x "$INSTALL_SCRIPT_PATH"

echo "→ Lege Template first_boot_container.txt an (falls nicht vorhanden)"

if [ ! -f "$CONFIG_DIR/first_boot_container.txt" ]; then
  cat > "$CONFIG_DIR/first_boot_container.txt" <<'EOF'
# Wichtigste zuerst
berry-mariadb
ntopng-redis-1
portainer_agent
openappsec-agent
crowdsec
npmplus
Beszel-Agent
Home-Assistant
npmplus-geoipupdate
pi-backup
EOF
else
  echo "  • $CONFIG_DIR/first_boot_container.txt existiert bereits – nicht überschrieben."
fi

echo "→ Lege Template dependencies.txt an (falls nicht vorhanden)"

if [ ! -f "$CONFIG_DIR/dependencies.txt" ]; then
  cat > "$CONFIG_DIR/dependencies.txt" <<'EOF'
homeassistant depends on berry-mariadb
npmplus depends on berry-mariadb & crowdsec & openappsec-agent
ntopng depends on ntopng-redis-1
EOF
else
  echo "  • $CONFIG_DIR/dependencies.txt existiert bereits – nicht überschrieben."
fi

echo "→ Lege Template docker-boot-config.env an (falls nicht vorhanden)"

if [ ! -f "$CONFIG_FILE" ]; then
  cat > "$CONFIG_FILE" <<'EOF'
# =====================================================================
# Konfiguration für /usr/local/sbin/docker-boot-start.sh
#
# Diese Datei wird beim Start des Skripts per "source" eingelesen.
# Änderungen werden beim nächsten Boot / nächsten Service-Start wirksam.
# =====================================================================

# ========== GOTIFY ==========
# 0 = keine Benachrichtigungen, 1 = Benachrichtigungen senden
GOTIFY_ENABLED=0

# Vollständige Gotify-URL zum Message-Endpunkt
# Beispiel: "https://gotify.deinedomain.tld/message"
GOTIFY_URL="https://gotify.example.com/message"

# Gotify-App-Token (unbedingt geheim halten!)
GOTIFY_TOKEN=""

# Optional: Titel und Priorität der Nachrichten
GOTIFY_TITLE="Docker-Start-Skript (Pi)"
GOTIFY_PRIORITY=5
EOF

  chmod 600 "$CONFIG_FILE"
  echo "  • $CONFIG_FILE erstellt (chmod 600)."
else
  echo "  • $CONFIG_FILE existiert bereits – nicht überschrieben."
fi

echo "→ Erstelle systemd Service: $SERVICE_PATH"

cat > "$SERVICE_PATH" <<'EOF'
[Unit]
Description=Docker Boot Orchestrator (Pi)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/docker-boot-start.sh
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

echo "→ Setze einfache Rechte für $CONFIG_DIR"

# Ordner: owner+group rwx, andere rx
chmod 775 "$CONFIG_DIR"

# Alle Dateien im Ordner: owner+group rw, andere r
chmod 664 "$CONFIG_DIR"/* 2>/dev/null || true

echo "→ systemd neu einlesen & Service aktivieren"
systemctl daemon-reload
systemctl enable docker-boot-start.service


echo
echo "=== Fertig! ==="
echo "• Skript:   $INSTALL_SCRIPT_PATH"
echo "• Service:  docker-boot-start.service (beim Boot aktiv)"
echo "• Configs:  $CONFIG_DIR/first_boot_container.txt"
echo "            $CONFIG_DIR/dependencies.txt"
echo "            $CONFIG_FILE"
echo
echo "Optional: jetzt einmalig testen mit:"
echo "  sudo systemctl start docker-boot-start.service"

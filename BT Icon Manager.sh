#!/bin/bash

#--------------------------------#
#   Bluetooth Icon Management    #
#            By Jason            #
#--------------------------------#

# --- Vérification des privilèges root ---
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi
set -euo pipefail

# --- Variables globales ---
CURR_TTY="/dev/tty1"
BACKTITLE="Bluetooth Icon Manager - By Jason"

THEMES_DIR="/roms/themes"
BLUETOOTH_PATCH_MARKER=".bluetooth_icon_patched"

BLUETOOTH_ICON_POS_X="0.215" 
BLUETOOTH_ICON_POS_Y="0.033" 
BLUETOOTH_ICON_SIZE="0.053"   

UPDATER_PATH="/usr/local/bin/bluetooth_icon_state_updater.sh"
SERVICE_PATH="/etc/systemd/system/bluetooth-icon-updater.service"

UPDATE_INTERVAL=2

# --- Configuration initiale ---
printf "\033c" > "$CURR_TTY"
printf "\e[?25l" > "$CURR_TTY"
dialog --clear
export TERM=linux
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [[ ! -e "/dev/input/by-path/platform-odroidgo2-joypad-event-joystick" ]]; then
    setfont /usr/share/consolefonts/Lat7-TerminusBold22x11.psf.gz
else
    setfont /usr/share/consolefonts/Lat7-Terminus16.psf.gz
fi

pkill -9 -f gptokeyb || true
pkill -9 -f osk.py || true

printf "\033c" > "$CURR_TTY"
printf "Firing up BT Icon Manager...\nHang tight." > "$CURR_TTY"
sleep 1

# --- Fonction pour vérifier si les paquets nécessaires sont installés ---
check_bluetooth_deps() {
    local REQUIRED_PACKAGES=("rfkill" "bluez")
    local MISSING_PACKAGES=()

    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            MISSING_PACKAGES+=("$pkg")
        fi
    done

    if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
        if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
            dialog --backtitle "$BACKTITLE" --title "Need Net" --msgbox "\nNeed active internet to install missing stuff.\n\nPlease connect first." 9 60 > "$CURR_TTY"
            ExitMenu
        fi
        dialog --backtitle "$BACKTITLE" --title "Checking Deps" --infobox "\nInstalling: ${MISSING_PACKAGES[*]}..." 5 60 > "$CURR_TTY"
        sleep 1
        apt-get update -y >/dev/null 2>&1
        if apt-get install -y "${MISSING_PACKAGES[@]}" >/dev/null 2>&1; then
            dialog --backtitle "$BACKTITLE" --title "Checking Deps" --infobox "\nSorted. Installation done." 6 60 > "$CURR_TTY"
            sleep 2
        else
            dialog --backtitle "$BACKTITLE" --title "Checking Deps" --msgbox "\nInstall failed. Bummer." 6 60 > "$CURR_TTY"
            ExitMenu
        fi
    fi
}

# --- Fonction Exit ---
ExitMenu() {
    printf "\033c" > "$CURR_TTY"
    printf "\e[?25h" > "$CURR_TTY" 
    pkill -f "gptokeyb -1 BT Icon Manager.sh" || true 
    if [[ ! -e "/dev/input/by-path/platform-odroidgo2-joypad-event-joystick" ]]; then
        setfont /usr/share/consolefonts/Lat7-Terminus20x10.psf.gz
    fi
    exit 0
}

# --- Fonction pour redémarrer EmulationStation ---
restart_es_and_exit() {
    dialog --backtitle "$BACKTITLE" --title "Rebooting" --infobox "\nRestarting EmulationStation..." 5 40 > "$CURR_TTY"
    sleep 2
    systemctl restart emulationstation &
    ExitMenu
}

# --- Fonction pour déterminer l'état actuel (utilisé pour la synchro immédiate) ---
get_immediate_bt_state() {
    # 1. Blocked
    if rfkill list bluetooth | grep -q "Soft blocked: yes"; then echo "off"; return; fi
    # 2. Service inactif
    if ! systemctl is-active --quiet bluetooth; then echo "off"; return; fi
    # 3. Powered off
    if ! echo "show" | bluetoothctl | grep -q "Powered: yes"; then echo "off"; return; fi
    # 4. Connecte via bluetoothctl
    if echo "info" | bluetoothctl | grep -q "Connected: yes"; then echo "connected"; return; fi
    # 5. Connecte via hcitool fallback
    if command -v hcitool &> /dev/null; then
        if hcitool con 2>/dev/null | grep -q "..:..:..:..:..:.."; then echo "connected"; return; fi
    fi
    # 6. Fallback check
    if bluetoothctl devices Connected | grep -q ":"; then echo "connected"; return; fi
    
    echo "on_not_connected"
}

# --- Fonction pour créer le script en arrière-plan ---
create_updater_script() {
    cat > "$UPDATER_PATH" << 'EOF'
#!/bin/bash
THEMES_DIR="/roms/themes"
UPDATE_INTERVAL=2
prev_state=""

get_bluetooth_icon_state() {
    if rfkill list bluetooth | grep -q "Soft blocked: yes"; then echo "off"; return; fi
    if ! systemctl is-active --quiet bluetooth; then echo "off"; return; fi
    if ! echo "show" | bluetoothctl | grep -q "Powered: yes"; then echo "off"; return; fi
    if echo "info" | bluetoothctl | grep -q "Connected: yes"; then echo "connected"; return; fi
    if command -v hcitool &> /dev/null; then
        if hcitool con 2>/dev/null | grep -q "..:..:..:..:..:.."; then echo "connected"; return; fi
    fi
    if bluetoothctl devices Connected | grep -q ":"; then echo "connected"; return; fi
    echo "on_not_connected"
}

while true; do
    current_state=$(get_bluetooth_icon_state)

    if [[ "$current_state" != "$prev_state" ]]; then
        need_restart=false
        for theme_path in "$THEMES_DIR"/*; do
            [ -d "$theme_path" ] || continue
            art_dir="$theme_path/_art"
            [ -d "$art_dir" ] || art_dir="$theme_path/art"
            [ -d "$art_dir" ] || continue
            
            icon_file="$art_dir/bluetooth.svg"
            connected_bak="$art_dir/bluetooth_connected.bak.svg"
            on_bak="$art_dir/bluetooth_on.bak.svg"
            off_bak="$art_dir/bluetooth_off.bak.svg"

            if [[ "$current_state" == "connected" ]]; then
                if [[ -f "$connected_bak" ]]; then
                    if [[ ! -f "$icon_file" ]] || ! cmp -s "$connected_bak" "$icon_file"; then
                        cp "$connected_bak" "$icon_file"
                        need_restart=true
                    fi
                fi
            elif [[ "$current_state" == "on_not_connected" ]]; then
                if [[ -f "$on_bak" ]]; then
                    if [[ ! -f "$icon_file" ]] || ! cmp -s "$on_bak" "$icon_file"; then
                        cp "$on_bak" "$icon_file"
                        need_restart=true
                    fi
                fi
            else 
                if [[ -f "$off_bak" ]]; then
                    if [[ ! -f "$icon_file" ]] || ! cmp -s "$off_bak" "$icon_file"; then
                        cp "$off_bak" "$icon_file"
                        need_restart=true
                    fi
                fi
            fi
        done
        if [ "$need_restart" = true ]; then
    sleep 2
            systemctl restart emulationstation
        fi
        prev_state="$current_state"
    fi
    sleep "$UPDATE_INTERVAL"
done
EOF
    chmod +x "$UPDATER_PATH"
}

# --- Fonction pour créer et activer le service systemd ---
create_systemd_service() {
    cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Bluetooth Icon State Updater
After=bluetooth.service
[Service]
ExecStart=$UPDATER_PATH
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable --now "$(basename "$SERVICE_PATH")"
}

# --- Fonction pour vérifier si les thèmes ont déjà été patchés ---
themes_already_patched() {
    local all_patched=true
    for theme_path in "$THEMES_DIR"/*; do
        [ -d "$theme_path" ] || continue
        if [ ! -f "$theme_path/$BLUETOOTH_PATCH_MARKER" ]; then
            return 1
        fi
    done
    return 0
}

# --- Fonction pour installer les icônes Bluetooth ---
install_icons() {
    create_updater_script
    create_systemd_service

    if themes_already_patched; then
        dialog --backtitle "$BACKTITLE" --title "Done" --msgbox "\nThemes are already patched." 7 40 > "$CURR_TTY"
        return
    fi

    dialog --backtitle "$BACKTITLE" --title "Installing" --infobox "\nPatching themes, hang tight..." 5 40 > "$CURR_TTY"
    sleep 2

    local target_xml_files=("theme.xml" "main.xml" "header.xml" "rgb30.xml" "ogs.xml" "503.xml" "fullscreen.xml" "fullscreenv.xml")
    local progress_text=""

    for theme_path in "$THEMES_DIR"/*; do
        [ -d "$theme_path" ] || continue
        [ -f "$theme_path/$BLUETOOTH_PATCH_MARKER" ] && continue

        local theme_was_patched=false
        local art_dir=""
        local xml_block=""

        for xml_file in "${target_xml_files[@]}"; do
            local theme_xml_file="$theme_path/$xml_file"

            if [ -f "$theme_xml_file" ]; then
                if [[ -z "$art_dir" ]]; then
                    art_dir="$theme_path/_art"
                    [ -d "$art_dir" ] || art_dir="$theme_path/art"
                    mkdir -p "$art_dir"

                    # Icônes SVG
                    cat > "$art_dir/bluetooth_connected.bak.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#007bff" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7 7l10 10-5 5V2l5 5-10 10"/></svg>
EOF
                    cat > "$art_dir/bluetooth_on.bak.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#ff6600" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7 7l10 10-5 5V2l5 5-10 10"/></svg>
EOF
                    cat > "$art_dir/bluetooth_off.bak.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#dc3545" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7 7l10 10-5 5V2l5 5-10 10"/><line x1="2" y1="22" x2="22" y2="2" /></svg>
EOF
                    # Par défaut on met OFF, mais on va le mettre à jour juste après
                    cp "$art_dir/bluetooth_off.bak.svg" "$art_dir/bluetooth.svg"

                    local icon_path_prefix=$(realpath --relative-to="$theme_path" "$art_dir")
                    xml_block="
    <image name=\"bluetooth_icon\" extra=\"true\">
        <path>./$icon_path_prefix/bluetooth.svg</path>
        <pos>${BLUETOOTH_ICON_POS_X} ${BLUETOOTH_ICON_POS_Y}</pos>
        <origin>0.5 0.5</origin>
        <maxSize>${BLUETOOTH_ICON_SIZE} ${BLUETOOTH_ICON_SIZE}</maxSize>
        <zIndex>150</zIndex>
        <visible>true</visible>
    </image>"
                fi

                cp "$theme_xml_file" "${theme_xml_file}.bak"
                awk -v block="$xml_block" '/<view / { print; print block; next } { print }' "$theme_xml_file" > "${theme_xml_file}.tmp" && mv "${theme_xml_file}.tmp" "$theme_xml_file"
                theme_was_patched=true
            fi
        done

        if [ "$theme_was_patched" = true ]; then
            touch "$theme_path/$BLUETOOTH_PATCH_MARKER"
            progress_text+="Theme: $(basename "$theme_path")\n"
        fi
    done

    dialog --backtitle "$BACKTITLE" --title "Syncing" --infobox "\nWaiting for Bluetooth Status..." 5 40 > "$CURR_TTY"
    
    local final_status="off"
    for i in $(seq 1 5); do
        final_status=$(get_immediate_bt_state)
        if [ "$final_status" == "connected" ]; then
            break
        fi
        sleep 1
    done

    dialog --backtitle "$BACKTITLE" --title "Syncing" --infobox "\nApplying status: $final_status..." 5 40 > "$CURR_TTY"
    
    for theme_path in "$THEMES_DIR"/*; do
        [ -d "$theme_path" ] || continue
        [ -f "$theme_path/$BLUETOOTH_PATCH_MARKER" ] || continue
        
        art_dir="$theme_path/_art"
        [ -d "$art_dir" ] || art_dir="$theme_path/art"
        
        if [ "$final_status" == "connected" ]; then
             cp -f "$art_dir/bluetooth_connected.bak.svg" "$art_dir/bluetooth.svg" 2>/dev/null
        elif [ "$final_status" == "on_not_connected" ]; then
             cp -f "$art_dir/bluetooth_on.bak.svg" "$art_dir/bluetooth.svg" 2>/dev/null
        else
             cp -f "$art_dir/bluetooth_off.bak.svg" "$art_dir/bluetooth.svg" 2>/dev/null
        fi
    done
    sleep 1

    dialog --backtitle "$BACKTITLE" --title "Patched" --msgbox "\n$progress_text" 0 0 > "$CURR_TTY"
    restart_es_and_exit
}

# --- Fonction pour désinstaller ---
uninstall_icons() {
    dialog --backtitle "$BACKTITLE" --title "Uninstalling" --infobox "\nRestoring themes..." 5 40 > "$CURR_TTY"
    sleep 2
    local progress_text=""
    local target_xml_files=("theme.xml" "main.xml" "header.xml" "rgb30.xml" "ogs.xml" "503.xml" "fullscreen.xml" "fullscreenv.xml")

    for theme_path in "$THEMES_DIR"/*; do
        [ -d "$theme_path" ] || continue
        if [ -f "$theme_path/$BLUETOOTH_PATCH_MARKER" ]; then
            for xml_file in "${target_xml_files[@]}"; do
                local theme_xml_file="$theme_path/$xml_file"
                if [ -f "${theme_xml_file}.bak" ]; then
                    mv "${theme_xml_file}.bak" "$theme_xml_file"
                fi
            done
            rm -f "$theme_path/$BLUETOOTH_PATCH_MARKER"
            rm -f "$theme_path"/{art,_art}/bluetooth_*.svg
            progress_text+="Themes: $(basename "$theme_path")\n"
        fi
    done

    rm -f "$UPDATER_PATH"
    rm -f "$SERVICE_PATH"
    systemctl stop bluetooth-icon-updater.service >/dev/null 2>&1 || true
    systemctl disable bluetooth-icon-updater.service >/dev/null 2>&1 || true
    systemctl daemon-reload

    dialog --backtitle "$BACKTITLE" --title "Restored" --msgbox "\n$progress_text" 0 0 > "$CURR_TTY"
    restart_es_and_exit
}

# --- Menu principal ---
MainMenu() {
    check_bluetooth_deps 
    while true; do
        local CHOICE
        CHOICE=$(dialog --output-fd 1 \
            --backtitle "$BACKTITLE" \
            --title "Bluetooth Icon Manager" \
            --menu "\nPick an option:" 16 50 3 \
            1 "Install BT Icon" \
            2 "Uninstall BT Icon" \
            3 "Exit" \
        2>"$CURR_TTY")

        case $CHOICE in
            1) install_icons ;;
            2) uninstall_icons ;;
            3) ExitMenu ;;
            *) ExitMenu ;;
        esac
    done
}

# --- EXÉCUTION ---
trap ExitMenu EXIT SIGINT SIGTERM

if command -v /opt/inttools/gptokeyb &> /dev/null; then
    if [[ -e /dev/uinput ]]; then
        chmod 666 /dev/uinput 2>/dev/null || true
    fi
    export SDL_GAMECONTROLLERCONFIG_FILE="/opt/inttools/gamecontrollerdb.txt"

    SCRIPT_NAME=$(basename "$0")

    pkill -f "gptokeyb -1 $SCRIPT_NAME" || true
    /opt/inttools/gptokeyb -1 "$SCRIPT_NAME" -c "/opt/inttools/keys.gptk" >/dev/null 2>&1 &
fi

printf "\033c" > "$CURR_TTY"
MainMenu
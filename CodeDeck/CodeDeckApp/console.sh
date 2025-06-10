#!/bin/bash

# ── CODEDECK CONSOLE CHAT APPLICATION ──
# Interactive terminal interface for CodeDeck Neural Interface

# ── COLOR CODES ──
PURPLE="\e[35m"
DIM_PURPLE="\e[2;35m"
ORANGE="\e[33m"
BRIGHT_ORANGE="\e[1;33m"
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BLUE="\e[34m"
RESET="\e[0m"

# ── CONFIGURATION ──
CODEDECK_API="http://localhost:8000"
GLADOS_PERSONA_ID="assistant-default"  # Default assistant persona
DEFAULT_MODEL="deepseek_r1_distill_qwen_1_5b_q4_0"  # Current available model
VOICE_ENABLED=false  # Toggle for voice responses

# ── SOUND EFFECTS ──
SOUND_EFFECTS_DIR="$(dirname "$0")/assets"  # Sound effects directory
SOUND_ENABLED=true  # Toggle for sound effects

# ── SESSION STATE ──
SESSION_SYSTEM_MESSAGE=""  # Current session system message
MESSAGE_HISTORY=()  # Array to store conversation history
CONTEXT_LENGTH=5  # Number of message pairs to include in context
CURRENT_MODEL="$DEFAULT_MODEL"  # Currently selected model

# ── BATTERY & CACHING ──
LAST_BATTERY_WARNING=100  # Track last battery warning level
SPEECH_CACHE_DIR="$HOME/.codedeck/speech_cache"  # Directory for cached speech files
RECORDING_CACHE_DIR="$HOME/.codedeck/recording_cache"  # Directory for temporary recordings

# ── INTERRUPT HANDLING ──
GENERATION_PID=""  # Track the current generation process
INTERRUPT_REQUESTED=false  # Flag for interrupt requests

# ── TERMINAL DETECTION ──
# Detect if we're running over SSH or locally
IS_SSH_SESSION=false
if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ] || [ -n "$SSH_CONNECTION" ]; then
    IS_SSH_SESSION=true
fi

# Function to handle interrupt signals
handle_interrupt() {
    INTERRUPT_REQUESTED=true
    if [ -n "$GENERATION_PID" ]; then
        kill -TERM "$GENERATION_PID" 2>/dev/null
    fi
    echo -e "\n$YELLOW[⚠] Generation interrupted by user$RESET"
    
    # Only reset terminal state if needed, and do it gently
    if [ "$IS_SSH_SESSION" = true ]; then
        stty sane 2>/dev/null || true
    else
        # For local terminals, be more careful
        stty echo 2>/dev/null || true
        stty icanon 2>/dev/null || true
    fi
}

# Set up interrupt handlers
trap handle_interrupt SIGINT SIGTERM

# ── TERMINAL RECOVERY ──

# Function to recover terminal state - only when actually needed
recover_terminal_state() {
    echo -e "$DIM_PURPLE[🔧 Recovering terminal state...]$RESET"
    
    # Reset terminal settings based on session type
    if [ "$IS_SSH_SESSION" = true ]; then
        # SSH sessions can handle full stty sane
        stty sane 2>/dev/null || true
    else
        # Local terminals - be more gentle
        stty echo 2>/dev/null || true
        stty icanon 2>/dev/null || true
        stty -raw 2>/dev/null || true
    fi
    
    # Clear any pending input only if needed
    if read -r -t 0 2>/dev/null; then
        while read -r -t 0.1 2>/dev/null; do
            break
        done
    fi
    
    # Reset interrupt flag
    INTERRUPT_REQUESTED=false
    
    # Clear generation PID
    GENERATION_PID=""
    
    echo -e "$GREEN[✓ Terminal state recovered]$RESET"
}

# ── INITIALIZATION ──

# Create speech cache directory
mkdir -p "$SPEECH_CACHE_DIR"

# Create recording cache directory  
mkdir -p "$RECORDING_CACHE_DIR"

# ── BATTERY MONITORING FUNCTIONS ──

# Function to get battery percentage
get_battery_percentage() {
    local battery_percent=""
    
    # Try different methods based on the system
    if command -v pmset >/dev/null 2>&1; then
        # macOS
        battery_percent=$(pmset -g batt | grep -Eo "[0-9]+%" | head -1 | tr -d '%')
    elif [ -f /sys/class/power_supply/BAT0/capacity ]; then
        # Linux - most common location
        battery_percent=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)
    elif [ -f /sys/class/power_supply/BAT1/capacity ]; then
        # Linux - alternative battery location
        battery_percent=$(cat /sys/class/power_supply/BAT1/capacity 2>/dev/null)
    elif command -v upower >/dev/null 2>&1; then
        # Linux with upower - try different battery paths
        local bat_path=$(upower -e | grep -i bat | head -1)
        if [ -n "$bat_path" ]; then
            battery_percent=$(upower -i "$bat_path" | grep -E "percentage" | awk '{print $2}' | tr -d '%')
        fi
    elif command -v acpi >/dev/null 2>&1; then
        # Linux with acpi
        battery_percent=$(acpi -b | grep -P -o '[0-9]+(?=%)' | head -1)
    elif [ -d /proc/acpi/battery ]; then
        # Older Linux systems
        for battery in /proc/acpi/battery/BAT*; do
            if [ -f "$battery/state" ]; then
                local remaining=$(grep "remaining capacity" "$battery/state" | awk '{print $3}')
                local full=$(grep "last full capacity" "$battery/info" | awk '{print $4}')
                if [ -n "$remaining" ] && [ -n "$full" ] && [ "$full" -gt 0 ]; then
                    battery_percent=$((remaining * 100 / full))
                    break
                fi
            fi
        done
    elif command -v cat >/dev/null 2>&1 && [ -f /sys/class/power_supply/battery/capacity ]; then
        # Some systems use 'battery' instead of 'BAT0'
        battery_percent=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    elif command -v cat >/dev/null 2>&1; then
        # Try to find any power supply with capacity
        for ps in /sys/class/power_supply/*/capacity; do
            if [ -f "$ps" ]; then
                battery_percent=$(cat "$ps" 2>/dev/null)
                if [ -n "$battery_percent" ] && [ "$battery_percent" -le 100 ]; then
                    break
                fi
            fi
        done
    fi
    
    # Return the percentage or empty if not found
    echo "$battery_percent"
}

# Function to get charging status
get_charging_status() {
    local charging=""
    
    if command -v pmset >/dev/null 2>&1; then
        # macOS
        charging=$(pmset -g batt | grep -o "AC Power\|Battery Power")
    elif [ -f /sys/class/power_supply/BAT0/status ]; then
        # Linux
        charging=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null)
    elif [ -f /sys/class/power_supply/BAT1/status ]; then
        # Linux alternative
        charging=$(cat /sys/class/power_supply/BAT1/status 2>/dev/null)
    elif command -v upower >/dev/null 2>&1; then
        # Linux with upower
        local bat_path=$(upower -e | grep -i bat | head -1)
        if [ -n "$bat_path" ]; then
            charging=$(upower -i "$bat_path" | grep -E "state" | awk '{print $2}')
        fi
    elif command -v acpi >/dev/null 2>&1; then
        # Linux with acpi - get charging status
        charging=$(acpi -a | grep -o "on-line\|off-line")
    elif [ -f /sys/class/power_supply/AC0/online ]; then
        # Check AC adapter status
        local ac_online=$(cat /sys/class/power_supply/AC0/online 2>/dev/null)
        if [ "$ac_online" = "1" ]; then
            charging="Charging"
        else
            charging="Discharging"
        fi
    elif [ -f /sys/class/power_supply/ADP0/online ]; then
        # Alternative AC adapter path
        local ac_online=$(cat /sys/class/power_supply/ADP0/online 2>/dev/null)
        if [ "$ac_online" = "1" ]; then
            charging="Charging"
        else
            charging="Discharging"
        fi
    fi
    
    echo "$charging"
}

# Function to display battery status
show_battery_status() {
    local battery_percent
    local charging_status
    local battery_icon
    local charging_icon
    
    battery_percent=$(get_battery_percentage)
    charging_status=$(get_charging_status)
    
    if [ -z "$battery_percent" ]; then
        echo -e "$RED🔋 Battery: $YELLOW[Unable to detect]$RESET"
        return
    fi
    
    # Choose battery icon based on level
    if [ "$battery_percent" -ge 75 ]; then
        battery_icon="🔋"
    elif [ "$battery_percent" -ge 50 ]; then
        battery_icon="🔋"
    elif [ "$battery_percent" -ge 25 ]; then
        battery_icon="🪫"
    else
        battery_icon="🪫"
    fi
    
    # Choose charging icon and status
    if [[ "$charging_status" =~ (Charging|AC\ Power|on-line) ]]; then
        charging_icon="⚡"
    else
        charging_icon=""
    fi
    
    # Use bright, distinct colors for battery percentage
    local battery_color
    local battery_bg=""
    if [ "$battery_percent" -ge 75 ]; then
        battery_color="\e[1;92m"  # Bright green
    elif [ "$battery_percent" -ge 50 ]; then
        battery_color="\e[1;93m"  # Bright yellow
    elif [ "$battery_percent" -ge 20 ]; then
        battery_color="\e[1;91m"  # Bright red
    else
        battery_color="\e[1;97;41m"  # Bright white on red background (critical)
        battery_bg=" [CRITICAL]"
    fi
    
    # Display with distinct formatting
    echo -e "$DIM_PURPLE$battery_icon Battery: $battery_color$battery_percent%$charging_icon$battery_bg$RESET"
}

# Function to check battery warnings
check_battery_warnings() {
    local battery_percent
    battery_percent=$(get_battery_percentage)
    
    if [ -z "$battery_percent" ]; then
        return
    fi
    
    # Check if we need to warn at specific thresholds
    local warning_levels=(50 20 10 5)
    local charging_status
    charging_status=$(get_charging_status)
    
    # Don't warn if charging
    if [[ "$charging_status" =~ (Charging|AC\ Power|on-line) ]]; then
        LAST_BATTERY_WARNING=100  # Reset warnings when charging
        return
    fi
    
    for level in "${warning_levels[@]}"; do
        if [ "$battery_percent" -le "$level" ] && [ "$LAST_BATTERY_WARNING" -gt "$level" ]; then
            LAST_BATTERY_WARNING="$level"
            
            # Show warning
            local warning_color
            if [ "$level" -le 10 ]; then
                warning_color="$RED"
            else
                warning_color="$YELLOW"
            fi
            
            echo ""
            echo -e "$warning_color⚠️  BATTERY WARNING: $battery_percent% remaining$RESET"
            
            # Speak warning if voice enabled
            if [ "$VOICE_ENABLED" = true ]; then
                speak_routine_message "battery_warning_$level" "Battery at $battery_percent percent. Consider charging soon."
            fi
            echo ""
            break
        fi
    done
}

# Function to show detailed battery information
check_battery_command() {
    local battery_percent
    local charging_status
    
    echo -e "$DIM_PURPLE[🔋 Battery Diagnostic Check...]$RESET"
    
    battery_percent=$(get_battery_percentage)
    charging_status=$(get_charging_status)
    
    if [ -z "$battery_percent" ]; then
        echo -e "$RED❌ Battery detection failed$RESET"
        echo -e "$YELLOW💡 Attempting alternative detection methods...$RESET"
        
        # Try to provide diagnostic information
        echo -e "$DIM_PURPLE"
        echo "Available power supply paths:"
        if [ -d /sys/class/power_supply ]; then
            ls -la /sys/class/power_supply/ 2>/dev/null || echo "  No /sys/class/power_supply directory"
        else
            echo "  No /sys/class/power_supply directory found"
        fi
        
        echo ""
        echo "Available detection tools:"
        command -v pmset >/dev/null 2>&1 && echo "  ✓ pmset (macOS)" || echo "  ✗ pmset"
        command -v upower >/dev/null 2>&1 && echo "  ✓ upower" || echo "  ✗ upower"
        command -v acpi >/dev/null 2>&1 && echo "  ✓ acpi" || echo "  ✗ acpi"
        echo -e "$RESET"
        
        # Try upower diagnostic if available
        if command -v upower >/dev/null 2>&1; then
            echo -e "$YELLOW🔍 upower diagnostic:$RESET"
            upower -l 2>/dev/null | head -10 || echo "  upower failed to list devices"
        fi
        
        return
    fi
    
    # Display detailed battery information
    echo -e "$GREEN✓ Battery detected successfully$RESET"
    echo ""
    
    # Show detailed status
    show_battery_status
    
    # Additional details
    echo -e "$DIM_PURPLE┌─────────────────────────────────────────────────────┐$RESET"
    echo -e "$DIM_PURPLE│                BATTERY DETAILS                     │$RESET"
    echo -e "$DIM_PURPLE└─────────────────────────────────────────────────────┘$RESET"
    
    local status_text="Discharging"
    if [[ "$charging_status" =~ (Charging|AC\ Power|on-line) ]]; then
        status_text="Charging"
    fi
    
    echo -e "$CYAN📊 Level: $battery_percent%$RESET"
    echo -e "$CYAN🔌 Status: $status_text$RESET"
    echo -e "$CYAN⚠️  Last Warning: $LAST_BATTERY_WARNING%$RESET"
    
    # Health assessment
    if [ "$battery_percent" -ge 75 ]; then
        echo -e "$GREEN💚 Health: Excellent$RESET"
    elif [ "$battery_percent" -ge 50 ]; then
        echo -e "$YELLOW💛 Health: Good$RESET"
    elif [ "$battery_percent" -ge 20 ]; then
        echo -e "$ORANGE🧡 Health: Low - Consider charging$RESET"
    else
        echo -e "$RED❤️  Health: Critical - Charge immediately$RESET"
    fi
    
    # Voice feedback if enabled
    if [ "$VOICE_ENABLED" = true ]; then
        if [ "$battery_percent" -le 20 ]; then
            speak_routine_message "battery_check_low" "Battery level is $battery_percent percent. You should charge soon."
        else
            speak_routine_message "battery_check_good" "Battery level is $battery_percent percent."
        fi
    fi
}

# ── CACHED SPEECH SYSTEM ──

# Function to speak routine messages with automatic caching
speak_routine_message() {
    local cache_key="$1"
    local message="$2"
    
    [ -z "$message" ] && return 1
    
    local cache_file="$SPEECH_CACHE_DIR/${cache_key}.wav"
    
    # Auto-fix cache directory permissions if needed
    mkdir -p "$SPEECH_CACHE_DIR" 2>/dev/null || {
        chmod -R 755 "$SPEECH_CACHE_DIR" 2>/dev/null
        chown -R "$(whoami):$(id -gn)" "$SPEECH_CACHE_DIR" 2>/dev/null
    }
    
    # Try cached version first
    if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
        # Quick validation - ensure it's not a JSON error
        if ! head -c 1 "$cache_file" 2>/dev/null | grep -q "{"; then
            echo -ne "$DIM_PURPLE[🔊 ♪]$RESET"
            aplay "$cache_file" >/dev/null 2>&1 &
            return 0
        fi
        # Remove corrupted cache
        rm -f "$cache_file" 2>/dev/null
    fi
    
    # Generate new audio
    echo -ne "$DIM_PURPLE[🎤 ♪]$RESET"
    
    # Ensure recording cache directory exists
    mkdir -p "$RECORDING_CACHE_DIR" 2>/dev/null
    local temp_audio="$RECORDING_CACHE_DIR/codedeck_voice_$(date +%s)_$$.wav"
    
    # Get audio from API
    if curl -s -X POST "$CODEDECK_API/v1/tts/speak" \
        -H "Content-Type: application/json" \
        -d "{\"text\": \"$message\", \"voice\": \"glados\", \"audio_file\": true}" \
        -o "$temp_audio" 2>/dev/null && [ -s "$temp_audio" ]; then
        
        # Validate audio file
        if ! head -c 1 "$temp_audio" 2>/dev/null | grep -q "{"; then
            # Try to save to cache (best effort)
            cp "$temp_audio" "$cache_file" 2>/dev/null
            
            # Play audio
            aplay "$temp_audio" >/dev/null 2>&1 &
            
            # Clean up temp file after delay
            (sleep 5 && rm -f "$temp_audio") &
            return 0
        fi
    fi
    
    # Cleanup on failure
    rm -f "$temp_audio" 2>/dev/null
    echo -ne "$DIM_PURPLE[🔊 ✗]$RESET"
    return 1
}

# Function to clear all cached voice clips
purge_cognitive_cache()
{
    local cache_dir="$SPEECH_CACHE_DIR"
    local cache_count=0
    local cache_size=0
    
    echo -e "$DIM_PURPLE[🗑️ Analyzing cognitive cache...]$RESET"
    
    # Count cache files if directory exists
    if [ -d "$cache_dir" ]; then
        cache_count=$(find "$cache_dir" -name "*.wav" 2>/dev/null | wc -l)
        if [ "$cache_count" -gt 0 ]; then
            # Calculate total size
            cache_size=$(find "$cache_dir" -name "*.wav" -exec ls -l {} \; 2>/dev/null | awk '{sum+=$5} END {print sum+0}')
            local size_mb=$(( cache_size / 1024 / 1024 ))
            
            echo -e "$YELLOW[📊 Found $cache_count cached voice clips (~${size_mb}MB)]$RESET"
            echo -e "$DIM_PURPLE[🗑️ Purging voice cache...]$RESET"
            
            # Remove all wav files
            find "$cache_dir" -name "*.wav" -delete 2>/dev/null
            
            # Verify deletion
            local remaining=$(find "$cache_dir" -name "*.wav" 2>/dev/null | wc -l)
            if [ "$remaining" -eq 0 ]; then
                echo -e "$GREEN[✓ Cache purged successfully - freed ${size_mb}MB]$RESET"
                play_sound_effect "confirm"
            else
                echo -e "$YELLOW[⚠ Partial purge - $remaining files remain]$RESET"
            fi
        else
            echo -e "$GREEN[✓ Cache already empty]$RESET"
        fi
    else
        echo -e "$GREEN[✓ No cache directory found]$RESET"
    fi
    
    # Voice feedback if enabled
    if [ "$VOICE_ENABLED" = true ]; then
        # Don't use cached message since we just cleared cache :)
        speak_routine_message "voice_cache_cleared" "Voice cache cleared."
    fi
}

# Function to play sound effects in background
play_sound_effect() {
    local sound_name="$1"
    
    if [ "$SOUND_ENABLED" != true ]; then
        return
    fi
    
    local sound_file="$SOUND_EFFECTS_DIR/${sound_name}.wav"
    
    if [ -f "$sound_file" ]; then
        # For local terminals, be more careful with background processes
        if [ "$IS_SSH_SESSION" = true ]; then
            aplay "$sound_file" >/dev/null 2>&1 &
        else
            # On local terminals, use simpler audio playback to avoid TTY conflicts
            (aplay "$sound_file" >/dev/null 2>&1) &
        fi
    fi
}

# Function to toggle sound effects
toggle_sound_effects() {
    if [ "$SOUND_ENABLED" = true ]; then
        SOUND_ENABLED=false
        show_property_change "Sound effects DISABLED" "Silent mode" "🔇"
    else
        SOUND_ENABLED=true
        show_property_change "Sound effects ENABLED" "Audio feedback active" "🔊"
        echo -e "$DIM_PURPLE[Testing sound effects...]$RESET"
        play_sound_effect "confirm"
    fi
}

# Function to generate hash for static messages
get_message_hash() {
    local message="$1"
    echo -n "$message" | md5sum | cut -d' ' -f1
}

# Function to show property change header
show_property_change() {
    local property="$1"
    local value="$2"
    local icon="$3"
    
    echo ""
    echo -e "$DIM_PURPLE┌─────────────────────────────────────────────────────┐$RESET"
    echo -e "$DIM_PURPLE│ $icon $property: $value$RESET"
    echo -e "$DIM_PURPLE└─────────────────────────────────────────────────────┘$RESET"
    echo ""
}

# Function to make API call to CodeDeck
chat_with_codedeck() {
    local message="$1"
    local response
    
    # Reset interrupt flag
    INTERRUPT_REQUESTED=false
    
    # Play send sound effect
    play_sound_effect "send"
    
    # Show user message in orange
    echo -e "$BRIGHT_ORANGE[You] $message$RESET"
    echo ""
    
    # Add user message to history
    MESSAGE_HISTORY+=("user:$message")
    
    # Show neural transmission indicator
    echo -ne "$DIM_PURPLE[⟁ Transmitting to neural core"
    for i in {1..3}; do
        echo -ne "."
        sleep 0.2
    done
    echo -e " ⟁]$RESET"
    echo -e "$DIM_PURPLE[Press Ctrl+C to interrupt generation]$RESET"
    
    # Build messages array with system message and history
    local messages_json
    messages_json=$(build_messages_json "$message")
    
    # Debug: Show what we're sending (comment out in production)
    # echo "DEBUG: Sending messages: $messages_json" >&2
    
    # Make API call with constructed messages and capture streaming response
    echo -ne "$PURPLE[GLaDOS] $RESET"
    
    # Use a temporary file to capture the full content from streaming
    local temp_content=$(mktemp)
    local in_think_tag=false
    local current_think_content=""
    local think_tag_type=""
    
    # Start generation in background and capture PID
    {
        curl -s -X POST "$CODEDECK_API/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "X-Persona-ID: $GLADOS_PERSONA_ID" \
        -d "{
                \"model\": \"$CURRENT_MODEL\",
                \"messages\": $messages_json,
                \"max_tokens\": 8192,
            \"temperature\": 0.7,
                \"stream\": true
            }" 2>/dev/null | while IFS= read -r line; do
                # Check for interrupt
                if [ "$INTERRUPT_REQUESTED" = true ]; then
                    break
                fi
                
                # Skip empty lines and non-data lines
                if [[ "$line" =~ ^data:\ (.*)$ ]]; then
                    local json_data="${BASH_REMATCH[1]}"
                    
                    # Skip [DONE] marker
                    if [ "$json_data" = "[DONE]" ]; then
                        # Play receive sound effect when response is complete
                        play_sound_effect "receive"
                        break
                    fi
                    
                    # Parse each streaming chunk
                    local token
                    token=$(echo "$json_data" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'choices' in data and len(data['choices']) > 0:
        delta = data['choices'][0].get('delta', {})
        if 'content' in delta:
            print(delta['content'], end='')
except:
    pass
" 2>/dev/null)
                    
                    # Process token with think-tag awareness
                    if [ -n "$token" ]; then
                        echo -n "$token" >> "$temp_content"
                        
                        # Simple think-tag processing - check the accumulated content
                        local full_so_far
                        full_so_far=$(cat "$temp_content" 2>/dev/null)
                        
                        # Count think tags to determine state
                        local think_opens=$(echo "$full_so_far" | grep -o '<think>' | wc -l)
                        local think_closes=$(echo "$full_so_far" | grep -o '</think>' | wc -l)
                        
                        # Are we inside a think tag?
                        local inside_think=false
                        if [ "$think_opens" -gt "$think_closes" ]; then
                            inside_think=true
                        fi
                        
                        # Handle think tag transitions
                        if [[ "$token" == *"<think>"* ]]; then
                            echo -ne "\n$DIM_PURPLE💭 [Internal Thinking]$RESET\n"
                            # Print remaining content after <think> tag
                            local after_tag=$(echo "$token" | sed 's/.*<think>//')
                            if [ -n "$after_tag" ]; then
                                echo -ne "\e[2;90m$after_tag\e[0m"
                            fi
                        elif [[ "$token" == *"</think>"* ]]; then
                            # Print content before </think> tag
                            local before_tag=$(echo "$token" | sed 's/<\/think>.*//')
                            if [ -n "$before_tag" ]; then
                                echo -ne "\e[2;90m$before_tag\e[0m"
                            fi
                            echo -ne "\n$PURPLE"
                            # Print remaining content after </think> tag
                            local after_tag=$(echo "$token" | sed 's/.*<\/think>//')
                            if [ -n "$after_tag" ]; then
                                echo -ne "$after_tag"
                            fi
                        elif [ "$inside_think" = true ]; then
                            # Inside think tag - use very dim gray
                            echo -ne "\e[2;90m$token\e[0m"
                        else
                            # Normal content - use regular purple
                            echo -ne "\e[35m$token\e[0m"
                        fi
                    fi
                fi
            done
    } &
    
    # Capture the background process PID
    GENERATION_PID=$!
    
    # Wait for generation to complete
    wait "$GENERATION_PID" 2>/dev/null
    local generation_exit_code=$?
    
    # Reset generation PID and ensure clean terminal state only if needed
    GENERATION_PID=""
    if [ "$generation_exit_code" -ne 0 ] || [ "$INTERRUPT_REQUESTED" = true ]; then
        if [ "$IS_SSH_SESSION" = true ]; then
            stty sane 2>/dev/null || true
        else
            stty echo 2>/dev/null || true
            stty icanon 2>/dev/null || true
        fi
    fi
    
    echo  # New line after completion
    
    # Read the full content from temp file
    local full_content=""
    if [ -f "$temp_content" ]; then
        full_content=$(cat "$temp_content")
        rm -f "$temp_content"
    fi
    
    # Only process if not interrupted
    if [ "$INTERRUPT_REQUESTED" != true ] && [ -n "$full_content" ]; then
        # Add assistant response to history
        MESSAGE_HISTORY+=("assistant:$full_content")
        
        # If voice is enabled, use TTS to speak the response (clean of think tags)
        if [ "$VOICE_ENABLED" = true ]; then
            speak_routine_message "response" "$full_content"
        fi
    elif [ "$INTERRUPT_REQUESTED" = true ]; then
        # Remove the user message from history since the exchange was interrupted
        if [ ${#MESSAGE_HISTORY[@]} -gt 0 ]; then
            unset 'MESSAGE_HISTORY[-1]'
        fi
        echo -e "$DIM_PURPLE[Generation stopped. You can continue the conversation normally.]$RESET"
    else
        echo -e "$RED🔧 Connection to CODEDECK core failed. Is the service running?$RESET"
        
        # Remove the user message from history since the exchange failed
        if [ ${#MESSAGE_HISTORY[@]} -gt 0 ]; then
            unset 'MESSAGE_HISTORY[-1]'
        fi
    fi
}

# Function to build messages JSON with system message and history
build_messages_json() {
    local current_message="$1"
    
    # Create a temporary file to pass data to Python
    local temp_data=$(mktemp)
    
    # Write configuration to temp file
    echo "SYSTEM_MESSAGE=${SESSION_SYSTEM_MESSAGE}" > "$temp_data"
    echo "CONTEXT_LENGTH=${CONTEXT_LENGTH}" >> "$temp_data"
    echo "CURRENT_MESSAGE=${current_message}" >> "$temp_data"
    echo "HISTORY_START" >> "$temp_data"
    
    # Add history entries (but exclude the current message we just added to avoid duplication)
    for entry in "${MESSAGE_HISTORY[@]}"; do
        # Skip the current user message if it's already in history
        if [[ "$entry" != "user:$current_message" ]]; then
            echo "$entry" >> "$temp_data"
        fi
    done
    
    echo "HISTORY_END" >> "$temp_data"
    
    # Process with Python
    python3 -c "
import json
import sys

# Read the temp file
with open('$temp_data', 'r') as f:
    lines = f.readlines()

messages = []
system_msg = ''
context_length = 5
current_msg = ''
history = []

# Parse the configuration
i = 0
while i < len(lines):
    line = lines[i].strip()
    if line.startswith('SYSTEM_MESSAGE='):
        system_msg = line[15:]  # Remove 'SYSTEM_MESSAGE='
    elif line.startswith('CONTEXT_LENGTH='):
        context_length = int(line[15:])  # Remove 'CONTEXT_LENGTH='
    elif line.startswith('CURRENT_MESSAGE='):
        current_msg = line[16:]  # Remove 'CURRENT_MESSAGE='
    elif line == 'HISTORY_START':
        i += 1
        while i < len(lines) and lines[i].strip() != 'HISTORY_END':
            if lines[i].strip():
                history.append(lines[i].strip())
            i += 1
    i += 1

# Add system message if set
if system_msg:
    messages.append({'role': 'system', 'content': system_msg})

# Add message history (keep last context_length pairs)
if len(history) > context_length * 2:
    # Keep the most recent context_length pairs
    history = history[-(context_length * 2):]

# Add history to messages
for entry in history:
    if ':' in entry:
        role, content = entry.split(':', 1)
        if role in ['user', 'assistant']:
            messages.append({'role': role, 'content': content})

# Add current message
if current_msg:
    messages.append({'role': 'user', 'content': current_msg})

print(json.dumps(messages))
"
    
    # Clean up temp file
    rm -f "$temp_data"
}

# Function to format response with think-tags using cool effects
format_response_with_think_tags() {
    local content="$1"
    
    # Process the content through Python to separate think-tags from regular text
    echo "$content" | python3 -c "
import sys, re

content = sys.stdin.read()

# Define think-tag patterns
think_patterns = [
    (r'<think>(.*?)</think>', 'THINK'),
    (r'<thought>(.*?)</thought>', 'THOUGHT'), 
    (r'<reasoning>(.*?)</reasoning>', 'REASONING'),
    (r'<plan>(.*?)</plan>', 'PLAN'),
    (r'<observe>(.*?)</observe>', 'OBSERVE'),
    (r'<critique>(.*?)</critique>', 'CRITIQUE')
]

# Split content into parts
parts = []
last_end = 0

for pattern, tag_type in think_patterns:
    for match in re.finditer(pattern, content, re.DOTALL | re.IGNORECASE):
        # Add text before the tag
        if match.start() > last_end:
            before_text = content[last_end:match.start()].strip()
            if before_text:
                parts.append(('TEXT', before_text))
        
        # Add the think-tag content
        tag_content = match.group(1).strip()
        if tag_content:
            parts.append((tag_type, tag_content))
        
        last_end = match.end()

# Add remaining text after last tag
if last_end < len(content):
    remaining_text = content[last_end:].strip()
    if remaining_text:
        parts.append(('TEXT', remaining_text))

# If no think-tags found, treat as regular text
if not parts:
    parts.append(('TEXT', content))

# Output the formatted parts
for part_type, text in parts:
    if part_type == 'TEXT':
        print(f'REGULAR:{text}')
    else:
        print(f'{part_type}:{text}')
" | while IFS=':' read -r tag_type text; do
        case "$tag_type" in
            "REGULAR")
                echo -e "$PURPLE[GLaDOS] $text$RESET"
                ;;
            "THINK"|"THOUGHT")
                echo -e "$DIM_PURPLE💭 [Internal Processing]$RESET"
                echo "$text" | lolcat -a -d 1 -s 50 2>/dev/null || echo -e "$CYAN$text$RESET"
                ;;
            "REASONING")
                echo -e "$DIM_PURPLE🧠 [Neural Reasoning]$RESET"
                echo "$text" | lolcat -a -d 1 -s 30 2>/dev/null || echo -e "$BLUE$text$RESET"
                ;;
            "PLAN")
                echo -e "$DIM_PURPLE📋 [Strategic Planning]$RESET"
                echo "$text" | lolcat -a -d 1 -s 40 2>/dev/null || echo -e "$GREEN$text$RESET"
                ;;
            "OBSERVE")
                echo -e "$DIM_PURPLE👁️ [Observation Mode]$RESET"
                echo "$text" | lolcat -a -d 1 -s 60 2>/dev/null || echo -e "$YELLOW$text$RESET"
                ;;
            "CRITIQUE")
                echo -e "$DIM_PURPLE⚖️ [Critical Analysis]$RESET"
                echo "$text" | lolcat -a -d 1 -s 20 2>/dev/null || echo -e "$RED$text$RESET"
                ;;
        esac
    done
}

# Function to speak response using TTS
speak_response() {
    local text_to_speak="$1"
    
    # Remove think-tags and other markup for cleaner speech
    local clean_text
    clean_text=$(echo "$text_to_speak" | python3 -c "
import sys, re
content = sys.stdin.read()
# Remove think-tags and their content
content = re.sub(r'<(think|thought|reasoning|plan|observe|critique)>.*?</\1>', '', content, flags=re.DOTALL | re.IGNORECASE)
# Clean up extra whitespace
content = re.sub(r'\s+', ' ', content).strip()
print(content)
")
    
    if [ -n "$clean_text" ]; then
        echo -ne "$DIM_PURPLE[🔊 Vocalizing response"
        for i in {1..2}; do
            echo -ne "."
            sleep 0.1
        done
        echo -ne "]$RESET"
        
        # Call TTS API with better error handling
        local tts_response
        local http_code
        
        # Create temporary files for response and error capture
        local temp_response=$(mktemp)
        local temp_error=$(mktemp)
        
        # Make the API call with verbose error reporting
        http_code=$(curl -s -w "%{http_code}" -X POST "$CODEDECK_API/v1/tts/speak" \
            -H "Content-Type: application/json" \
            -d "{
                \"text\": \"$clean_text\",
                \"voice\": \"glados\",
                \"speed\": 1.0
            }" -o "$temp_response" 2>"$temp_error")
        
        # Check the response
        if [ "$http_code" = "200" ]; then
            # Check if response contains audio or error message
            local response_content
            response_content=$(head -c 100 "$temp_response" 2>/dev/null)
            
            if echo "$response_content" | grep -q "detail\|error\|html"; then
                echo -e " ✗ (API error)$RESET"
                echo -e "$DIM_PURPLE[TTS Error: $(cat "$temp_response" | head -c 200)]$RESET"
            else
                echo -e " ♪$RESET"
            fi
        elif [ "$http_code" = "000" ]; then
            echo -e " ✗ (connection failed)$RESET"
            echo -e "$DIM_PURPLE[Could not connect to TTS service at $CODEDECK_API]$RESET"
        else
            echo -e " ✗ (HTTP $http_code)$RESET"
            local error_detail
            error_detail=$(cat "$temp_response" 2>/dev/null | head -c 200)
            if [ -n "$error_detail" ]; then
                echo -e "$DIM_PURPLE[TTS Error: $error_detail]$RESET"
            fi
        fi
        
        # Clean up temp files
        rm -f "$temp_response" "$temp_error"
    else
        echo -e "$DIM_PURPLE[🔊 No content to vocalize]$RESET"
    fi
}

# Function to check service status
check_status() {
    local status_response
    echo -e "$DIM_PURPLE[Probing neural interface...]$RESET"
    
    status_response=$(curl -s "$CODEDECK_API/v1/status" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$status_response" ]; then
        echo -e "$GREEN[✓] CODEDECK Neural Interface is ONLINE$RESET"
        echo "$status_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(f'🧠 Status: {data.get(\"status\", \"unknown\")}')
    print(f'⚙️  Model Engine: {data.get(\"model_engine\", \"unknown\")}')
    print(f'🤖 Current Model: {data.get(\"current_model\", \"none\")}')
except:
    print('📊 Raw response received but could not parse status')
"
    else
        echo -e "$RED[✗] CODEDECK Neural Interface is OFFLINE$RESET"
        echo -e "$YELLOW💡 Start the service with: sudo systemctl start codedeck.service$RESET"
    fi
}

# Function to list available personas
list_personas() {
    local personas_response
    echo -e "$DIM_PURPLE[Scanning available consciousness modules...]$RESET"
    
    personas_response=$(curl -s "$CODEDECK_API/v1/personas" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$personas_response" ]; then
        echo "$personas_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    personas = data.get('data', [])
    print(f'Found {len(personas)} consciousness modules:')
    for p in personas:
        print(f'  {p.get(\"icon\", \"🤖\")} {p.get(\"name\", \"Unknown\")} ({p.get(\"id\", \"no-id\")})')
        print(f'    {p.get(\"description\", \"No description\")}')
except Exception as e:
    print('Could not parse personas list')
"
    else
        echo -e "$RED[✗] Could not retrieve personas list$RESET"
    fi
}

# Function to switch persona
switch_persona() {
    local persona_name="$1"
    echo -e "$DIM_PURPLE[Switching consciousness module to: $persona_name]$RESET"
    
    # For now, just update the ID - in a more advanced version, 
    # we could lookup by name from the personas list
    case "$persona_name" in
        "glados"|"default")
            GLADOS_PERSONA_ID="assistant-default"
            echo -e "$GREEN[✓] Switched to GLaDOS (Default Assistant)$RESET"
            ;;
        "coder")
            GLADOS_PERSONA_ID="coder-expert"
            echo -e "$GREEN[✓] Switched to Code Expert$RESET"
            ;;
        "writer")
            GLADOS_PERSONA_ID="creative-writer"
            echo -e "$GREEN[✓] Switched to Creative Writer$RESET"
            ;;
        *)
            echo -e "$YELLOW[!] Unknown persona. Available: glados, coder, writer$RESET"
            ;;
    esac
}

# Function to toggle voice responses
toggle_voice() {
    if [ "$VOICE_ENABLED" = true ]; then
        VOICE_ENABLED=false
        play_sound_effect "confirm"
        show_property_change "Voice responses DISABLED" "Text only mode" "🔇"
    else
        VOICE_ENABLED=true
        play_sound_effect "confirm"
        show_property_change "Voice responses ENABLED" "GLaDOS voice active" "🔊"
        echo -e "$DIM_PURPLE[Testing voice...]$RESET"
        speak_routine_message "voice_activated" "Voice active."
    fi
}

# Function to set session system message
set_system_message() {
    local new_system_message="$1"
    
    if [ -z "$new_system_message" ]; then
        if [ -z "$SESSION_SYSTEM_MESSAGE" ]; then
            echo -e "$YELLOW[!] No system message currently set$RESET"
        else
            echo -e "$GREEN[ℹ] Current system message:$RESET"
            echo -e "$DIM_PURPLE    $SESSION_SYSTEM_MESSAGE$RESET"
        fi
        echo -e "$DIM_PURPLE    Usage: system <message> - Set system message for this session$RESET"
        echo -e "$DIM_PURPLE    Usage: system clear - Remove system message$RESET"
        return
    fi
    
    if [ "$new_system_message" = "clear" ]; then
        SESSION_SYSTEM_MESSAGE=""
        play_sound_effect "confirm"
        show_property_change "System message cleared" "Using persona default" "🧠"
        
        if [ "$VOICE_ENABLED" = true ]; then
            speak_routine_message "system_cleared" "System directive cleared."
        fi
        return
    fi
    
    SESSION_SYSTEM_MESSAGE="$new_system_message"
    play_sound_effect "confirm"
    show_property_change "System message updated" "${new_system_message:0:50}..." "🧠"
    
    if [ "$VOICE_ENABLED" = true ]; then
        speak_routine_message "system_updated" "New system directive loaded."
    fi
}

# Function to set context length
set_context_length() {
    local new_length="$1"
    
    if [ -z "$new_length" ]; then
        echo -e "$GREEN[ℹ] Current context length: $CONTEXT_LENGTH message pairs$RESET"
        echo -e "$DIM_PURPLE    Usage: context <number> - Set number of message pairs to remember$RESET"
        return
    fi
    
    if ! [[ "$new_length" =~ ^[0-9]+$ ]] || [ "$new_length" -lt 0 ] || [ "$new_length" -gt 20 ]; then
        echo -e "$RED[✗] Context length must be a number between 0 and 20$RESET"
        return
    fi
    
    CONTEXT_LENGTH="$new_length"
    play_sound_effect "confirm"
    show_property_change "Context length updated" "$CONTEXT_LENGTH message pairs" "📚"
    
    if [ "$VOICE_ENABLED" = true ]; then
        speak_routine_message "context_updated_$new_length" "Context memory updated to $new_length pairs."
    fi
}

# Function to clear conversation history
clear_context() {
    MESSAGE_HISTORY=()
    play_sound_effect "confirm"
    show_property_change "Conversation context cleared" "Memory wiped" "🗑️"
    
    if [ "$VOICE_ENABLED" = true ]; then
        speak_routine_message "memory_wiped" "Memory wiped."
    fi
}

# Function to show current session status
show_session_status() {
    echo -e "$DIM_PURPLE"
    echo "═══════════════════════════════════════════════════════════════"
    echo "                     SESSION STATUS"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "$RESET"
    
    echo -e "$GREEN🧠 System Message:$RESET"
    if [ -z "$SESSION_SYSTEM_MESSAGE" ]; then
        echo -e "$DIM_PURPLE    (none set - using persona default)$RESET"
    else
        echo -e "$DIM_PURPLE    $SESSION_SYSTEM_MESSAGE$RESET"
    fi
    echo ""
    
    echo -e "$GREEN📚 Context Settings:$RESET"
    echo -e "$DIM_PURPLE    Length: $CONTEXT_LENGTH message pairs$RESET"
    echo -e "$DIM_PURPLE    History: ${#MESSAGE_HISTORY[@]} messages stored$RESET"
    echo ""
    
    echo -e "$GREEN🔊 Voice Status:$RESET"
    if [ "$VOICE_ENABLED" = true ]; then
        echo -e "$DIM_PURPLE    ENABLED (GLaDOS voice)$RESET"
    else
        echo -e "$DIM_PURPLE    DISABLED (text only)$RESET"
    fi
    echo ""
}

# Function to list and select models
manage_models() {
    local action="$1"
    local model_name="$2"
    
    if [ "$action" = "list" ] || [ -z "$action" ]; then
        echo -e "$DIM_PURPLE[Scanning available neural models...]$RESET"
        
        local models_response
        models_response=$(curl -s "$CODEDECK_API/v1/models" 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$models_response" ]; then
            echo "$models_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', [])
    print(f'Available models ({len(models)} found):')
    for i, model in enumerate(models):
        name = model.get('id', 'unknown')
        desc = model.get('description', 'No description')
        loaded = model.get('loaded', False)
        status = '🟢 LOADED' if loaded else '⚪ Available'
        current = ' <- CURRENT' if name == '$CURRENT_MODEL' else ''
        print(f'  {i+1}. {status} {name}{current}')
        print(f'     {desc}')
    print()
    print('Usage: model select <name> - Load and switch to a model')
except Exception as e:
    print('Could not parse models list')
    print(f'Error: {e}', file=sys.stderr)
"
        else
            echo -e "$RED[✗] Could not retrieve models list$RESET"
        fi
        
    elif [ "$action" = "select" ]; then
        if [ -z "$model_name" ]; then
            echo -e "$YELLOW[!] Usage: model select <model_name>$RESET"
            return
        fi
        
        echo -e "$DIM_PURPLE[Loading neural model: $model_name]$RESET"
        
        # Try to load the model
        local load_response
        load_response=$(curl -s -X POST "$CODEDECK_API/v1/models/$model_name/load" 2>/dev/null)
        
        if [ $? -eq 0 ]; then
            local success
            success=$(echo "$load_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data.get('status') == 'success':
        print('true')
        print(f'Model: {data.get(\"current_model\", \"unknown\")}', file=sys.stderr)
    else:
        print('false')
        print(f'Error: {data.get(\"detail\", \"Unknown error\")}', file=sys.stderr)
except:
    print('false')
")
            
            if [ "$success" = "true" ]; then
                CURRENT_MODEL="$model_name"
                play_sound_effect "switch"
                show_property_change "Model switched" "$model_name" "🤖"
                
                if [ "$VOICE_ENABLED" = true ]; then
                    speak_routine_message "model_switched" "Neural model $model_name loaded."
                fi
            else
                echo -e "$RED[✗] Failed to load model '$model_name'$RESET"
            fi
        else
            echo -e "$RED[✗] Could not connect to load model$RESET"
        fi
        
    else
        echo -e "$YELLOW[!] Usage:$RESET"
        echo -e "$DIM_PURPLE    model           - List available models$RESET"
        echo -e "$DIM_PURPLE    model list      - List available models$RESET"
        echo -e "$DIM_PURPLE    model select <name> - Load and switch to model$RESET"
    fi
}

# Function to display help
show_help() {
    echo -e "$DIM_PURPLE"
    echo "═══════════════════════════════════════════════════════════════"
    echo "                    CODEDECK CONSOLE COMMANDS"
    echo "═══════════════════════════════════════════════════════════════"
    echo "🗨️  CHAT:"
    echo "   <message>        - Chat with current AI persona"
    echo "   help/h/?         - Show this help message"
    echo ""
    echo "🔧 SYSTEM:"
    echo "   status           - Check CODEDECK service status"
    echo "   battery          - Show battery status and check warnings"
    echo "   session          - Show current session status"
    echo -e "$RESET"
    echo -e "$YELLOW[Press any key to continue...]$RESET"
    read -n 1 -s
    
    echo -e "$DIM_PURPLE"
    echo "👤 PERSONAS & MODELS:"
    echo "   personas         - List available consciousness modules"
    echo "   switch <name>    - Switch AI persona (glados, coder, writer)"
    echo "   model            - List available models"
    echo "   model select <n> - Load and switch to a specific model"
    echo ""
    echo "🧠 CONTEXT MANAGEMENT:"
    echo "   system <msg>     - Set system message for this session"
    echo "   system clear     - Remove current system message"
    echo "   system           - Show current system message"
    echo -e "$RESET"
    echo -e "$YELLOW[Press any key to continue...]$RESET"
    read -n 1 -s
    
    echo -e "$DIM_PURPLE"
    echo "📚 MEMORY:"
    echo "   context <num>    - Set context length (0-20 message pairs)"
    echo "   context          - Show current context length"
    echo "   clear            - Clear conversation history"
    echo ""
    echo "🔊 AUDIO:"
    echo "   speak            - Toggle voice responses (text + audio)"
    echo "   sound            - Toggle sound effects (UI feedback sounds)"
    echo "   hear             - Record 10s of audio and convert to text input"
    echo "   audio-diag       - Run comprehensive audio system diagnostics"
    echo ""
    echo "🎮 INTERFACE:"
    echo "   cls              - Clear the console display"
    echo "   recover/fix      - Fix input issues / recover terminal state"
    echo "   cache-purge      - Delete all cached voice clips (free space)"
    echo "   exit/quit/q      - Exit the console"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "$RESET"
}

# Function to initialize console
init_console() {
    echo -e "$PURPLE"
    cat << "EOF"
    ╔═══════════════════════════════════════════════════════╗
    ║                    CODEDECK CONSOLE                       ║
    ║                  Neural Chat Interface                    ║
    ╚═══════════════════════════════════════════════════════╝
EOF
    echo -e "$RESET"
    echo ""
    echo -e "$DIM_PURPLE𓁹 GLaDOS consciousness module loaded...$RESET"
    
    # Play startup sound
    play_sound_effect "start"
    
    # Show battery status on startup
    echo -ne "$DIM_PURPLE[Checking power status..."
    sleep 0.1
    echo -e "]$RESET"
    show_battery_status
    
    echo -e "$PURPLE[GLaDOS] Well, well, well. Look who's decided to interface with me directly.$RESET"
    echo -e "$DIM_PURPLE💡 Type 'help' for available commands$RESET"
    echo -e "$DIM_PURPLE🎨 Colors: $BRIGHT_ORANGE[Your messages]$DIM_PURPLE, $PURPLE[AI replies]$DIM_PURPLE, $CYAN[Think-tags with cool effects]$RESET"
    
    # Voice status
    local voice_status="$RED[DISABLED]"
    if [ "$VOICE_ENABLED" = true ]; then
        voice_status="$GREEN[ENABLED]"
    fi
    
    # Sound effects status
    local sound_status="$GREEN[ENABLED]"
    if [ "$SOUND_ENABLED" != true ]; then
        sound_status="$RED[DISABLED]"
    fi
    
    echo -e "$DIM_PURPLE🔊 Voice: $voice_status$DIM_PURPLE - Type 'speak' to toggle | 🎵 Sound: $sound_status$DIM_PURPLE - Type 'sound' to toggle$RESET"
    echo -e "$DIM_PURPLE📚 Context: $CONTEXT_LENGTH pairs | 🧠 System: ${SESSION_SYSTEM_MESSAGE:-"(default)"} | 🤖 Model: $CURRENT_MODEL$RESET"
    echo ""
}

# ── VOICE RECORDING FUNCTIONS ──

# Function to run comprehensive audio diagnostics
audio_diagnostics() {
    echo -e "$DIM_PURPLE"
    echo "═══════════════════════════════════════════════════════════════"
    echo "                   AUDIO SYSTEM DIAGNOSTICS"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "$RESET"
    
    # 1. Check basic audio tools
    echo -e "$CYAN[1/8] Checking audio tools...$RESET"
    local tools_ok=true
    
    if command -v arecord >/dev/null 2>&1; then
        echo -e "$GREEN  ✓ arecord found: $(which arecord)$RESET"
    else
        echo -e "$RED  ✗ arecord not found$RESET"
        tools_ok=false
    fi
    
    if command -v aplay >/dev/null 2>&1; then
        echo -e "$GREEN  ✓ aplay found: $(which aplay)$RESET"
    else
        echo -e "$RED  ✗ aplay not found$RESET"
        tools_ok=false
    fi
    
    if [ "$tools_ok" = false ]; then
        echo -e "$YELLOW  💡 Install with: sudo apt install alsa-utils$RESET"
        return 1
    fi
    
    # 2. Check user permissions
    echo -e "$CYAN[2/8] Checking user permissions...$RESET"
    local audio_group=false
    
    if groups | grep -q audio 2>/dev/null; then
        echo -e "$GREEN  ✓ User is in audio group$RESET"
        audio_group=true
    else
        echo -e "$YELLOW  ⚠ User not in audio group$RESET"
        echo -e "$DIM_PURPLE     Fix: sudo usermod -a -G audio $(whoami)$RESET"
        echo -e "$DIM_PURPLE     Then logout/login$RESET"
    fi
    
    # 3. Check /dev/snd permissions
    echo -e "$CYAN[3/8] Checking device permissions...$RESET"
    if [ -d /dev/snd ]; then
        echo -e "$GREEN  ✓ /dev/snd directory exists$RESET"
        local snd_perms=$(ls -la /dev/snd/ | head -5)
        echo -e "$DIM_PURPLE  Device permissions:$RESET"
        echo "$snd_perms" | while read line; do
            echo -e "$DIM_PURPLE    $line$RESET"
        done
        
        # Check if controlC* devices are accessible
        local control_access=false
        for ctrl in /dev/snd/controlC*; do
            if [ -r "$ctrl" ] && [ -w "$ctrl" ]; then
                control_access=true
                break
            fi
        done
        
        if [ "$control_access" = true ]; then
            echo -e "$GREEN  ✓ Audio control devices accessible$RESET"
        else
            echo -e "$YELLOW  ⚠ Audio control devices not accessible$RESET"
            echo -e "$DIM_PURPLE     Fix: sudo chmod 666 /dev/snd/*$RESET"
        fi
    else
        echo -e "$RED  ✗ /dev/snd directory not found$RESET"
    fi
    
    # 4. List available recording devices
    echo -e "$CYAN[4/8] Listing recording devices...$RESET"
    local device_list
    device_list=$(arecord -l 2>/dev/null)
    
    if [ -n "$device_list" ]; then
        echo -e "$GREEN  ✓ Recording devices found:$RESET"
        echo "$device_list" | while read line; do
            if [[ "$line" =~ ^card.*device ]]; then
                echo -e "$DIM_PURPLE    $line$RESET"
            fi
        done
    else
        echo -e "$RED  ✗ No recording devices found$RESET"
        echo -e "$YELLOW  💡 Check microphone connection$RESET"
        return 1
    fi
    
    # 5. Test device access with different methods
    echo -e "$CYAN[5/8] Testing device access...$RESET"
    local test_devices=("default" "hw:0,0" "hw:1,0" "plughw:0,0" "plughw:1,0")
    local working_devices=()
    
    for device in "${test_devices[@]}"; do
        echo -ne "$DIM_PURPLE  Testing $device..."
        
        # Try to open device for 0.1 seconds
        if timeout 2s arecord -D "$device" -f S16_LE -r 16000 -c 1 -d 0.1 /dev/null >/dev/null 2>&1; then
            echo -e " ✓$RESET"
            working_devices+=("$device")
        else
            echo -e " ✗$RESET"
        fi
    done
    
    if [ ${#working_devices[@]} -eq 0 ]; then
        echo -e "$RED  ✗ No devices accessible for recording$RESET"
        return 1
    else
        echo -e "$GREEN  ✓ Working devices: ${working_devices[*]}$RESET"
    fi
    
    # 6. Test actual recording with best device
    echo -e "$CYAN[6/8] Testing 2-second recording...$RESET"
    local best_device="${working_devices[0]}"
    local test_file="/tmp/audio_test_$(date +%s).wav"
    
    echo -e "$DIM_PURPLE  Recording 2 seconds with device: $best_device$RESET"
    echo -e "$BRIGHT_ORANGE  [Speak now for 2 seconds...]$RESET"
    
    if arecord -D "$best_device" -f S16_LE -r 16000 -c 1 -d 2 "$test_file" >/dev/null 2>&1; then
        if [ -f "$test_file" ] && [ -s "$test_file" ]; then
            local file_size
            file_size=$(stat -f%z "$test_file" 2>/dev/null || stat -c%s "$test_file" 2>/dev/null || echo 0)
            echo -e "$GREEN  ✓ Recording successful: $file_size bytes$RESET"
            
            # 7. Test playback
            echo -e "$CYAN[7/8] Testing playback...$RESET"
            echo -e "$DIM_PURPLE  Playing back your recording...$RESET"
            
            if aplay "$test_file" >/dev/null 2>&1; then
                echo -e "$GREEN  ✓ Playback successful$RESET"
            else
                echo -e "$YELLOW  ⚠ Playback failed (recording worked though)$RESET"
            fi
            
            rm -f "$test_file"
        else
            echo -e "$RED  ✗ Recording file empty or missing$RESET"
            rm -f "$test_file"
            return 1
        fi
    else
        echo -e "$RED  ✗ Recording failed$RESET"
        rm -f "$test_file"
        return 1
    fi
    
    # 8. Test API connectivity
    echo -e "$CYAN[8/8] Testing CodeDeck API connectivity...$RESET"
    local api_status
    api_status=$(curl -s --connect-timeout 5 "$CODEDECK_API/v1/status" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$api_status" ]; then
        echo -e "$GREEN  ✓ CodeDeck API accessible$RESET"
        
        # Check if transcription endpoint exists
        local transcription_test
        transcription_test=$(curl -s --connect-timeout 5 -I "$CODEDECK_API/v1/audio/transcriptions" 2>/dev/null | head -1)
        
        if echo "$transcription_test" | grep -q "200\|405\|400"; then
            echo -e "$GREEN  ✓ Transcription endpoint accessible$RESET"
        else
            echo -e "$YELLOW  ⚠ Transcription endpoint may not be available$RESET"
        fi
    else
        echo -e "$RED  ✗ CodeDeck API not accessible at $CODEDECK_API$RESET"
        echo -e "$YELLOW  💡 Make sure CodeDeck service is running$RESET"
    fi
    
    # Summary
    echo ""
    echo -e "$DIM_PURPLE═══════════════════════════════════════════════════════════════$RESET"
    echo -e "$GREEN✓ AUDIO DIAGNOSTICS COMPLETE$RESET"
    echo -e "$DIM_PURPLE═══════════════════════════════════════════════════════════════$RESET"
    echo ""
    echo -e "$BRIGHT_ORANGE🎤 Recommended device: $best_device$RESET"
    
    if [ "$audio_group" = false ]; then
        echo -e "$YELLOW⚠ Action needed: Add user to audio group$RESET"
    else
        echo -e "$GREEN🎤 Audio system appears ready for voice input!$RESET"
    fi
}

# Function to detect recording device (simplified version)
detect_recording_device() {
    # Find USB Audio device from arecord -l
    local usb_device
    usb_device=$(arecord -l 2>/dev/null | grep "USB Audio" | head -1 | grep -o "card [0-9]*" | grep -o "[0-9]*")
    
    if [ -n "$usb_device" ]; then
        echo "plughw:${usb_device},0"
        return 0
    fi
    
    # Fallback to default
    echo "default"
    return 0
}

# Function to record voice and convert to text
hear_command() {
    echo -e "$DIM_PURPLE[🎤 Initializing voice input...]$RESET"
    
    # Quick device detection
    local recording_device
    recording_device=$(detect_recording_device)
    
    if [ $? -ne 0 ]; then
        echo -e "$RED[✗] No working recording device found$RESET"
        echo -e "$YELLOW💡 Run 'audio-diag' for detailed diagnostics$RESET"
        return 1
    fi
    
    echo -e "$GREEN[✓ Using device: $recording_device]$RESET"
    
    # Ensure recording cache directory exists and create temp file
    mkdir -p "$RECORDING_CACHE_DIR" 2>/dev/null
    local temp_audio="$RECORDING_CACHE_DIR/codedeck_recording_$(date +%s)_$$.wav"
    
    echo ""
    echo -e "$GREEN[🔴 RECORDING - Speak clearly for 10 seconds!]$RESET"
    echo ""
    
    # Start recording
    arecord -D "$recording_device" -f S16_LE -r 16000 -c 1 -d 10 "$temp_audio" >/dev/null 2>&1 &
    local record_pid=$!
    
    # Countdown
    for i in {10..1}; do
        printf "\r$BRIGHT_ORANGE[🎤 RECORDING: %2ds remaining]$RESET" "$i"
        sleep 1
    done
    
    wait "$record_pid" 2>/dev/null
    local record_exit_code=$?
    
    printf "\r$DIM_PURPLE[🎤 Processing...]$RESET\n"
    
    # Validate recording
    if [ "$record_exit_code" -ne 0 ] || [ ! -f "$temp_audio" ] || [ ! -s "$temp_audio" ]; then
        echo -e "$RED[✗] Recording failed$RESET"
        echo -e "$YELLOW💡 Run 'audio-diag' for troubleshooting$RESET"
        rm -f "$temp_audio"
        return 1
    fi
    
    local file_size
    file_size=$(stat -f%z "$temp_audio" 2>/dev/null || stat -c%s "$temp_audio" 2>/dev/null || echo 0)
    
    if [ "$file_size" -lt 1000 ]; then
        echo -e "$RED[✗] Recording too small ($file_size bytes)$RESET"
        echo -e "$YELLOW💡 Try speaking louder$RESET"
        rm -f "$temp_audio"
        return 1
    fi
    
    echo -e "$GREEN[✓ Recording captured: ${file_size} bytes]$RESET"
    
    # Send to API
    local temp_response="/tmp/codedeck_response_$(date +%s)_$$.json"
    local http_code
    
    http_code=$(curl -s -w "%{http_code}" -X POST "$CODEDECK_API/v1/audio/transcriptions" \
        -H "Content-Type: multipart/form-data" \
        -F "file=@$temp_audio" \
        -F "model=whisper" \
        -o "$temp_response" 2>/dev/null)
    
    if [ "$http_code" = "200" ]; then
        local transcription
        transcription=$(cat "$temp_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'text' in data:
        print(data['text'].strip())
    elif 'transcription' in data:
        print(data['transcription'].strip())
    else:
        print('')
except:
    print('')
")
        
        if [ -n "$transcription" ]; then
            echo -e "$GREEN[✓ Speech recognized]$RESET"
            echo ""
            play_sound_effect "confirm"
            chat_with_codedeck "$transcription"
            echo ""
        else
            echo -e "$YELLOW[!] No speech detected$RESET"
        fi
    else
        echo -e "$RED[✗ API failed (HTTP $http_code)]$RESET"
    fi
    
    rm -f "$temp_response" "$temp_audio"
}

# ── MAIN CONSOLE LOOP ──

# Initialize the console
init_console

# Show session type for debugging
if [ "$IS_SSH_SESSION" = true ]; then
    echo -e "$DIM_PURPLE[SSH session detected - using SSH-optimized terminal handling]$RESET"
else
    echo -e "$DIM_PURPLE[Local session detected - using local-optimized terminal handling]$RESET"
fi

# Counter for battery check interval
BATTERY_CHECK_COUNTER=0
INPUT_ERROR_COUNT=0  # Track consecutive input errors

# Main interactive loop
while true; do
    # Only recover terminal state if we've had recent input errors
    # This removes the aggressive recovery that was causing issues
    if [ $INPUT_ERROR_COUNT -gt 2 ]; then
        echo -e "$YELLOW[!] Multiple input errors detected, attempting recovery...$RESET"
        recover_terminal_state
        INPUT_ERROR_COUNT=0
    fi
    
    # Check battery every 10 interactions
    if [ $((BATTERY_CHECK_COUNTER % 10)) -eq 0 ]; then
        check_battery_warnings
    fi
    BATTERY_CHECK_COUNTER=$((BATTERY_CHECK_COUNTER + 1))
    
    # Stylized prompt
    echo -ne "\e[1;35m╭─[CODEDECK]─[$(date +%H:%M:%S)]"
    echo -ne "\n╰─➤ \e[0m"
    
    # Read input with improved error handling
    user_input=""
    if read -r user_input 2>/dev/null; then
        # Successfully read input - reset error counter
        INPUT_ERROR_COUNT=0
    else
        # Input failed
        INPUT_ERROR_COUNT=$((INPUT_ERROR_COUNT + 1))
        echo -e "\n$YELLOW[!] Input error $INPUT_ERROR_COUNT detected$RESET"
        
        if [ $INPUT_ERROR_COUNT -le 2 ]; then
            echo -e "$DIM_PURPLE[Retrying input...]$RESET"
            sleep 0.1
            continue
        else
            echo -e "$RED[!] Multiple input failures - trying terminal recovery$RESET"
            recover_terminal_state
            continue
        fi
    fi
    
    # Handle empty input
    if [ -z "$user_input" ]; then
        continue
    fi
    
    # Parse commands
    command=$(echo "$user_input" | awk '{print $1}')
    args=$(echo "$user_input" | cut -d' ' -f2-)
    
    case "$command" in
        "exit"|"quit"|"q")
            echo -e "$DIM_PURPLE[GLaDOS] Goodbye. Try not to miss me too much.$RESET"
            echo -e "$PURPLE𐑄⟁⌁ Console session terminated ⌁⟁𐑄$RESET"
            break
            ;;
        "help"|"h"|"?")
            show_help
            ;;
        "status")
            check_status
            ;;
        "battery")
            check_battery_command
            ;;
        "session")
            show_session_status
            ;;
        "personas")
            list_personas
            ;;
        "switch")
            if [ "$args" != "$command" ]; then
                switch_persona "$args"
            else
                echo -e "$YELLOW[!] Usage: switch <persona_name>$RESET"
            fi
            ;;
        "model")
            if [ "$args" != "$command" ]; then
                # Parse model subcommand
                model_action=$(echo "$args" | awk '{print $1}')
                model_name=$(echo "$args" | cut -d' ' -f2-)
                if [ "$model_name" = "$model_action" ]; then
                    model_name=""
                fi
                manage_models "$model_action" "$model_name"
            else
                manage_models "list"
            fi
            ;;
        "speak")
            toggle_voice
            ;;
        "system")
            if [ "$args" != "$command" ]; then
                set_system_message "$args"
            else
                set_system_message ""
            fi
            ;;
        "context")
            if [ "$args" != "$command" ]; then
                set_context_length "$args"
            else
                set_context_length ""
            fi
            ;;
        "clear")
            clear_context
            ;;
        "cls")
            clear
            init_console
            ;;
        "sound")
            toggle_sound_effects
            ;;
        "recover"|"fix")
            recover_terminal_state
            INPUT_ERROR_COUNT=0
            ;;
        "hear")
            hear_command
            ;;
        "cache-purge")
            purge_cognitive_cache
            ;;
        "audio-diag")
            audio_diagnostics
            ;;
        *)
            # Chat with current AI persona (user message display now handled in function)
            chat_with_codedeck "$user_input"
            echo ""
            ;;
    esac
done 
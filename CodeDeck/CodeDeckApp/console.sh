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

# ── SESSION STATE ──
SESSION_SYSTEM_MESSAGE=""  # Current session system message
MESSAGE_HISTORY=()  # Array to store conversation history
CONTEXT_LENGTH=5  # Number of message pairs to include in context
CURRENT_MODEL="$DEFAULT_MODEL"  # Currently selected model

# ── API COMMUNICATION FUNCTIONS ──

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
    
    # Build messages array with system message and history
    local messages_json
    messages_json=$(build_messages_json "$message")
    
    # Debug: Show what we're sending (comment out in production)
    # echo "DEBUG: Sending messages: $messages_json" >&2
    
    # Make API call with constructed messages and capture streaming response
    echo -ne "$PURPLE[GLaDOS] $RESET"
    
    # Use a temporary file to capture the full content from streaming
    local temp_content=$(mktemp)
    
    curl -s -X POST "$CODEDECK_API/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "X-Persona-ID: $GLADOS_PERSONA_ID" \
        -d "{
            \"model\": \"$CURRENT_MODEL\",
            \"messages\": $messages_json,
            \"max_tokens\": 150,
            \"temperature\": 0.7,
            \"stream\": true
        }" 2>/dev/null | while IFS= read -r line; do
            # Skip empty lines and non-data lines
            if [[ "$line" =~ ^data:\ (.*)$ ]]; then
                local json_data="${BASH_REMATCH[1]}"
                
                # Skip [DONE] marker
                if [ "$json_data" = "[DONE]" ]; then
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
                
                # Display token immediately and save to temp file
                if [ -n "$token" ]; then
                    echo -ne "$PURPLE$token$RESET"
                    echo -n "$token" >> "$temp_content"
                fi
            fi
        done
    
    echo  # New line after completion
    
    # Read the full content from temp file
    local full_content=""
    if [ -f "$temp_content" ]; then
        full_content=$(cat "$temp_content")
        rm -f "$temp_content"
    fi
    
    # Add assistant response to history
    if [ -n "$full_content" ]; then
        MESSAGE_HISTORY+=("assistant:$full_content")
        
        # If voice is enabled, use TTS to speak the response
        if [ "$VOICE_ENABLED" = true ]; then
            speak_response "$full_content"
        fi
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
        echo -e " 🔊]$RESET"
        
        # Call TTS API
        curl -s -X POST "$CODEDECK_API/v1/tts/speak" \
            -H "Content-Type: application/json" \
            -d "{
                \"text\": \"$clean_text\",
                \"voice\": \"glados\",
                \"speed\": 1.0
            }" > /dev/null 2>&1
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
        show_property_change "Voice responses DISABLED" "Text only mode" "🔇"
    else
        VOICE_ENABLED=true
        show_property_change "Voice responses ENABLED" "GLaDOS voice active" "🔊"
        echo -e "$DIM_PURPLE[Testing voice...]$RESET"
        speak_response "Voice active."
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
        show_property_change "System message cleared" "Using persona default" "🧠"
        
        if [ "$VOICE_ENABLED" = true ]; then
            speak_response "System directive cleared."
        fi
        return
    fi
    
    SESSION_SYSTEM_MESSAGE="$new_system_message"
    show_property_change "System message updated" "${new_system_message:0:50}..." "🧠"
    
    if [ "$VOICE_ENABLED" = true ]; then
        speak_response "New system directive loaded."
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
    show_property_change "Context length updated" "$CONTEXT_LENGTH message pairs" "📚"
    
    if [ "$VOICE_ENABLED" = true ]; then
        speak_response "Context memory updated to $new_length pairs."
    fi
}

# Function to clear conversation history
clear_context() {
    MESSAGE_HISTORY=()
    show_property_change "Conversation context cleared" "Memory wiped" "🗑️"
    
    if [ "$VOICE_ENABLED" = true ]; then
        speak_response "Memory wiped."
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
                show_property_change "Model switched" "$model_name" "🤖"
                
                if [ "$VOICE_ENABLED" = true ]; then
                    speak_response "Neural model $model_name loaded."
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
    echo ""
    echo "🗨️  CHAT:"
    echo "   <message>        - Chat with current AI persona"
    echo ""
    echo "🔧 SYSTEM:"
    echo "   help             - Show this help message"
    echo "   status           - Check CODEDECK service status"
    echo "   session          - Show current session status"
    echo "   personas         - List available consciousness modules"
    echo "   switch <name>    - Switch AI persona (glados, coder, writer)"
    echo "   model            - List available models"
    echo "   model select <n> - Load and switch to a specific model"
    echo ""
    echo "🧠 CONTEXT MANAGEMENT:"
    echo "   system <msg>     - Set system message for this session"
    echo "   system clear     - Remove current system message"
    echo "   system           - Show current system message"
    echo "   context <num>    - Set context length (0-20 message pairs)"
    echo "   context          - Show current context length"
    echo "   clear            - Clear conversation history"
    echo ""
    echo "🔊 VOICE:"
    echo "   speak            - Toggle voice responses (text + audio)"
    echo ""
    echo "🎮 INTERFACE:"
    echo "   cls              - Clear the console display"
    echo "   exit             - Exit the console"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "$RESET"
}

# Function to initialize console
init_console() {
    echo -e "$PURPLE"
    cat << "EOF"
    ╔═══════════════════════════════════════════════════════════╗
    ║                    CODEDECK CONSOLE                       ║
    ║                  Neural Chat Interface                    ║
    ╚═══════════════════════════════════════════════════════════╝
EOF
    echo -e "$RESET"
    echo ""
    echo -e "$DIM_PURPLE𓁹 GLaDOS consciousness module loaded...$RESET"
    echo -e "$PURPLE[GLaDOS] Well, well, well. Look who's decided to interface with me directly.$RESET"
    echo -e "$DIM_PURPLE💡 Type 'help' for available commands$RESET"
    echo -e "$DIM_PURPLE🎨 Colors: $BRIGHT_ORANGE[Your messages]$DIM_PURPLE, $PURPLE[AI replies]$DIM_PURPLE, $CYAN[Think-tags with cool effects]$RESET"
    echo -e "$DIM_PURPLE🔊 Voice: $RED[DISABLED]$DIM_PURPLE - Type 'speak' to enable audio responses$RESET"
    echo -e "$DIM_PURPLE📚 Context: $CONTEXT_LENGTH pairs | 🧠 System: ${SESSION_SYSTEM_MESSAGE:-"(default)"} | 🤖 Model: $CURRENT_MODEL$RESET"
    echo ""
}

# ── MAIN CONSOLE LOOP ──

# Initialize the console
init_console

# Main interactive loop
while true; do
    # Stylized prompt
    echo -ne "\e[1;35m╭─[CODEDECK]─[$(date +%H:%M:%S)]"
    echo -ne "\n╰─➤ \e[0m"
    read -r user_input
    
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
        *)
            # Chat with current AI persona (user message display now handled in function)
            chat_with_codedeck "$user_input"
            echo ""
            ;;
    esac
done 
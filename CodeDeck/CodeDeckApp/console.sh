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

# ── SILICON-SPECIFIC COLORS ──
SILICON_PURPLE="\e[1;95m"    # Bright magenta/purple for Silicon responses
SILICON_DIM="\e[2;95m"       # Dim bright magenta for Silicon debug
SILICON_GREEN="\e[1;92m"     # Bright green for Silicon success messages

# ── DEBUG LOGGING ──
debug_log() {
    if [ "$DEBUG_ENABLED" = true ]; then
        echo -e "$DIM_PURPLE[DEBUG: $*]$RESET" >&2
    fi
}

# ── CONFIGURATION ──
CODEDECK_API="http://codedeck.local:8000"
GLADOS_PERSONA_ID="assistant-default"  # Default assistant persona
DEFAULT_MODEL="deepseek_r1_distill_qwen_1_5b_q4_0"  # Current available model
VOICE_ENABLED=false  # Toggle for voice responses
STREAMING_SPEECH_ENABLED=false  # Toggle for real-time sentence-based speech streaming
DEBUG_ENABLED=false  # Toggle for debug output

# ── VIRTUAL ENVIRONMENT CONFIGURATION ──
CODEDECK_VENV_PATH="/home/codemusic/CodeDeck/codedeck_venv"  # Path to CodeDeck virtual environment

# ── VOICE MODELS CONFIGURATION ──
VOICE_MODELS_DIR="$HOME/CodeDeck/voice_models"  # Directory containing Piper voice models
DEFAULT_VOICE="en_US-GlaDOS-medium.onnx"  # Default voice model
CURRENT_VOICE="$DEFAULT_VOICE"  # Currently selected voice model

# ── SILICON PIPELINE CONFIGURATION ──
ENABLE_SILICON_PIPELINE=true  # Toggle for remote Ollama endpoint monitoring
SILICON_ENDPOINTS=(
    "http://10.0.0.105:11434"
    "http://10.0.0.151:11434"
)  # List of remote Ollama endpoints (priority order)
SILICON_PREFERRED_MODEL="deepseek-r1:latest"  # Preferred model on remote endpoints
SILICON_CHECK_INTERVAL=30  # Seconds between endpoint health checks
SILICON_TIMEOUT=30  # Connection timeout for endpoint checks (increased for busy endpoints)

# ── SILICON PIPELINE STATE ──
SILICON_ACTIVE_ENDPOINT=""  # Currently active remote endpoint
SILICON_ACTIVE_MODEL=""  # Currently active remote model
SILICON_LAST_CHECK=0  # Timestamp of last endpoint check
SILICON_STATUS="disconnected"  # Current pipeline status: connected, disconnected, fallback
SILICON_MONITOR_PID=""  # PID of background monitoring process

# ── SOUND EFFECTS ──
SOUND_EFFECTS_DIR="$(dirname "$0")/assets"  # Sound effects directory
SOUND_ENABLED=true  # Toggle for sound effects

MAX_SPEAK_CHUNK=40

# ── SESSION STATE ──
SESSION_SYSTEM_MESSAGE=""  # Current session system message
MESSAGE_HISTORY=()  # Array to store conversation history
CONTEXT_LENGTH=4  # Number of message pairs to include in context
CURRENT_MODEL="$DEFAULT_MODEL"  # Currently selected model
CURRENT_TEMPERATURE=0.7  # AI creativity/spontaneity level (0.0-1.0)

# ── BATTERY & CACHING ──
LAST_BATTERY_WARNING=100  # Track last battery warning level
SPEECH_CACHE_DIR="$HOME/.codedeck/speech_cache"  # Directory for cached speech files
RECORDING_CACHE_DIR="$HOME/.codedeck/recording_cache"  # Directory for temporary recordings

# ── STREAMING SPEECH SYSTEM ──
STREAMING_SPEECH_DIR="$HOME/.codedeck/streaming_speech"  # Directory for streaming speech files
SENTENCE_INDEX_COUNTER=0  # Global counter for sentence indexing
EXPECTED_PLAYBACK_INDEX=1  # Next expected sentence index for playback
PLAYBACK_QUEUE_FILE="$STREAMING_SPEECH_DIR/playback_queue"  # File to track playback queue
SENTENCE_BUFFER=""  # Buffer for incomplete sentences during streaming
PLAYBACK_COORDINATOR_PID=""  # PID of the playback coordinator process

# ── INTERRUPT HANDLING ──
GENERATION_PID=""  # Track the current generation process
INTERRUPT_REQUESTED=false  # Flag for interrupt requests
POST_INTERRUPT_AUDIO=false  # Flag for when we're in post-interrupt audio playback

# ── SILICON PIPELINE FUNCTIONS ──

# Function to check if an Ollama endpoint is alive
check_silicon_endpoint() {
    local endpoint="$1"
    local timeout="${2:-$SILICON_TIMEOUT}"
    
    debug_log "Checking Silicon endpoint: $endpoint"
    
    # Quick health check on the /api/tags endpoint
    local response
    response=$(curl -s --connect-timeout "$timeout" --max-time "$timeout" "$endpoint/api/tags" 2>/dev/null)
    
    if [ $? -eq 0 ] && echo "$response" | grep -q "models" 2>/dev/null; then
        debug_log "Silicon endpoint $endpoint is alive"
        return 0
    else
        debug_log "Silicon endpoint $endpoint is unreachable"
        return 1
    fi
}

# Function to get available models from an Ollama endpoint
get_silicon_models() {
    local endpoint="$1"
    
    debug_log "Fetching models from Silicon endpoint: $endpoint"
    
    local response
    response=$(curl -s --connect-timeout "$SILICON_TIMEOUT" --max-time "$SILICON_TIMEOUT" "$endpoint/api/tags" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$response" ]; then
        # Parse JSON to extract model names
        echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('models', [])
    for model in models:
        print(model.get('name', ''))
except:
    pass
" 2>/dev/null
    fi
}

# Function to select best model from available models
select_silicon_model() {
    local endpoint="$1"
    local models
    models=$(get_silicon_models "$endpoint")
    
    if [ -z "$models" ]; then
        debug_log "No models found on Silicon endpoint: $endpoint"
        return 1
    fi
    
    debug_log "Available models on $endpoint: $(echo "$models" | tr '\n' ' ')"
    
    # Check if preferred model exists
    if echo "$models" | grep -q "^${SILICON_PREFERRED_MODEL}$"; then
        echo "$SILICON_PREFERRED_MODEL"
        debug_log "Found preferred model: $SILICON_PREFERRED_MODEL"
        return 0
    fi
    
    # Use first available model as fallback
    local first_model
    first_model=$(echo "$models" | head -1)
    if [ -n "$first_model" ]; then
        echo "$first_model"
        debug_log "Using first available model: $first_model"
        return 0
    fi
    
    debug_log "No suitable models found on Silicon endpoint"
    return 1
}

# Function to discover active Silicon endpoint
discover_silicon_endpoint() {
    if [ "$ENABLE_SILICON_PIPELINE" != true ]; then
        return 1
    fi
    
    debug_log "Discovering Silicon endpoints..."
    
    for endpoint in "${SILICON_ENDPOINTS[@]}"; do
        if check_silicon_endpoint "$endpoint"; then
            local model
            model=$(select_silicon_model "$endpoint")
            
            if [ $? -eq 0 ] && [ -n "$model" ]; then
                SILICON_ACTIVE_ENDPOINT="$endpoint"
                SILICON_ACTIVE_MODEL="$model"
                debug_log "Silicon pipeline connected: $endpoint with model $model"
                return 0
            fi
        fi
    done
    
    debug_log "No Silicon endpoints available"
    return 1
}

# Function to announce Silicon pipeline status changes
announce_silicon_status() {
    local new_status="$1"
    local old_status="$SILICON_STATUS"
    
    if [ "$new_status" = "$old_status" ]; then
        return  # No change
    fi
    
    SILICON_STATUS="$new_status"
    
    case "$new_status" in
        "connected")
            echo -e "$GREEN[🧠 Synaptic Influx Detected - Neural bandwidth enhanced]$RESET"
            if [ "$VOICE_ENABLED" = true ]; then
                speak_routine_message "silicon_connected" "Synaptic influx detected. Neural bandwidth enhanced."
            fi
            play_sound_effect "switch"
            ;;
        "disconnected"|"fallback")
            # Check if local API is available to determine message
            local local_available=false
            if curl -s --connect-timeout 2 "$CODEDECK_API/v1/status" >/dev/null 2>&1; then
                local_available=true
            fi
            
            if [ "$local_available" = true ]; then
                echo -e "$YELLOW[🧠 Synaptic Density has Normalized - Local processing active]$RESET"
                if [ "$VOICE_ENABLED" = true ]; then
                    speak_routine_message "silicon_disconnected" "Synaptic density has normalized. Local processing active."
                fi
            else
                echo -e "$RED[🧠 Synaptic Density has Normalized - No remote AI available]$RESET"
                if [ "$VOICE_ENABLED" = true ]; then
                    speak_routine_message "silicon_disconnected_no_local" "Synaptic density has normalized. No Remote AI systems available."
                fi
            fi
            play_sound_effect "confirm"
            ;;
    esac
}

# Function to start Silicon pipeline monitoring
start_silicon_monitor() {
    if [ "$ENABLE_SILICON_PIPELINE" != true ]; then
        return
    fi
    
    # Stop any existing monitor
    stop_silicon_monitor
    
    debug_log "Starting Silicon pipeline monitor"
    
    # Initial discovery
    if discover_silicon_endpoint; then
        announce_silicon_status "connected"
    else
        announce_silicon_status "disconnected"
    fi
    
    # Start background monitoring process
    {
        while [ "$ENABLE_SILICON_PIPELINE" = true ]; do
            sleep "$SILICON_CHECK_INTERVAL"
            
            local current_time
            current_time=$(date +%s)
            
            # Skip if we just checked recently (avoid excessive checking)
            if [ $((current_time - SILICON_LAST_CHECK)) -lt "$SILICON_CHECK_INTERVAL" ]; then
                continue
            fi
            
            SILICON_LAST_CHECK="$current_time"
            
            # Check current endpoint if we have one
            if [ -n "$SILICON_ACTIVE_ENDPOINT" ]; then
                # Try multiple times before marking as failed (endpoint might be busy)
                local check_attempts=0
                local max_attempts=3
                local endpoint_failed=true
                
                while [ $check_attempts -lt $max_attempts ]; do
                    if check_silicon_endpoint "$SILICON_ACTIVE_ENDPOINT"; then
                        endpoint_failed=false
                        break
                    fi
                    check_attempts=$((check_attempts + 1))
                    debug_log "Silicon endpoint check attempt $check_attempts/$max_attempts failed"
                    if [ $check_attempts -lt $max_attempts ]; then
                        sleep 5  # Wait before retry
                    fi
                done
                
                if [ "$endpoint_failed" = true ]; then
                    debug_log "Silicon endpoint $SILICON_ACTIVE_ENDPOINT went offline after $max_attempts attempts"
                    SILICON_ACTIVE_ENDPOINT=""
                    SILICON_ACTIVE_MODEL=""
                    announce_silicon_status "fallback"
                fi
            fi
            
            # If no active endpoint, try to discover one
            if [ -z "$SILICON_ACTIVE_ENDPOINT" ]; then
                if discover_silicon_endpoint; then
                    announce_silicon_status "connected"
                fi
            fi
        done
    } &
    
    SILICON_MONITOR_PID=$!
    debug_log "Silicon monitor started with PID: $SILICON_MONITOR_PID"
}

# Function to stop Silicon pipeline monitoring
stop_silicon_monitor() {
    if [ -n "$SILICON_MONITOR_PID" ]; then
        debug_log "Stopping Silicon monitor PID: $SILICON_MONITOR_PID"
        kill "$SILICON_MONITOR_PID" 2>/dev/null || true
        wait "$SILICON_MONITOR_PID" 2>/dev/null || true
        SILICON_MONITOR_PID=""
    fi
}

# Function to route chat request through Silicon pipeline with streaming
route_silicon_chat_streaming() {
    local messages_json="$1"
    local output_file="$2"
    
    if [ "$ENABLE_SILICON_PIPELINE" != true ] || [ -z "$SILICON_ACTIVE_ENDPOINT" ] || [ -z "$SILICON_ACTIVE_MODEL" ]; then
        return 1  # Use local routing
    fi
    
    debug_log "Routing chat through Silicon endpoint: $SILICON_ACTIVE_ENDPOINT with model: $SILICON_ACTIVE_MODEL"
    
    # Convert CodeDeck format to Ollama format
    local ollama_request
    ollama_request=$(echo "$messages_json" | python3 -c "
import sys, json
try:
    messages = json.load(sys.stdin)
    
    # Convert to Ollama chat format
    ollama_format = {
        'model': '$SILICON_ACTIVE_MODEL',
        'messages': messages,
        'stream': True,
        'options': {
            'temperature': $CURRENT_TEMPERATURE
        }
    }
    
    print(json.dumps(ollama_format))
except Exception as e:
    print('{}', file=sys.stderr)
    exit(1)
")
    
    if [ $? -ne 0 ]; then
        debug_log "Failed to convert request format for Silicon pipeline"
        return 1
    fi
    
    # Track streaming variables
    local full_content=""
    local in_think_tag=false
    local think_opens=0
    local think_closes=0
    local orphaned_close_handled=false
    
    # Make streaming request to Ollama endpoint
    curl -s -X POST "$SILICON_ACTIVE_ENDPOINT/api/chat" \
        -H "Content-Type: application/json" \
        -d "$ollama_request" 2>/dev/null | while IFS= read -r line; do
        
        # Check for interrupt
        if [ "$INTERRUPT_REQUESTED" = true ]; then
            exit 1
        fi
        
        if [ -n "$line" ]; then
            # Parse Ollama response format
            local content
            content=$(echo "$line" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    message = data.get('message', {})
    content = message.get('content', '')
    if content:
        print(content, end='')
except:
    pass
" 2>/dev/null)
            
            if [ -n "$content" ]; then
                # Add to full content
                full_content="$full_content$content"
                echo -n "$content" >> "$output_file"
                
                # Enhanced think-tag processing (simplified version)
                think_opens=$(echo "$full_content" | grep -o '<think>' | wc -l)
                think_closes=$(echo "$full_content" | grep -o '</think>' | wc -l)
                
                                        # Handle orphaned closing tag
                        if [ "$think_closes" -gt "$think_opens" ] && [ "$orphaned_close_handled" = false ]; then
                            orphaned_close_handled=true
                            echo -ne "\n$SILICON_DIM┌─ 💭 [SILICON THINK - FROM START] ─┐$RESET\n"
                            echo -ne "$SILICON_DIM│$RESET "
                            local before_close=$(echo "$full_content" | sed 's/<\/think>.*//')
                            if [ -n "$before_close" ]; then
                                echo -ne "\e[3;96m$before_close\e[0m"
                            fi
                        fi
                
                # Determine if we're inside think tag
                local inside_think=false
                if [ "$think_opens" -gt "$think_closes" ]; then
                    inside_think=true
                fi
                
                # Process think-tag transitions
                if [[ "$content" == *"<think>"* ]]; then
                    if [ "$orphaned_close_handled" = false ]; then
                        echo -ne "\n$SILICON_DIM┌─ 💭 [SILICON COGNITIVE PROCESSING] ─┐$RESET\n"
                        echo -ne "$SILICON_DIM│$RESET "
                    fi
                    local after_tag=$(echo "$content" | sed 's/.*<think>//')
                    if [ -n "$after_tag" ]; then
                        echo -ne "\e[3;96m$after_tag\e[0m"
                    fi
                elif [[ "$content" == *"</think>"* ]]; then
                    if [ "$orphaned_close_handled" = false ]; then
                        local before_tag=$(echo "$content" | sed 's/<\/think>.*//')
                        if [ -n "$before_tag" ]; then
                            echo -ne "\e[3;96m$before_tag\e[0m"
                        fi
                        echo -ne "\n$SILICON_DIM└────────────────────────────────────────┘$RESET\n"
                        echo -ne "$SILICON_PURPLE"
                    else
                        echo -ne "\n$SILICON_DIM└────────────────────────────────────────┘$RESET\n"
                        echo -ne "$SILICON_PURPLE"
                    fi
                    local after_tag=$(echo "$content" | sed 's/.*<\/think>//')
                    if [ -n "$after_tag" ]; then
                        echo -ne "$after_tag"
                        process_streaming_text_for_speech "$after_tag" false
                    fi
                elif [ "$inside_think" = true ]; then
                    echo -ne "\e[3;96m$content\e[0m"
                else
                    echo -ne "$SILICON_PURPLE$content$RESET"
                    process_streaming_text_for_speech "$content" false
                fi
            fi
            
            # Check if done
            local done
            done=$(echo "$line" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('done', False))
except:
    print(False)
" 2>/dev/null)
            
            if [ "$done" = "True" ]; then
                break
            fi
        fi
    done
    
    # Check if we got a response
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        return 0
    else
        # Check if this was due to user interrupt vs actual failure
        if [ "$INTERRUPT_REQUESTED" = true ]; then
            debug_log "Silicon request interrupted by user - endpoint still active"
            return 1  # Return failure for routing but don't mark Silicon as failed
        else
            debug_log "Silicon endpoint request failed, marking for fallback"
            # Mark endpoint as failed for background monitor to detect
            SILICON_ACTIVE_ENDPOINT=""
            SILICON_ACTIVE_MODEL=""
            announce_silicon_status "fallback"
            return 1
        fi
    fi
}

# Function to toggle Silicon pipeline
toggle_silicon_pipeline() {
    if [ "$ENABLE_SILICON_PIPELINE" = true ]; then
        ENABLE_SILICON_PIPELINE=false
        stop_silicon_monitor
        SILICON_ACTIVE_ENDPOINT=""
        SILICON_ACTIVE_MODEL=""
        SILICON_STATUS="disconnected"
        show_property_change "Silicon Pipeline DISABLED" "Local processing only" "🧠"
        play_sound_effect "confirm"
    else
        ENABLE_SILICON_PIPELINE=true
        show_property_change "Silicon Pipeline ENABLED" "Remote neural mesh monitoring" "🧠"
        play_sound_effect "confirm"
        start_silicon_monitor
    fi
}

# Function to discover and show Silicon endpoint summary
discover_silicon_endpoints_summary() {
    echo -e "$GREEN🧠 Scanning Silicon Pipeline endpoints...$RESET"
    
    local endpoint_status=()
    local endpoint_model_counts=()
    local total_models=0
    local available_endpoints=0
    
    # Check all configured endpoints
    for endpoint in "${SILICON_ENDPOINTS[@]}"; do
        echo -e "$DIM_PURPLE[Checking $endpoint...]$RESET"
        
        if check_silicon_endpoint "$endpoint"; then
            local models
            models=$(get_silicon_models "$endpoint")
            local model_count=0
            
            if [ -n "$models" ]; then
                model_count=$(echo "$models" | wc -l)
                total_models=$((total_models + model_count))
                available_endpoints=$((available_endpoints + 1))
                
                echo -e "$GREEN  ✓ $endpoint - $model_count models$RESET"
                endpoint_status+=("available")
                endpoint_model_counts+=("$model_count")
            else
                echo -e "$YELLOW  ⚠ $endpoint - Connected but no models$RESET"
                endpoint_status+=("no_models")
                endpoint_model_counts+=("0")
            fi
        else
            echo -e "$RED  ✗ $endpoint - Cannot connect$RESET"
            endpoint_status+=("offline")
            endpoint_model_counts+=("0")
        fi
    done
    
    echo ""
    echo -e "$GREEN✓ Silicon Summary: $available_endpoints/${#SILICON_ENDPOINTS[@]} endpoints available, $total_models total models$RESET"
    
    if [ $available_endpoints -gt 1 ]; then
        echo -e "$CYAN💡 Multiple endpoints found! Use 'silicon endpoints' to choose priority$RESET"
    fi
    
    return $available_endpoints
}

# Function to list models from Silicon endpoints
list_silicon_models() {
    # First show endpoint summary
    discover_silicon_endpoints_summary
    local available_count=$?
    
    if [ $available_count -eq 0 ]; then
        echo -e "$YELLOW  ⚠ No models found on Silicon endpoints$RESET"
        return 1
    fi
    
    echo ""
    echo -e "$CYAN🤖 Available Silicon Models:$RESET"
    
    # Collect all models from all endpoints for pagination
    local temp_models=$(mktemp)
    local all_models=()
    local model_sources=()
    local model_index=1
    local total_models=0
    
    # Build a list of all models for pagination
    for endpoint in "${SILICON_ENDPOINTS[@]}"; do
        if check_silicon_endpoint "$endpoint"; then
            local models
            models=$(get_silicon_models "$endpoint")
            
            if [ -n "$models" ]; then
                local priority_marker=""
                if [ "$endpoint" = "$SILICON_ACTIVE_ENDPOINT" ]; then
                    priority_marker=" [PRIORITY]"
                fi
                
                # Add endpoint header to temp file
                echo "ENDPOINT|$endpoint$priority_marker" >> "$temp_models"
                
                # Add models from this endpoint
                while IFS= read -r model; do
                    if [ -n "$model" ]; then
                        all_models+=("$model")
                        model_sources+=("$endpoint")
                        
                        # Mark current model if it matches
                        local current_marker=""
                        if [ "$model" = "$SILICON_ACTIVE_MODEL" ] && [ "$endpoint" = "$SILICON_ACTIVE_ENDPOINT" ]; then
                            current_marker=" <- CURRENT"
                        fi
                        
                        echo "MODEL|$model_index|$model|$endpoint|$current_marker" >> "$temp_models"
                        model_index=$((model_index + 1))
                        total_models=$((total_models + 1))
                    fi
                done <<< "$models"
                
                # Add separator
                echo "SEPARATOR|" >> "$temp_models"
            fi
        fi
    done
    
    if [ "$total_models" -eq 0 ]; then
        echo -e "$YELLOW  ⚠ No models found on Silicon endpoints$RESET"
        rm -f "$temp_models"
        return 1
    fi
    
    # Paginate the output (show 10 models at a time)
    local models_per_page=10
    local current_line=1
    local total_lines
    total_lines=$(wc -l < "$temp_models")
    
    echo -e "$SILICON_GREEN✓ Found $total_models Silicon models:$RESET"
    echo ""
    
    while [ "$current_line" -le "$total_lines" ]; do
        # Show next batch
        local end_line=$((current_line + models_per_page - 1))
        if [ "$end_line" -gt "$total_lines" ]; then
            end_line="$total_lines"
        fi
        
        # Display this batch
        sed -n "${current_line},${end_line}p" "$temp_models" | while IFS='|' read -r type field1 field2 field3 field4; do
            case "$type" in
                "ENDPOINT")
                    echo -e "$SILICON_GREEN📡 $field1:$RESET"
                    ;;
                "MODEL")
                    echo -e "$SILICON_PURPLE  $field1. 🔥 $field2$field4$RESET"
                    ;;
                "SEPARATOR")
                    echo ""
                    ;;
            esac
        done
        
        current_line=$((end_line + 1))
        
        # Show pagination controls if there are more models
        if [ "$current_line" -le "$total_lines" ]; then
            echo -e "$YELLOW[Press any key to see more Silicon models...]$RESET"
            read -n 1 -s
            echo ""
        fi
    done
    
    echo -e "$SILICON_DIM┌─────────────────────────────────────────────────────┐$RESET"
    echo -e "$SILICON_DIM│ SILICON MODEL USAGE:$RESET"
    echo -e "$SILICON_DIM│   model select 1              - Select model #1$RESET"
    echo -e "$SILICON_DIM│   model select deepseek_r1    - Select by name$RESET"
    echo -e "$SILICON_DIM│   silicon endpoints           - Choose priority endpoint$RESET"
    echo -e "$SILICON_DIM└─────────────────────────────────────────────────────┘$RESET"
    
    # Clean up temp file
    rm -f "$temp_models"
}

# Function to select model from Silicon endpoints
select_silicon_model_by_name_or_index() {
    local selection="$1"
    
    # Build arrays of all available models and their sources
    local all_models=()
    local model_sources=()
    
    for endpoint in "${SILICON_ENDPOINTS[@]}"; do
        if check_silicon_endpoint "$endpoint"; then
            local models
            models=$(get_silicon_models "$endpoint")
            
            while IFS= read -r model; do
                if [ -n "$model" ]; then
                    all_models+=("$model")
                    model_sources+=("$endpoint")
                fi
            done <<< "$models"
        fi
    done
    
    if [ ${#all_models[@]} -eq 0 ]; then
        echo -e "$RED❌ No models available on Silicon endpoints$RESET"
        return 1
    fi
    
    local target_model=""
    local target_endpoint=""
    
    # Check if selection is a number (index)
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        local index=$((selection - 1))  # Convert to 0-based
        
        if [ $index -ge 0 ] && [ $index -lt ${#all_models[@]} ]; then
            target_model="${all_models[$index]}"
            target_endpoint="${model_sources[$index]}"
            echo -e "$GREEN[✓ Model #$selection resolved to: $target_model on $target_endpoint]$RESET"
        else
            echo -e "$RED❌ Invalid model index: $selection (valid range: 1-${#all_models[@]})$RESET"
            return 1
        fi
    else
        # Selection by name - find first endpoint that has this model
        for i in "${!all_models[@]}"; do
            if [ "${all_models[$i]}" = "$selection" ]; then
                target_model="$selection"
                target_endpoint="${model_sources[$i]}"
                echo -e "$GREEN[✓ Found model '$selection' on $target_endpoint]$RESET"
                break
            fi
        done
        
        if [ -z "$target_model" ]; then
            echo -e "$RED❌ Model '$selection' not found on any Silicon endpoint$RESET"
            echo -e "$YELLOW💡 Use 'model list' to see available models$RESET"
            return 1
        fi
    fi
    
    # Switch to the selected model and endpoint
    SILICON_ACTIVE_ENDPOINT="$target_endpoint"
    SILICON_ACTIVE_MODEL="$target_model"
    CURRENT_MODEL="$target_model"
    
    # Update status
    announce_silicon_status "connected"
    
    play_sound_effect "switch"
    show_property_change "Silicon model switched" "$target_model @ ${target_endpoint##*/}" "🧠"
    
    if [ "$VOICE_ENABLED" = true ]; then
        speak_routine_message "silicon_model_switched" "Silicon model $target_model loaded."
    fi
    
    return 0
}

# Function to select priority Silicon endpoint
select_silicon_endpoint() {
    echo -e "$GREEN🧠 Silicon Endpoint Selection$RESET"
    echo ""
    
    # Discover all endpoints with their status
    local endpoint_list=()
    local endpoint_status=()
    local endpoint_model_counts=()
    local available_count=0
    
    local index=1
    for endpoint in "${SILICON_ENDPOINTS[@]}"; do
        echo -e "$DIM_PURPLE[$index] Checking $endpoint...$RESET"
        
        if check_silicon_endpoint "$endpoint"; then
            local models
            models=$(get_silicon_models "$endpoint")
            local model_count=0
            
            if [ -n "$models" ]; then
                model_count=$(echo "$models" | wc -l)
                available_count=$((available_count + 1))
                
                local current_marker=""
                if [ "$endpoint" = "$SILICON_ACTIVE_ENDPOINT" ]; then
                    current_marker=" [CURRENT PRIORITY]"
                fi
                
                echo -e "$GREEN    ✓ $endpoint - $model_count models$current_marker$RESET"
                endpoint_status+=("available")
                endpoint_model_counts+=("$model_count")
            else
                echo -e "$YELLOW    ⚠ $endpoint - Connected but no models$RESET"
                endpoint_status+=("no_models")
                endpoint_model_counts+=("0")
            fi
        else
            echo -e "$RED    ✗ $endpoint - Cannot connect$RESET"
            endpoint_status+=("offline")
            endpoint_model_counts+=("0")
        fi
        
        endpoint_list+=("$endpoint")
        index=$((index + 1))
    done
    
    echo ""
    
    if [ $available_count -eq 0 ]; then
        echo -e "$RED❌ No Silicon endpoints are currently available$RESET"
        return 1
    fi
    
    if [ $available_count -eq 1 ]; then
        echo -e "$YELLOW💡 Only one endpoint available - no selection needed$RESET"
        return 0
    fi
    
    # Show selection menu
    echo -e "$CYAN📋 Select priority endpoint:$RESET"
    echo ""
    
    index=1
    for endpoint in "${SILICON_ENDPOINTS[@]}"; do
        local status="${endpoint_status[$((index-1))]}"
        local count="${endpoint_model_counts[$((index-1))]}"
        
        case "$status" in
            "available")
                local current_marker=""
                if [ "$endpoint" = "$SILICON_ACTIVE_ENDPOINT" ]; then
                    current_marker=" [CURRENT]"
                fi
                echo -e "$GREEN  $index. ✓ $endpoint ($count models)$current_marker$RESET"
                ;;
            "no_models")
                echo -e "$YELLOW  $index. ⚠ $endpoint (no models)$RESET"
                ;;
            "offline")
                echo -e "$DIM_PURPLE  $index. ✗ $endpoint (offline)$RESET"
                ;;
        esac
        index=$((index + 1))
    done
    
    echo ""
    echo -ne "$CYAN Enter selection (1-${#SILICON_ENDPOINTS[@]}) or 'q' to cancel: $RESET"
    
    local selection=""
    read -r selection
    
    if [ "$selection" = "q" ] || [ "$selection" = "Q" ]; then
        echo -e "$YELLOW[Cancelled]$RESET"
        return 0
    fi
    
    # Validate selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#SILICON_ENDPOINTS[@]} ]; then
        echo -e "$RED❌ Invalid selection$RESET"
        return 1
    fi
    
    local selected_endpoint="${SILICON_ENDPOINTS[$((selection-1))]}"
    local selected_status="${endpoint_status[$((selection-1))]}"
    
    if [ "$selected_status" != "available" ]; then
        echo -e "$RED❌ Selected endpoint is not available$RESET"
        return 1
    fi
    
    # Set as priority endpoint
    SILICON_ACTIVE_ENDPOINT="$selected_endpoint"
    local best_model
    best_model=$(select_silicon_model "$selected_endpoint")
    
    if [ $? -eq 0 ] && [ -n "$best_model" ]; then
        SILICON_ACTIVE_MODEL="$best_model"
        announce_silicon_status "connected"
        
        play_sound_effect "switch"
        show_property_change "Silicon priority endpoint set" "$selected_endpoint (${best_model})" "🧠"
        
        if [ "$VOICE_ENABLED" = true ]; then
            speak_routine_message "silicon_endpoint_selected" "Priority endpoint switched to ${selected_endpoint##*/}."
        fi
        
        echo -e "$GREEN✓ Priority endpoint set to: $selected_endpoint$RESET"
        echo -e "$GREEN✓ Using model: $best_model$RESET"
    else
        echo -e "$RED❌ Failed to initialize selected endpoint$RESET"
        return 1
    fi
}

# Function to show Silicon pipeline status
show_silicon_status() {
    echo -e "$DIM_PURPLE┌─── SILICON PIPELINE STATUS ───┐$RESET"
    
    if [ "$ENABLE_SILICON_PIPELINE" = true ]; then
        echo -e "$GREEN🧠$RESET Pipeline: ENABLED"
        echo -e "$GREEN🔗$RESET Status: $SILICON_STATUS"
        
        if [ -n "$SILICON_ACTIVE_ENDPOINT" ]; then
            echo -e "$GREEN🌐$RESET Endpoint: $SILICON_ACTIVE_ENDPOINT"
            echo -e "$GREEN🤖$RESET Model: $SILICON_ACTIVE_MODEL"
        else
            echo -e "$YELLOW🌐$RESET Endpoint: (discovering...)"
            echo -e "$YELLOW🤖$RESET Model: (none)"
        fi
        
        echo -e "$GREEN⏱️$RESET Check Interval: ${SILICON_CHECK_INTERVAL}s"
        echo -e "$GREEN📡$RESET Configured Endpoints: ${#SILICON_ENDPOINTS[@]}"
        
        local i=1
        for endpoint in "${SILICON_ENDPOINTS[@]}"; do
            local status_icon="❓"
            if [ "$endpoint" = "$SILICON_ACTIVE_ENDPOINT" ]; then
                status_icon="🟢"
            else
                if check_silicon_endpoint "$endpoint" 1; then  # Quick 1-second check
                    status_icon="⚪"
                else
                    status_icon="🔴"
                fi
            fi
            echo -e "$DIM_PURPLE     $i. $status_icon $endpoint$RESET"
            i=$((i + 1))
        done
    else
        echo -e "$RED🧠$RESET Pipeline: DISABLED"
        echo -e "$DIM_PURPLE     Use 'silicon' to enable remote neural mesh$RESET"
    fi
    
    echo -e "$DIM_PURPLE└─────────────────────────────────┘$RESET"
}

# ── TERMINAL DETECTION ──
# Detect if we're running over SSH or locally
IS_SSH_SESSION=false
if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ] || [ -n "$SSH_CONNECTION" ]; then
    IS_SSH_SESSION=true
fi

source /home/codemusic/CodeDeck/codedeck_venv/bin/activate

# Function to handle interrupt signals
handle_interrupt() {
    # Check if we're already in post-interrupt audio state
    if [ "$POST_INTERRUPT_AUDIO" = true ]; then
        # Second interrupt - hush everything immediately
        echo -e "\n$RED[🤫 Double interrupt - hushing all audio]$RESET"
        hush
        POST_INTERRUPT_AUDIO=false
        INTERRUPT_REQUESTED=false
        return
    fi
    
    # First interrupt during generation
    INTERRUPT_REQUESTED=true
    if [ -n "$GENERATION_PID" ]; then
        kill -TERM "$GENERATION_PID" 2>/dev/null
    fi
    echo -e "\n$YELLOW[⚠] Generation interrupted - partial audio will play (Ctrl+C again to hush)$RESET"
    
    # Set flag to indicate we're now in post-interrupt audio state
    POST_INTERRUPT_AUDIO=true
    
    # DON'T kill audio processes on first interrupt - let partial audio play
    debug_log "Generation stopped, allowing partial audio to continue"
    
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
    
    # Reset interrupt flags
    INTERRUPT_REQUESTED=false
    POST_INTERRUPT_AUDIO=false
    
    # Clear generation PID
    GENERATION_PID=""
    
    echo -e "$GREEN[✓ Terminal state recovered]$RESET"
}

# ── INITIALIZATION ──

# Create speech cache directory
mkdir -p "$SPEECH_CACHE_DIR"

# Create recording cache directory  
mkdir -p "$RECORDING_CACHE_DIR"

# Create streaming speech directory
mkdir -p "$STREAMING_SPEECH_DIR"

# ── SYSTEM MONITORING FUNCTIONS ──

# Function to get CPU temperature
get_cpu_temperature() {
    local cpu_temp=""
    
    # Try different methods based on the system
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        # Linux - most common location (in millidegrees)
        local temp_millidegrees=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        if [ -n "$temp_millidegrees" ] && [ "$temp_millidegrees" -gt 0 ]; then
            cpu_temp=$((temp_millidegrees / 1000))
        fi
    elif command -v sensors >/dev/null 2>&1; then
        # Linux with lm-sensors
        cpu_temp=$(sensors 2>/dev/null | grep -i "core 0\|cpu\|temp1" | grep -o "[0-9]*\.[0-9]*°C\|[0-9]*°C" | head -1 | tr -d '°C')
    elif command -v cat >/dev/null 2>&1 && [ -f /sys/devices/virtual/thermal/thermal_zone0/temp ]; then
        # Alternative thermal zone path
        local temp_millidegrees=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp 2>/dev/null)
        if [ -n "$temp_millidegrees" ] && [ "$temp_millidegrees" -gt 0 ]; then
            cpu_temp=$((temp_millidegrees / 1000))
        fi
    elif command -v vcgencmd >/dev/null 2>&1; then
        # Raspberry Pi
        cpu_temp=$(vcgencmd measure_temp 2>/dev/null | grep -o "[0-9]*\.[0-9]*" | head -1)
    elif command -v pmset >/dev/null 2>&1; then
        # macOS - try to get thermal state (not exact temp but indicator)
        local thermal_state=$(pmset -g thermlog 2>/dev/null | tail -1 | awk '{print $2}' 2>/dev/null)
        if [ -n "$thermal_state" ]; then
            cpu_temp="$thermal_state"
        fi
    fi
    
    # Return the temperature or empty if not found
    echo "$cpu_temp"
}

# Function to detect if system uses 18650 batteries
is_18650_system() {
    # Detect uConsole, GameHat, or other 18650-based systems
    if [ -f /proc/device-tree/model ]; then
        # Use tr to handle null bytes properly and suppress warnings
        local model=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' 2>/dev/null)
        if [[ "$model" =~ (uConsole|GameHat|ClockworkPi) ]]; then
            return 0
        fi
    fi
    
    # Check for uConsole specific hardware paths
    if [ -d /sys/class/power_supply ] && [ -f /sys/class/power_supply/BAT0/capacity ]; then
        # Look for battery capacity in the right range for dual 18650 (typically 4000-5000mAh)
        local design_capacity=""
        if [ -f /sys/class/power_supply/BAT0/charge_full_design ]; then
            design_capacity=$(cat /sys/class/power_supply/BAT0/charge_full_design 2>/dev/null)
        fi
        
        # Check for typical 18650 voltage ranges (2S configuration)
        if [ -f /sys/class/power_supply/BAT0/voltage_now ]; then
            local voltage_now=$(cat /sys/class/power_supply/BAT0/voltage_now 2>/dev/null)
            if [ -n "$voltage_now" ]; then
                # Convert to volts (microvolts to volts)
                local voltage=$(echo "scale=1; $voltage_now / 1000000" | bc 2>/dev/null)
                # 18650 2S: 3.0V-4.2V per cell = 6.0V-8.4V total (3.7V nominal = 7.4V)
                if [ -n "$voltage" ] && echo "$voltage >= 5.5 && $voltage <= 9.0" | bc -l 2>/dev/null | grep -q 1; then
                    return 0
                fi
            fi
        fi
    fi
    
    # Check for specific filesystem indicators
    if [ -f /sys/firmware/devicetree/base/model ]; then
        local model=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0' 2>/dev/null)
        if [[ "$model" =~ (uConsole|GameHat|ClockworkPi) ]]; then
            return 0
        fi
    fi
    
    # Temporary: Force enable for testing (you mentioned you have a uConsole)
    # Remove this when detection is working properly
    if [ -f /sys/class/power_supply/BAT0/capacity ]; then
        # If we have a battery and it's not clearly a laptop, assume 18650
        return 0
    fi
    
    return 1
}

# Function to debug 18650 detection
debug_18650_detection() {
    echo "=== 18650 Detection Debug ==="
    
    echo "Device tree model checks:"
    if [ -f /proc/device-tree/model ]; then
        local model=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' 2>/dev/null)
        echo "  /proc/device-tree/model: '$model'"
    else
        echo "  /proc/device-tree/model: not found"
    fi
    
    if [ -f /sys/firmware/devicetree/base/model ]; then
        local model=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0' 2>/dev/null)
        echo "  /sys/firmware/devicetree/base/model: '$model'"
    else
        echo "  /sys/firmware/devicetree/base/model: not found"
    fi
    
    echo "Battery voltage check:"
    if [ -f /sys/class/power_supply/BAT0/voltage_now ]; then
        local voltage_now=$(cat /sys/class/power_supply/BAT0/voltage_now 2>/dev/null)
        if [ -n "$voltage_now" ]; then
            local voltage=$(echo "scale=1; $voltage_now / 1000000" | bc 2>/dev/null)
            echo "  Current voltage: ${voltage}V (raw: $voltage_now µV)"
            if [ -n "$voltage" ] && echo "$voltage >= 5.5 && $voltage <= 9.0" | bc -l 2>/dev/null | grep -q 1; then
                echo "  Voltage matches 18650 2S range ✓"
            else
                echo "  Voltage outside 18650 2S range"
            fi
        else
            echo "  No voltage data"
        fi
    else
        echo "  No voltage file found"
    fi
    
    echo "18650 detection result:"
    if is_18650_system; then
        echo "  ✓ Detected as 18650 system"
    else
        echo "  ✗ Not detected as 18650 system"
    fi
    
    echo "Battery percentages:"
    local raw_pct=$(get_raw_battery_percentage)
    local massaged_pct=$(get_battery_percentage)
    echo "  Raw: ${raw_pct}%"
    echo "  Massaged: ${massaged_pct}%"
    echo "=========================="
}

# Function to massage battery percentage based on battery type
massage_battery_percentage() {
    local raw_percent="$1"
    
    if [ -z "$raw_percent" ]; then
        echo ""
        return
    fi
    
    # Check if this is an 18650 system
    if is_18650_system; then
        # 18650 usable range mapping:
        # 40% raw = 0% usable (voltage cutoff)
        # 100% raw = 100% usable (full charge)
        # Linear remap: usable = max(0, (raw - 40) * 100 / 60)
        
        if [ "$raw_percent" -gt 40 ]; then
            local usable_percent=$(echo "scale=0; ($raw_percent - 40) * 100 / 60" | bc 2>/dev/null)
            echo "$usable_percent"
        else
            echo "0"
        fi
    else
        # For non-18650 systems, return raw percentage unchanged
        echo "$raw_percent"
    fi
}

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
    
    # Massage the percentage based on battery type
    massage_battery_percentage "$battery_percent"
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

# Function to get raw battery percentage (before 18650 remapping)
get_raw_battery_percentage() {
    local battery_percent=""
    
    # Same detection logic as get_battery_percentage but without remapping
    if command -v pmset >/dev/null 2>&1; then
        battery_percent=$(pmset -g batt | grep -Eo "[0-9]+%" | head -1 | tr -d '%')
    elif [ -f /sys/class/power_supply/BAT0/capacity ]; then
        battery_percent=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)
    elif [ -f /sys/class/power_supply/BAT1/capacity ]; then
        battery_percent=$(cat /sys/class/power_supply/BAT1/capacity 2>/dev/null)
    elif command -v upower >/dev/null 2>&1; then
        local bat_path=$(upower -e | grep -i bat | head -1)
        if [ -n "$bat_path" ]; then
            battery_percent=$(upower -i "$bat_path" | grep -E "percentage" | awk '{print $2}' | tr -d '%')
        fi
    elif command -v acpi >/dev/null 2>&1; then
        battery_percent=$(acpi -b | grep -P -o '[0-9]+(?=%)' | head -1)
    elif [ -d /proc/acpi/battery ]; then
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
        battery_percent=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    elif command -v cat >/dev/null 2>&1; then
        for ps in /sys/class/power_supply/*/capacity; do
            if [ -f "$ps" ]; then
                battery_percent=$(cat "$ps" 2>/dev/null)
                if [ -n "$battery_percent" ] && [ "$battery_percent" -le 100 ]; then
                    break
                fi
            fi
        done
    fi
    
    echo "$battery_percent"
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
    
    # Display with distinct formatting and 18650 awareness
    local raw_percent
    raw_percent=$(get_raw_battery_percentage)
    
    # Show raw percentage if different from massaged percentage (18650 systems)
    if [ "$raw_percent" != "$battery_percent" ]; then
        echo -e "$DIM_PURPLE$battery_icon Battery: $battery_color$battery_percent%$charging_icon$battery_bg$RESET $DIM_PURPLE(raw: ${raw_percent}%)$RESET"
    else
        echo -e "$DIM_PURPLE$battery_icon Battery: $battery_color$battery_percent%$charging_icon$battery_bg$RESET"
    fi
}

# Function to check battery warnings
check_battery_warnings() {
    local battery_percent
    local check_percent
    battery_percent=$(get_battery_percentage)
    
    if [ -z "$battery_percent" ]; then
        return
    fi
    
    # Determine threshold check method and warning levels based on battery type
    local raw_percent
    raw_percent=$(get_raw_battery_percentage)
    
    # If raw != massaged, we have a special battery system (like 18650)
    if [ "$raw_percent" != "$battery_percent" ]; then
        check_percent="$raw_percent"
        # Aggressive warnings for 18650 voltage cutoff behavior
        local warning_levels=(45 35 25 15 10)
    else
        check_percent="$battery_percent"
        # Standard warning levels for regular batteries
        local warning_levels=(50 20 10 5)
    fi
    
    local charging_status
    charging_status=$(get_charging_status)
    
    # Don't warn if charging
    if [[ "$charging_status" =~ (Charging|AC\ Power|on-line) ]]; then
        LAST_BATTERY_WARNING=100  # Reset warnings when charging
        return
    fi
    
    for level in "${warning_levels[@]}"; do
        if [ "$check_percent" -le "$level" ] && [ "$LAST_BATTERY_WARNING" -gt "$level" ]; then
            LAST_BATTERY_WARNING="$level"
            
            # Show warning
            local warning_color
            if [ "$level" -le 10 ]; then
                warning_color="$RED"
            else
                warning_color="$YELLOW"
            fi
            
            echo ""
            # Show both values if they differ (special battery system)
            if [ "$raw_percent" != "$battery_percent" ]; then
                echo -e "$warning_color⚠️  BATTERY WARNING: $battery_percent% usable (${check_percent}% raw) remaining$RESET"
            else
                echo -e "$warning_color⚠️  BATTERY WARNING: $battery_percent% remaining$RESET"
            fi
            
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
    
    echo -e "$DIM_PURPLE[🔋 Enhanced Battery Diagnostic Check...]$RESET"
    
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
    
    # Enhanced battery diagnostics
    echo -e "$DIM_PURPLE┌─────────────────────────────────────────────────────┐$RESET"
    echo -e "$DIM_PURPLE│                ENHANCED BATTERY ANALYSIS           │$RESET"
    echo -e "$DIM_PURPLE└─────────────────────────────────────────────────────┘$RESET"
    
    local status_text="Discharging"
    if [[ "$charging_status" =~ (Charging|AC\ Power|on-line) ]]; then
        status_text="Charging"
    fi
    
    # Show both raw and adjusted percentages for special battery systems
    local raw_percent
    raw_percent=$(get_raw_battery_percentage)
    
    if [ "$raw_percent" != "$battery_percent" ]; then
        echo -e "$CYAN📊 Usable Capacity: $battery_percent% (raw: ${raw_percent}%)$RESET"
        echo -e "$CYAN⚙️  Battery Remapping: Adjusted for voltage cutoff at 40% raw$RESET"
    else
        echo -e "$CYAN📊 Battery Level: $battery_percent%$RESET"
    fi
    echo -e "$CYAN🔌 Status: $status_text$RESET"
    echo -e "$CYAN⚠️  Last Warning: $LAST_BATTERY_WARNING%$RESET"
    
    # Try to get voltage information (Linux)
    local voltage=""
    local voltage_now=""
    local voltage_min=""
    if [ -f /sys/class/power_supply/BAT0/voltage_now ]; then
        voltage_now=$(cat /sys/class/power_supply/BAT0/voltage_now 2>/dev/null)
        if [ -n "$voltage_now" ]; then
            # Convert microvolts to volts
            voltage=$(echo "scale=2; $voltage_now / 1000000" | bc 2>/dev/null || echo "unknown")
        fi
    fi
    
    if [ -f /sys/class/power_supply/BAT0/voltage_min_design ]; then
        voltage_min=$(cat /sys/class/power_supply/BAT0/voltage_min_design 2>/dev/null)
        if [ -n "$voltage_min" ]; then
            voltage_min=$(echo "scale=2; $voltage_min / 1000000" | bc 2>/dev/null || echo "unknown")
        fi
    fi
    
    # Battery capacity information
    local capacity_full=""
    local capacity_design=""
    if [ -f /sys/class/power_supply/BAT0/charge_full ]; then
        capacity_full=$(cat /sys/class/power_supply/BAT0/charge_full 2>/dev/null)
    fi
    if [ -f /sys/class/power_supply/BAT0/charge_full_design ]; then
        capacity_design=$(cat /sys/class/power_supply/BAT0/charge_full_design 2>/dev/null)
    fi
    
    # Calculate battery wear
    local wear_percentage=""
    if [ -n "$capacity_full" ] && [ -n "$capacity_design" ] && [ "$capacity_design" -gt 0 ]; then
        wear_percentage=$(echo "scale=1; (1 - $capacity_full / $capacity_design) * 100" | bc 2>/dev/null)
    fi
    
    # Display advanced info
    if [ -n "$voltage" ] && [ "$voltage" != "unknown" ]; then
        echo -e "$CYAN⚡ Current Voltage: ${voltage}V$RESET"
        if [ -n "$voltage_min" ] && [ "$voltage_min" != "unknown" ]; then
            echo -e "$CYAN⚡ Min Design Voltage: ${voltage_min}V$RESET"
            
            # Voltage health check
            local voltage_ratio
            voltage_ratio=$(echo "scale=2; $voltage / $voltage_min" | bc 2>/dev/null)
            if [ -n "$voltage_ratio" ]; then
                if echo "$voltage_ratio < 1.05" | bc -l 2>/dev/null | grep -q 1; then
                    echo -e "$RED⚠️  WARNING: Voltage critically low (${voltage}V)$RESET"
                    echo -e "$RED   This may explain unexpected shutdowns!$RESET"
                elif echo "$voltage_ratio < 1.15" | bc -l 2>/dev/null | grep -q 1; then
                    echo -e "$YELLOW⚠️  CAUTION: Voltage somewhat low (${voltage}V)$RESET"
                fi
            fi
        fi
    fi
    
    if [ -n "$wear_percentage" ]; then
        echo -e "$CYAN🔋 Battery Wear: ${wear_percentage}%$RESET"
        if echo "$wear_percentage > 30" | bc -l 2>/dev/null | grep -q 1; then
            echo -e "$YELLOW⚠️  Battery shows significant wear$RESET"
        fi
    fi
    
    # macOS specific diagnostics
    if command -v pmset >/dev/null 2>&1; then
        echo -e "$CYAN🍎 macOS Battery Details:$RESET"
        pmset -g batt | head -5 | while read line; do
            echo -e "$DIM_PURPLE   $line$RESET"
        done
    fi
    
    # Health assessment with voltage consideration
    local health_warning=""
    if [ -n "$voltage" ] && [ "$voltage" != "unknown" ] && [ -n "$voltage_min" ]; then
        local voltage_ratio
        voltage_ratio=$(echo "scale=2; $voltage / $voltage_min" | bc 2>/dev/null)
        if [ -n "$voltage_ratio" ] && echo "$voltage_ratio < 1.1" | bc -l 2>/dev/null | grep -q 1; then
            health_warning=" (VOLTAGE CRITICAL)"
        fi
    fi
    
    if [ "$battery_percent" -ge 75 ]; then
        echo -e "$GREEN💚 Health: Excellent$health_warning$RESET"
    elif [ "$battery_percent" -ge 50 ]; then
        echo -e "$YELLOW💛 Health: Good$health_warning$RESET"
    elif [ "$battery_percent" -ge 20 ]; then
        echo -e "$ORANGE🧡 Health: Low - Consider charging$health_warning$RESET"
    else
        echo -e "$RED❤️  Health: Critical - Charge immediately$health_warning$RESET"
    fi
    
    # 18650 battery specific warnings
    echo ""
    echo -e "$CYAN🔋 18650 Battery System Detected (uConsole):$RESET"
    echo -e "$YELLOW⚠️  18650s have hard voltage cutoff around 3.0V per cell$RESET"
    echo -e "$YELLOW⚠️  Reported percentage may be inaccurate near cutoff$RESET"
    echo -e "$YELLOW💡 Charge before 40% to avoid boot failure$RESET"
    
    # Shutdown prediction warning
    if [ -n "$voltage" ] && [ "$voltage" != "unknown" ] && [ -n "$voltage_min" ]; then
        local voltage_ratio
        voltage_ratio=$(echo "scale=2; $voltage / $voltage_min" | bc 2>/dev/null)
        if [ -n "$voltage_ratio" ] && echo "$voltage_ratio < 1.1" | bc -l 2>/dev/null | grep -q 1; then
            echo ""
            echo -e "$RED🚨 SHUTDOWN RISK: Low voltage detected!$RESET"
            echo -e "$YELLOW💡 Your device may shut down unexpectedly even at moderate charge levels$RESET"
            echo -e "$YELLOW💡 This is common with 18650 batteries near voltage cutoff$RESET"
            echo -e "$YELLOW💡 Consider charging or battery replacement$RESET"
        elif [ "$battery_percent" -lt 45 ]; then
            echo ""
            echo -e "$RED⚠️  CRITICAL: 18650 voltage cutoff imminent!$RESET"
            echo -e "$YELLOW💡 Charge immediately to avoid shutdown and boot failure$RESET"
        fi
    fi
    
    # Voice feedback if enabled
    if [ "$VOICE_ENABLED" = true ]; then
        if [ "$battery_percent" -le 20 ] || [ -n "$health_warning" ]; then
            speak_routine_message "battery_check_warning" "Battery diagnostics show potential issues. Check the display for details."
        else
            speak_routine_message "battery_check_good" "Battery level is $battery_percent percent."
        fi
    fi
}

# ── STREAMING SPEECH SYSTEM FUNCTIONS ──

# Function to initialize streaming speech system
init_streaming_speech() {
    if [ "$STREAMING_SPEECH_ENABLED" != true ]; then
        return
    fi
    
    # Reset counters and buffer
    SENTENCE_INDEX_COUNTER=0
    EXPECTED_PLAYBACK_INDEX=1
    SENTENCE_BUFFER=""
    
    # Clean up any existing files
    rm -f "$STREAMING_SPEECH_DIR"/tts_*.wav 2>/dev/null
    rm -f "$PLAYBACK_QUEUE_FILE" 2>/dev/null
    
    # Start playback coordinator in background
    start_playback_coordinator
    
    echo -e "$DIM_PURPLE[🔊 Streaming speech system initialized]$RESET"
}

# Function to start the playback coordinator background process
start_playback_coordinator() {
    # Stop any existing coordinator
    stop_playback_coordinator
    
    # Start new coordinator in background
    {
        while true; do
            if [ -f "$PLAYBACK_QUEUE_FILE" ]; then
                # Check if next expected file is ready
                local next_file="$STREAMING_SPEECH_DIR/tts_${EXPECTED_PLAYBACK_INDEX}.wav"
                
                if [ -f "$next_file" ] && [ -s "$next_file" ]; then
                    # Play the file
                    aplay "$next_file" >/dev/null 2>&1
                    
                    # Clean up played file
                    rm -f "$next_file" 2>/dev/null
                    
                    # Remove the played index from queue tracking before updating
                    grep -v "^${EXPECTED_PLAYBACK_INDEX}:" "$PLAYBACK_QUEUE_FILE" > "$PLAYBACK_QUEUE_FILE.tmp" 2>/dev/null || true
                    mv "$PLAYBACK_QUEUE_FILE.tmp" "$PLAYBACK_QUEUE_FILE" 2>/dev/null || true
                    
                    # Update expected index
                    EXPECTED_PLAYBACK_INDEX=$((EXPECTED_PLAYBACK_INDEX + 1))
                else
                    # Wait briefly before checking again
                    sleep 0.1
                fi
            else
                # No queue file, wait longer
                sleep 0.5
            fi
            
            # Exit if streaming speech is disabled
            if [ "$STREAMING_SPEECH_ENABLED" != true ]; then
                break
            fi
        done
    } &
    
    PLAYBACK_COORDINATOR_PID=$!
}

# Function to stop the playback coordinator
stop_playback_coordinator() {
    if [ -n "$PLAYBACK_COORDINATOR_PID" ]; then
        kill "$PLAYBACK_COORDINATOR_PID" 2>/dev/null || true
        wait "$PLAYBACK_COORDINATOR_PID" 2>/dev/null || true
        PLAYBACK_COORDINATOR_PID=""
    fi
}

# Function to cleanup streaming speech system
cleanup_streaming_speech() {
    stop_playback_coordinator
    
    # Clean up temporary files
    rm -f "$STREAMING_SPEECH_DIR"/tts_*.wav 2>/dev/null
    rm -f "$PLAYBACK_QUEUE_FILE" 2>/dev/null
    
    # Reset state
    SENTENCE_INDEX_COUNTER=0
    EXPECTED_PLAYBACK_INDEX=1
    SENTENCE_BUFFER=""
}

# Function to detect sentence boundaries from streaming text
detect_sentence_boundaries() {
    local new_text="$1"
    
    # Add new text to buffer - this should accumulate!
    SENTENCE_BUFFER+="$new_text"
    
    # Debug: Show what's being added and current buffer state
    debug_log "Adding text chunk: '$(echo "$new_text" | tr '\n' ' ' | head -c 20)...'"
    debug_log "Buffer now (${#SENTENCE_BUFFER} chars): '$(echo "$SENTENCE_BUFFER" | tr '\n' ' ' | head -c 50)...'"
    
    # Simple bash sentence detection
    local detected_sentences=""
    local temp_buffer="$SENTENCE_BUFFER"
    
    # Extract complete sentences (ending with . ! ?) - speak immediately on punctuation
    while [[ "$temp_buffer" =~ ^(.*[.!?])(.*)$ ]]; do
        local sentence="${BASH_REMATCH[1]}"
        sentence=$(echo "$sentence" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        
        if [ -n "$sentence" ] && [[ "$sentence" =~ [a-zA-Z0-9] ]]; then
            if [ -n "$detected_sentences" ]; then
                detected_sentences="${detected_sentences}|||${sentence}"
            else
                detected_sentences="$sentence"
            fi
            debug_log "Extracted sentence: '$sentence'"
        fi
        
        temp_buffer="${BASH_REMATCH[2]}"
        temp_buffer=$(echo "$temp_buffer" | sed 's/^[[:space:]]*//')  # Remove leading spaces
    done
    
    # Update buffer with remaining text
    debug_log "Before buffer update - temp_buffer: '$(echo "$temp_buffer" | head -c 30)...'"
    debug_log "Before buffer update - original buffer: '$(echo "$SENTENCE_BUFFER" | head -c 30)...'"
    SENTENCE_BUFFER="$temp_buffer"
    debug_log "After buffer update - new buffer: '$(echo "$SENTENCE_BUFFER" | head -c 30)...'"
    
    # Debug: Show results
    local sentence_count=0
    if [ -n "$detected_sentences" ]; then
        sentence_count=$(echo "$detected_sentences" | grep -o "|||" | wc -l)
        sentence_count=$((sentence_count + 1))  # Add 1 since separator count is n-1
    fi
    
    if [ "$sentence_count" -gt 0 ]; then
        debug_log "Found $sentence_count complete sentences, remaining buffer: '$(echo "$SENTENCE_BUFFER" | head -c 30)...'"
    else
        debug_log "No complete sentences found, buffer: '$(echo "$SENTENCE_BUFFER" | head -c 30)...'"
    fi
    
    # Output sentences (convert from pipe-separated back to line-separated)
    if [ -n "$detected_sentences" ]; then
        echo "$detected_sentences" | tr '|||' '\n'
    fi
}

# Function to check if text should be spoken (filter out think-tags and system messages)
should_speak_text() {
    local text="$1"
    
    # Skip if empty
    [ -z "$text" ] && return 1
    
    # Skip system messages
    [[ "$text" =~ ^\[.*\].*$ ]] && return 1
    
    # Skip think-tag content (we'll handle this in the streaming parser)
    [[ "$text" =~ ^\<think\>.*\</think\>$ ]] && return 1
    
    # Skip URLs and technical markers
    [[ "$text" =~ ^https?:// ]] && return 1
    [[ "$text" =~ ^[[:space:]]*[\[\(].*[\]\)][[:space:]]*$ ]] && return 1
    
    # Skip very short fragments (less than 3 characters)
    [ ${#text} -lt 3 ] && return 1
    
    return 0
}

# Function to dispatch sentence to TTS with index
dispatch_sentence_to_tts() {
    local sentence="$1"
    local index="$2"
    
    # Skip if sentence shouldn't be spoken
    if ! should_speak_text "$sentence"; then
        return
    fi
    
    # Create background TTS process
    {
        local output_file="$STREAMING_SPEECH_DIR/tts_${index}.wav"
        local temp_file="$STREAMING_SPEECH_DIR/tts_${index}.tmp"
        
        # Escape quotes in the sentence for JSON (avoid xargs issues)
        local escaped_sentence
        escaped_sentence=$(echo "$sentence" | sed 's/"/\\"/g' | sed 's/'"'"'/\\'"'"'/g')
        
        # Call TTS API to generate audio file
        local api_response
        api_response=$(curl -s -X POST "$CODEDECK_API/v1/tts/generate" \
            -H "Content-Type: application/json" \
            -d "{\"text\": \"$escaped_sentence\", \"voice\": \"glados\"}" 2>/dev/null)
            
        if [ $? -eq 0 ] && [ -n "$api_response" ]; then
            # Parse the JSON response to get audio path
            local audio_path
            audio_path=$(echo "$api_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'audio_path' in data:
        print(data['audio_path'])
except:
    pass
" 2>/dev/null)
            
            if [ -n "$audio_path" ]; then
                # Download the audio file from the server
                local full_url="$CODEDECK_API$audio_path"
                if curl -s "$full_url" -o "$temp_file" 2>/dev/null && [ -s "$temp_file" ]; then
                    # Validate it's an audio file (check for WAV header)
                    if head -c 4 "$temp_file" 2>/dev/null | grep -q "RIFF\|WAV"; then
                        # Move to final location
                        mv "$temp_file" "$output_file"
                        
                        # Add to queue tracking
                        echo "${index}:${output_file}" >> "$PLAYBACK_QUEUE_FILE"
                        debug_log "TTS file created: $output_file"
                    else
                        # Not a valid audio file
                        rm -f "$temp_file" 2>/dev/null
                        debug_log "TTS response not valid audio"
                    fi
                else
                    debug_log "Failed to download audio from $full_url"
                fi
            else
                debug_log "No audio_path in API response: $api_response"
            fi
        else
            # Cleanup on failure
            rm -f "$temp_file" 2>/dev/null
        fi
    } &
}

# Function to process streaming text for sentence-based speech
process_streaming_text_for_speech() {
    local text="$1"
    local inside_think_tag="$2"  # true/false
    
    # Skip processing if streaming speech is disabled
    if [ "$STREAMING_SPEECH_ENABLED" != true ]; then
        return
    fi
    
    # Skip think-tag content
    if [ "$inside_think_tag" = true ]; then
        return
    fi
    
    # Detect complete sentences from the text
    local sentences
    sentences=$(detect_sentence_boundaries "$text")
    
    # Process each complete sentence
    if [ -n "$sentences" ]; then
        while IFS= read -r sentence; do
            if [ -n "$sentence" ]; then
                # Increment counter and dispatch
                SENTENCE_INDEX_COUNTER=$((SENTENCE_INDEX_COUNTER + 1))
                debug_log "Dispatching sentence #$SENTENCE_INDEX_COUNTER to TTS: '$(echo "$sentence" | head -c 40)...'"
                dispatch_sentence_to_tts "$sentence" "$SENTENCE_INDEX_COUNTER"
            fi
        done <<< "$sentences"
    fi
}

# Function to toggle streaming speech
toggle_streaming_speech() {
    if [ "$STREAMING_SPEECH_ENABLED" = true ]; then
        STREAMING_SPEECH_ENABLED=false
        cleanup_streaming_speech
        show_property_change "Streaming speech DISABLED" "Real-time sentence speech off" "🔇"
        play_sound_effect "confirm"
    else
        STREAMING_SPEECH_ENABLED=true
        init_streaming_speech
        show_property_change "Streaming speech ENABLED" "Real-time sentence speech active" "🎙️"
        play_sound_effect "confirm"
        
        # Test with a sample sentence
        echo -e "$DIM_PURPLE[Testing streaming speech...]$RESET"
        dispatch_sentence_to_tts "Streaming speech system is now active." 1
    fi
}

# ── CACHED SPEECH SYSTEM ──

# Function to check TTS capabilities and install Festival if needed
check_tts_capabilities() {
    # Check for Piper in multiple locations
    local piper_paths=(
        "$(command -v piper 2>/dev/null)"
        "$VIRTUAL_ENV/bin/piper"
        "$HOME/.local/bin/piper"
        "$(which piper 2>/dev/null)"
        "./venv/bin/piper"
        "../venv/bin/piper"
        "$CODEDECK_VENV_PATH/bin/piper"
    )
    
    for piper_path in "${piper_paths[@]}"; do
        if [ -n "$piper_path" ] && [ -x "$piper_path" ]; then
            echo "piper"
            return 0
        fi
    done
    
    # Check for Festival
    if command -v festival >/dev/null 2>&1; then
        echo "festival"
        return 0
    fi
    
    # No TTS found - show installation guidance
    echo -e "$YELLOW[!] No local TTS found.$RESET"
    echo -e "$DIM_PURPLE💡 Install Festival TTS manually:$RESET"
    
    if command -v apt >/dev/null 2>&1; then
        echo -e "$DIM_PURPLE   Ubuntu/Debian: sudo apt update && sudo apt install festival$RESET"
    elif command -v yum >/dev/null 2>&1; then
        echo -e "$DIM_PURPLE   RHEL/CentOS: sudo yum install festival$RESET"
    elif command -v dnf >/dev/null 2>&1; then
        echo -e "$DIM_PURPLE   Fedora: sudo dnf install festival$RESET"
    elif command -v brew >/dev/null 2>&1; then
        echo -e "$DIM_PURPLE   macOS: brew install festival$RESET"
    elif command -v pacman >/dev/null 2>&1; then
        echo -e "$DIM_PURPLE   Arch: sudo pacman -S festival$RESET"
    else
        echo -e "$DIM_PURPLE   Or download from: http://www.cstr.ed.ac.uk/projects/festival/$RESET"
    fi
    
    echo -e "$DIM_PURPLE💡 Alternative: Install Piper TTS: pip install piper-tts$RESET"
    echo "none"
    return 1
}

# Function to find Piper executable
find_piper_executable() {
    local piper_paths=(
        "$(command -v piper 2>/dev/null)"
        "$VIRTUAL_ENV/bin/piper"
        "$HOME/.local/bin/piper"
        "$(which piper 2>/dev/null)"
        "./venv/bin/piper"
        "../venv/bin/piper"
        "$CODEDECK_VENV_PATH/bin/piper"
    )
    
    for piper_path in "${piper_paths[@]}"; do
        if [ -n "$piper_path" ] && [ -x "$piper_path" ]; then
            echo "$piper_path"
            return 0
        fi
    done
    
    return 1
}

# Function to speak with Piper
# Function to get current voice model path
get_current_voice_model() {
    # Check configured voice models directory first
    if [ -f "$VOICE_MODELS_DIR/$CURRENT_VOICE" ]; then
        echo "$VOICE_MODELS_DIR/$CURRENT_VOICE"
        return 0
    fi
    
    # Fall back to system locations
    local voice_paths=(
        "/usr/share/piper/voices/$CURRENT_VOICE"
        "/usr/local/share/piper/voices/$CURRENT_VOICE"
        "$HOME/.local/share/piper/voices/$CURRENT_VOICE"
        "$VIRTUAL_ENV/share/piper/voices/$CURRENT_VOICE"
        "$CODEDECK_VENV_PATH/share/piper/voices/$CURRENT_VOICE"
    )
    
    for voice_path in "${voice_paths[@]}"; do
        if [ -n "$voice_path" ] && [ -f "$voice_path" ]; then
            echo "$voice_path"
            return 0
        fi
    done
    
    # Try to find any available voice
    local voice_paths=(
        "/usr/share/piper/voices/en_US-lessac-medium.onnx"
        "/usr/local/share/piper/voices/en_US-lessac-medium.onnx"
        "$HOME/.local/share/piper/voices/en_US-lessac-medium.onnx"
        "$VIRTUAL_ENV/share/piper/voices/en_US-lessac-medium.onnx"
        "$CODEDECK_VENV_PATH/share/piper/voices/en_US-lessac-medium.onnx"
    )
    
    for voice_path in "${voice_paths[@]}"; do
        if [ -n "$voice_path" ] && [ -f "$voice_path" ]; then
            echo "$voice_path"
            return 0
        fi
    done
    
    return 1
}

# Function to list available voice models
list_voice_models() {
    echo -e "$CYAN[📢 Voice Models]$RESET"
    echo -e "$DIM_PURPLE═══════════════════════════════════════════════════════════════$RESET"
    
    local voice_count=0
    local current_shown=false
    
    # Check configured voice models directory
    if [ -d "$VOICE_MODELS_DIR" ]; then
        echo -e "$BRIGHT_CYAN📁 Custom Voice Models ($VOICE_MODELS_DIR):$RESET"
        local found_custom=false
        
        for voice in "$VOICE_MODELS_DIR"/*.onnx; do
            if [ -f "$voice" ]; then
                local voice_name=$(basename "$voice")
                voice_count=$((voice_count + 1))
                found_custom=true
                
                if [ "$voice_name" = "$CURRENT_VOICE" ]; then
                    echo -e "$GREEN  ✓ $voice_name (CURRENT)$RESET"
                    current_shown=true
                else
                    echo -e "$DIM_PURPLE    $voice_name$RESET"
                fi
            fi
        done
        
        if [ "$found_custom" = false ]; then
            echo -e "$YELLOW    No custom voice models found$RESET"
        fi
        echo ""
    else
        echo -e "$YELLOW📁 Custom voice directory not found: $VOICE_MODELS_DIR$RESET"
        echo ""
    fi
    
    # Check system locations
    echo -e "$BRIGHT_CYAN🔧 System Voice Models:$RESET"
    local system_voice_paths=(
        "/usr/share/piper/voices"
        "/usr/local/share/piper/voices"
        "$HOME/.local/share/piper/voices"
        "$VIRTUAL_ENV/share/piper/voices"
        "$CODEDECK_VENV_PATH/share/piper/voices"
    )
    
    local found_system=false
    for voice_dir in "${system_voice_paths[@]}"; do
        if [ -n "$voice_dir" ] && [ -d "$voice_dir" ]; then
            local dir_voices=()
            while IFS= read -r -d '' voice; do
                dir_voices+=("$voice")
            done < <(find "$voice_dir" -name "*.onnx" -print0 2>/dev/null)
            
            if [ ${#dir_voices[@]} -gt 0 ]; then
                found_system=true
                echo -e "$DIM_PURPLE  $voice_dir:$RESET"
                
                for voice in "${dir_voices[@]}"; do
                    local voice_name=$(basename "$voice")
                    voice_count=$((voice_count + 1))
                    
                    if [ "$voice_name" = "$CURRENT_VOICE" ] && [ "$current_shown" = false ]; then
                        echo -e "$GREEN    ✓ $voice_name (CURRENT)$RESET"
                        current_shown=true
                    else
                        echo -e "$DIM_PURPLE      $voice_name$RESET"
                    fi
                done
            fi
        fi
    done
    
    if [ "$found_system" = false ]; then
        echo -e "$YELLOW    No system voice models found$RESET"
    fi
    
    echo ""
    echo -e "$DIM_PURPLE═══════════════════════════════════════════════════════════════$RESET"
    echo -e "$BRIGHT_CYAN📊 Total voices found: $voice_count$RESET"
    echo -e "$BRIGHT_CYAN🎙️ Current voice: $CURRENT_VOICE$RESET"
    
    if [ "$current_shown" = false ]; then
        echo -e "$YELLOW⚠ Current voice model not found in any location!$RESET"
    fi
    
    echo ""
    echo -e "$DIM_PURPLE💡 Use 'voice set <name>' to change voice model$RESET"
    echo -e "$DIM_PURPLE💡 Voice models directory: $VOICE_MODELS_DIR$RESET"
}

# Function to set voice model
set_voice_model() {
    local voice_name="$1"
    
    if [ -z "$voice_name" ]; then
        echo -e "$RED[✗] Voice name required$RESET"
        echo -e "$YELLOW💡 Usage: voice set <voice_name>$RESET"
        echo -e "$YELLOW💡 Use 'voice list' to see available voices$RESET"
        return 1
    fi
    
    # Add .onnx extension if not present
    if [[ "$voice_name" != *.onnx ]]; then
        voice_name="${voice_name}.onnx"
    fi
    
    # Check if voice exists in configured directory
    if [ -f "$VOICE_MODELS_DIR/$voice_name" ]; then
        CURRENT_VOICE="$voice_name"
        echo -e "$GREEN[✓] Voice model set to: $voice_name$RESET"
        echo -e "$DIM_PURPLE    Location: $VOICE_MODELS_DIR/$voice_name$RESET"
        return 0
    fi
    
    # Check system locations
    local voice_paths=(
        "/usr/share/piper/voices/$voice_name"
        "/usr/local/share/piper/voices/$voice_name"
        "$HOME/.local/share/piper/voices/$voice_name"
        "$VIRTUAL_ENV/share/piper/voices/$voice_name"
        "$CODEDECK_VENV_PATH/share/piper/voices/$voice_name"
    )
    
    for voice_path in "${voice_paths[@]}"; do
        if [ -n "$voice_path" ] && [ -f "$voice_path" ]; then
            CURRENT_VOICE="$voice_name"
            echo -e "$GREEN[✓] Voice model set to: $voice_name$RESET"
            echo -e "$DIM_PURPLE    Location: $voice_path$RESET"
            return 0
        fi
    done
    
    echo -e "$RED[✗] Voice model not found: $voice_name$RESET"
    echo -e "$YELLOW💡 Use 'voice list' to see available voices$RESET"
    return 1
}

speak_with_piper() {
    local message="$1"
    local cache_file="$2"
    
    # Find Piper executable
    local piper_exec
    piper_exec=$(find_piper_executable)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Get current voice model
    local voice_model
    voice_model=$(get_current_voice_model)
    
    if [ $? -eq 0 ] && [ -n "$voice_model" ]; then
        echo "$message" | "$piper_exec" --model "$voice_model" --output_file "$cache_file" >/dev/null 2>&1
    else
        # Try without specifying model (use default)
        echo "$message" | "$piper_exec" --output_file "$cache_file" >/dev/null 2>&1
    fi
    
    if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
        return 0
    else
        return 1
    fi
}

# Function to speak with Festival
speak_with_festival() {
    local message="$1"
    
    # Use Festival's text2wave to generate audio file
    local temp_wav="/tmp/festival_$(date +%s)_$$.wav"
    
    if echo "$message" | festival --tts --otype riff --output "$temp_wav" >/dev/null 2>&1; then
        if [ -f "$temp_wav" ] && [ -s "$temp_wav" ]; then
            aplay "$temp_wav" >/dev/null 2>&1 &
            (sleep 3 && rm -f "$temp_wav") &
            return 0
        fi
    fi
    
    # Fallback to direct Festival TTS (no file)
    echo "$message" | festival --tts >/dev/null 2>&1 &
    return $?
}

# Function to speak routine messages with hierarchical TTS fallback
speak_routine_message() {
    local cache_key="$1"
    local message="$2"
    
    [ -z "$message" ] && return 1
    
    debug_log "speak_routine_message called: cache_key='$cache_key', message='$message'"
    
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
    
    # TTS Hierarchy: Piper -> CodeDeck API -> Festival
    
    # 1. Try Piper first (if available) - skip API if Piper works locally
    if find_piper_executable >/dev/null 2>&1; then
        echo -ne "$DIM_PURPLE[🤖 Piper]$RESET"
        debug_log "Attempting Piper TTS for cache_key='$cache_key'"
        if speak_with_piper "$message" "$cache_file"; then
            # Play immediately without delays - Piper succeeded, skip other methods
            debug_log "Piper TTS successful, playing audio and returning early"
            aplay "$cache_file" >/dev/null 2>&1 &
            return 0
        fi
        echo -ne "$DIM_PURPLE[✗]$RESET"
        debug_log "Piper TTS failed, continuing to API"
        # Piper failed, continue to API
    else
        debug_log "Piper not available, skipping to API"
    fi
    
    # 2. Try CodeDeck API (only if Piper not available or failed)
    echo -ne "$DIM_PURPLE[🌐 API]$RESET"
    debug_log "Attempting CodeDeck API TTS for cache_key='$cache_key'"
    
    # Use generate endpoint with audio_file=true to get audio bytes directly
    mkdir -p "$RECORDING_CACHE_DIR" 2>/dev/null
    local temp_audio="$RECORDING_CACHE_DIR/codedeck_voice_$(date +%s)_$$.wav"
    
    # Request audio file bytes directly
    if curl -s -X POST "$CODEDECK_API/v1/tts/generate" \
        -H "Content-Type: application/json" \
        -d "{\"text\": \"$message\", \"voice\": \"glados\", \"audio_file\": true}" \
        -o "$temp_audio" 2>/dev/null && [ -s "$temp_audio" ]; then
        
        # Validate it's an audio file (check for WAV header)
        if head -c 4 "$temp_audio" 2>/dev/null | grep -q "RIFF"; then
            # Try to save to cache (best effort)
            cp "$temp_audio" "$cache_file" 2>/dev/null
            
            # Play audio locally on console device
            debug_log "CodeDeck API TTS successful, playing audio locally"
            aplay "$temp_audio" >/dev/null 2>&1 &
            
            # Clean up temp file after reasonable delay
            (sleep 5 && rm -f "$temp_audio") &
            return 0
        else
            debug_log "API response is not a valid WAV file"
            rm -f "$temp_audio" 2>/dev/null
        fi
    else
        debug_log "Failed to get audio bytes from CodeDeck API generate endpoint"
        rm -f "$temp_audio" 2>/dev/null
    fi
    
    echo -ne "$DIM_PURPLE[✗]$RESET"
    
    # 3. Fall back to Festival
    local tts_capability
    tts_capability=$(check_tts_capabilities)
    
    if [ "$tts_capability" = "festival" ]; then
        echo -ne "$DIM_PURPLE[🎭 Festival]$RESET"
        debug_log "Attempting Festival TTS as fallback"
        if speak_with_festival "$message"; then
            debug_log "Festival TTS successful"
            return 0
        fi
        echo -ne "$DIM_PURPLE[✗]$RESET"
        debug_log "Festival TTS failed"
    fi
    
    # All TTS methods failed
    echo -ne "$DIM_PURPLE[🔊 No TTS]$RESET"
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

# Function to toggle debug mode
toggle_debug() {
    if [ "$DEBUG_ENABLED" = true ]; then
        DEBUG_ENABLED=false
        show_property_change "Debug mode DISABLED" "Clean console output" "🔇"
        play_sound_effect "confirm"
    else
        DEBUG_ENABLED=true
        show_property_change "Debug mode ENABLED" "Verbose diagnostic output" "🐛"
        play_sound_effect "confirm"
        debug_log "Debug logging is now active"
    fi
}

# Function to hush all audio processes
hush() {
    echo -e "$RED[🤫 Hushing all audio...]$RESET"
    
    # Kill all aplay processes
    pkill -f "aplay" 2>/dev/null || true
    
    # Kill all CodeDeck TTS processes
    pkill -f "curl.*codedeck.*tts" 2>/dev/null || true
    
    # Stop streaming speech system
    stop_playback_coordinator
    
    # Clean up audio files
    rm -f "$STREAMING_SPEECH_DIR"/tts_*.wav "$STREAMING_SPEECH_DIR"/tts_*.tmp 2>/dev/null || true
    rm -f "$PLAYBACK_QUEUE_FILE" 2>/dev/null || true
    
    # Reset post-interrupt audio flag
    POST_INTERRUPT_AUDIO=false
    
    echo -e "$GREEN[✓ All quiet now]$RESET"
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
    
    # Reset interrupt flags
    INTERRUPT_REQUESTED=false
    POST_INTERRUPT_AUDIO=false
    
    # Initialize streaming speech for this conversation
    if [ "$STREAMING_SPEECH_ENABLED" = true ]; then
        init_streaming_speech
    fi
    
    # Check battery for 18650-based systems (uConsole)
    local current_battery
    local raw_battery
    current_battery=$(get_battery_percentage)
    
    # Check thresholds based on battery type
    raw_battery=$(get_raw_battery_percentage)
    
    # If raw != massaged, we have a special battery system (like 18650)
    if [ "$raw_battery" != "$current_battery" ]; then
        # Use raw percentage for threshold check since massaged will be much lower
        if [ -n "$raw_battery" ] && [ "$raw_battery" -lt 45 ]; then
            local charging_status
            charging_status=$(get_charging_status)
            if ! [[ "$charging_status" =~ (Charging|AC\ Power|on-line) ]]; then
                echo -e "$YELLOW⚠️  Battery at ${current_battery}% usable (${raw_battery}% raw) - voltage cutoff approaching$RESET"
                echo -e "$YELLOW💡 Charge soon to avoid unexpected shutdown and boot failure$RESET"
            fi
        fi
    else
        # Standard battery check for regular systems
        if [ -n "$current_battery" ] && [ "$current_battery" -lt 50 ]; then
            local charging_status
            charging_status=$(get_charging_status)
            if ! [[ "$charging_status" =~ (Charging|AC\ Power|on-line) ]]; then
                echo -e "$YELLOW⚠️  Battery at ${current_battery}% - consider charging$RESET"
            fi
        fi
    fi
    
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
    
    # Try Silicon Pipeline routing first
    local silicon_response_content=""
    if [ "$ENABLE_SILICON_PIPELINE" = true ] && [ -n "$SILICON_ACTIVE_ENDPOINT" ] && [ -n "$SILICON_ACTIVE_MODEL" ]; then
        debug_log "Attempting Silicon Pipeline routing..."
        echo -ne "$SILICON_PURPLE[GLaDOS via Silicon] $RESET"
        
        # Route through Silicon Pipeline
        local silicon_temp_content=$(mktemp)
        if route_silicon_chat_streaming "$messages_json" "$silicon_temp_content"; then
            # Silicon routing successful
            silicon_response_content=$(cat "$silicon_temp_content" 2>/dev/null)
            rm -f "$silicon_temp_content"
            
            # Add response to history and handle voice
            if [ -n "$silicon_response_content" ]; then
                MESSAGE_HISTORY+=("assistant:$silicon_response_content")
                
                if [ "$VOICE_ENABLED" = true ]; then
                    speak_routine_message "silicon_response" "$silicon_response_content"
                fi
                
                play_sound_effect "receive"
                echo  # New line after completion
                return 0
            fi
        else
            # Silicon routing failed, try local fallback
            debug_log "Silicon routing failed, falling back to local API"
            rm -f "$silicon_temp_content"
        fi
    fi
    
    # Make API call with constructed messages and capture streaming response
    echo -ne "$PURPLE[GLaDOS] $RESET"
    
    # Use a temporary file to capture the full content from streaming
    local temp_content=$(mktemp)
    local in_think_tag=false
    local current_think_content=""
    local think_tag_type=""
    
                        # Content length and completion tracking
                    local char_count=0
                    local max_chars=4000
                    local length_exceeded=false
                    local special_end_token="<END_OUTPUT>"
                    local found_end_token=false
    
    # Think tag normalization tracking
    local think_opens=0
    local think_closes=0
    local orphaned_close_handled=false
    
    # Loop detection variables
    local loop_detected=false
    local loop_suffix=". Oh, I appear to be in a loop, how embarrassing."
    local recent_segments=()  # Array to store recent text segments
    local segment_size=20     # Number of words to consider as a segment
    local current_segment=""
    local word_count=0
    
    # Start generation in background and capture PID
    {
        curl -s -X POST "$CODEDECK_API/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "X-Persona-ID: $GLADOS_PERSONA_ID" \
        -d "{
                \"model\": \"$CURRENT_MODEL\",
                \"messages\": $messages_json,
                \"max_tokens\": $max_chars, 
            \"temperature\": $CURRENT_TEMPERATURE,
                \"stream\": true
            }" 2>/dev/null | while IFS= read -r line; do
                # Check for interrupt, loop detection, or length exceeded
                if [ "$INTERRUPT_REQUESTED" = true ] || [ "$loop_detected" = true ] || [ "$length_exceeded" = true ]; then
                    # Exit the while loop immediately to stop processing
                    # The parent process cleanup will handle killing curl
                    exit 1
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
                    
                    # Process token with think-tag awareness and loop detection
                    if [ -n "$token" ]; then
                        # Ticket 1: Check for length limit and end token
                        char_count=$((char_count + ${#token}))
                        
                        # Check for special end token
                        if [[ "$token" == *"$special_end_token"* ]]; then
                            found_end_token=true
                        fi
                        
                        # Check if we've exceeded length limit (unless end token found)
                        if [ "$char_count" -gt "$max_chars" ] && [ "$found_end_token" = false ]; then
                            if [ "$length_exceeded" = false ]; then
                                length_exceeded=true
                                echo -e "\n$YELLOW[⚠ Output limit reached (${max_chars} chars) - stopping generation...]$RESET"
                                # The interrupt check above will handle killing the process
                                # Just continue to let the main loop handle the termination
                            fi
                        fi
                        
                        echo -n "$token" >> "$temp_content"
                        
                        # Enhanced think-tag processing with normalization
                        local full_so_far
                        full_so_far=$(cat "$temp_content" 2>/dev/null)
                        
                        # Count think tags for state tracking and normalization
                        think_opens=$(echo "$full_so_far" | grep -o '<think>' | wc -l)
                        think_closes=$(echo "$full_so_far" | grep -o '</think>' | wc -l)
                        
                        # Ticket 3: Handle orphaned </think> tag (assume <think> at start)
                        if [ "$think_closes" -gt "$think_opens" ] && [ "$orphaned_close_handled" = false ]; then
                            orphaned_close_handled=true
                            # If we have a closing tag but no opening, treat from start as think content
                            echo -ne "\n$DIM_PURPLE┌─ 💭 [ORPHANED THINK - FROM START] ─┐$RESET\n"
                            echo -ne "$DIM_PURPLE│$RESET "
                            # Process content before the </think> as think content
                            local before_close=$(echo "$full_so_far" | sed 's/<\/think>.*//')
                            if [ -n "$before_close" ]; then
                                echo -ne "\e[3;96m$before_close\e[0m"  # Italic cyan for thoughts
                            fi
                        fi
                        
                        # Are we inside a think tag?
                        local inside_think=false
                        if [ "$think_opens" -gt "$think_closes" ]; then
                            inside_think=true
                        fi
                        
                        # Loop detection - check all content including think tags
                        # Add words to current segment for loop detection
                        current_segment="$current_segment$token"
                        
                        # Count words (simple approximation using spaces)
                        local new_words=$(echo "$token" | grep -o ' ' | wc -l)
                        word_count=$((word_count + new_words))
                        
                        # When we have enough words for a segment, check for loops
                        if [ $word_count -ge $segment_size ]; then
                            # Clean the segment (remove extra whitespace and normalize)
                            local clean_segment=$(echo "$current_segment" | tr -s ' ' | xargs)
                            
                            if [ ${#clean_segment} -gt 10 ]; then  # Only check meaningful segments
                                # Check if this segment appears in recent segments
                                local repetition_count=1
                                for prev_segment in "${recent_segments[@]}"; do
                                    # Use fuzzy matching for loop detection (85% similarity)
                                    local similarity=$(echo "$clean_segment" "$prev_segment" | python3 -c "
import sys
lines = sys.stdin.read().strip().split('\n')
if len(lines) >= 1:
    import difflib
    parts = lines[0].split()
    if len(parts) >= 2:
        seg1 = ' '.join(parts[:len(parts)//2])
        seg2 = ' '.join(parts[len(parts)//2:])
        ratio = difflib.SequenceMatcher(None, seg1.lower(), seg2.lower()).ratio()
        print(int(ratio * 100))
    else:
        print(0)
else:
    print(0)
" 2>/dev/null)
                                        
                                        if [ "${similarity:-0}" -gt 85 ]; then
                                            repetition_count=$((repetition_count + 1))
                                        fi
                                    done
                                    
                                    # If we found 3+ repetitions, trigger loop detection
                                    if [ $repetition_count -ge 3 ]; then
                                        loop_detected=true
                                        echo -e "\n$YELLOW[⚠ Loop detected - halting generation]$RESET"
                                        break
                                    fi
                                    
                                    # Add to recent segments (keep last 5 segments)
                                    recent_segments+=("$clean_segment")
                                    if [ ${#recent_segments[@]} -gt 5 ]; then
                                        recent_segments=("${recent_segments[@]:1}")  # Remove first element
                                    fi
                                fi
                                
                                # Reset for next segment
                                current_segment=""
                                word_count=0
                            fi
                        fi
                        
                        # Enhanced think tag transitions (Ticket 2: Normalized handling)
                        if [[ "$token" == *"<think>"* ]]; then
                            # Opening think tag
                            if [ "$orphaned_close_handled" = false ]; then
                                echo -ne "\n$DIM_PURPLE┌─ 💭 [INTERNAL COGNITIVE PROCESSING] ─┐$RESET\n"
                                echo -ne "$DIM_PURPLE│$RESET "
                            fi
                            # Print remaining content after <think> tag
                            local after_tag=$(echo "$token" | sed 's/.*<think>//')
                            if [ -n "$after_tag" ]; then
                                echo -ne "\e[3;96m$after_tag\e[0m"  # Italic cyan for thoughts
                            fi
                        elif [[ "$token" == *"</think>"* ]]; then
                            # Closing think tag
                            if [ "$orphaned_close_handled" = false ]; then
                                # Normal closing tag
                                local before_tag=$(echo "$token" | sed 's/<\/think>.*//')
                                if [ -n "$before_tag" ]; then
                                    echo -ne "\e[3;96m$before_tag\e[0m"  # Italic cyan for thoughts
                                fi
                                echo -ne "\n$DIM_PURPLE└────────────────────────────────────────┘$RESET\n"
                                echo -ne "$PURPLE"
                            else
                                # This was an orphaned close tag, already handled above
                                echo -ne "\n$DIM_PURPLE└────────────────────────────────────────┘$RESET\n"
                                echo -ne "$PURPLE"
                            fi
                            # Print remaining content after </think> tag
                            local after_tag=$(echo "$token" | sed 's/.*<\/think>//')
                            if [ -n "$after_tag" ]; then
                                echo -ne "$after_tag"
                                # Process for streaming speech (outside think tag)
                                process_streaming_text_for_speech "$after_tag" false
                            fi
                        elif [ "$inside_think" = true ]; then
                            # Inside think tag - use italic cyan with visual boxing
                            echo -ne "\e[3;96m$token\e[0m"
                            # No streaming speech processing for think content
                        else
                            # Normal content - use regular purple
                            echo -ne "\e[35m$token\e[0m"
                            # Process for streaming speech (normal content)
                            process_streaming_text_for_speech "$token" false
                        fi
                    fi
            done
    } &
    
    # Capture the background process PID
    GENERATION_PID=$!
    
    # Wait for generation to complete
    wait "$GENERATION_PID" 2>/dev/null
    local generation_exit_code=$?
    
    # Enhanced process cleanup - kill all child processes if needed
    if [ "$generation_exit_code" -ne 0 ] || [ "$INTERRUPT_REQUESTED" = true ] || [ "$length_exceeded" = true ] || [ "$loop_detected" = true ]; then
        # Kill the background process group to stop curl and any child processes
        if [ -n "$GENERATION_PID" ]; then
            # Kill the process group (negative PID) to get curl and subprocesses
            kill -TERM -"$GENERATION_PID" 2>/dev/null || true
            sleep 0.1
            # Force kill if still running
            kill -KILL -"$GENERATION_PID" 2>/dev/null || true
        fi
        
        # Also kill any remaining curl processes related to CodeDeck API
        pkill -f "curl.*codedeck.*chat/completions" 2>/dev/null || true
        
        # Only kill audio if this was a double-interrupt (hush requested)
        if [ "$POST_INTERRUPT_AUDIO" = false ]; then
            # This was a double-interrupt, audio was already hushed
            debug_log "Audio already hushed due to double interrupt"
        else
            # Single interrupt - let audio continue
            debug_log "Single interrupt - allowing audio to continue playing"
        fi
        
        # Reset terminal state only if needed
        if [ "$IS_SSH_SESSION" = true ]; then
            stty sane 2>/dev/null || true
        else
            stty echo 2>/dev/null || true
            stty icanon 2>/dev/null || true
        fi
        
        echo -e "$DIM_PURPLE[🛑 Generation and audio processes cleaned up]$RESET"
    fi
    
    # Reset generation PID
    GENERATION_PID=""
    
    echo  # New line after completion
    
    # Read the full content from temp file
    local full_content=""
    if [ -f "$temp_content" ]; then
        full_content=$(cat "$temp_content")
        rm -f "$temp_content"
    fi
    
    # Handle loop detection case
    if [ "$loop_detected" = true ] && [ -n "$full_content" ]; then
        # Add the embarrassing suffix
        full_content="${full_content}${loop_suffix}"
        echo -e "$PURPLE$loop_suffix$RESET"
        
        # Add assistant response to history
        MESSAGE_HISTORY+=("assistant:$full_content")
        
        # Voice the response including the suffix if voice is enabled
        if [ "$VOICE_ENABLED" = true ]; then
            speak_routine_message "loop_response" "$full_content"
        fi
        
    # Process if not manually interrupted (but allow length_exceeded and loop_detected)
    elif [ "$INTERRUPT_REQUESTED" != true ] && [ -n "$full_content" ]; then
        # Add assistant response to history
        MESSAGE_HISTORY+=("assistant:$full_content")
        
        # If voice is enabled, use TTS to speak the response (clean of think tags)
        if [ "$VOICE_ENABLED" = true ]; then
            speak_routine_message "response" "$full_content"
        fi
        
        # Show status message for truncated content
        if [ "$length_exceeded" = true ]; then
            echo -e "$YELLOW[📏 Response was truncated at ${max_chars} characters]$RESET"
        fi
        
        # Reset post-interrupt flag since normal processing completed
        POST_INTERRUPT_AUDIO=false
    elif [ "$INTERRUPT_REQUESTED" = true ]; then
        # Handle interrupted generation - still process any content that was generated
        if [ -n "$full_content" ]; then
            # Add partial response to history for context
            MESSAGE_HISTORY+=("assistant:$full_content")
            
            # If voice is enabled, speak the partial content (clean of think tags)
            if [ "$VOICE_ENABLED" = true ]; then
                echo -e "$DIM_PURPLE[🔊 Speaking partial response...]$RESET"
                
                # Clean the content for speech (remove think tags and markup)
                local clean_content
                clean_content=$(echo "$full_content" | python3 -c "
import sys, re
content = sys.stdin.read()
# Remove think-tags and their content
content = re.sub(r'<(think|thought|reasoning|plan|observe|critique)>.*?</\1>', '', content, flags=re.DOTALL | re.IGNORECASE)
# Clean up extra whitespace
content = re.sub(r'\s+', ' ', content).strip()
print(content)
")
                
                if [ -n "$clean_content" ]; then
                    speak_routine_message "interrupted_response" "$clean_content"
                else
                    echo -e "$DIM_PURPLE[No speakable content after cleaning]$RESET"
                fi
            fi
            
            # Allow streaming speech to finish any queued sentences
            if [ "$STREAMING_SPEECH_ENABLED" = true ]; then
                echo -e "$DIM_PURPLE[🎙️ Completing streaming speech for generated content...]$RESET"
                # Give streaming speech a moment to finish processing queued sentences
                sleep 1
            fi
        else
            # No content generated, remove the user message from history
            if [ ${#MESSAGE_HISTORY[@]} -gt 0 ]; then
                unset 'MESSAGE_HISTORY[-1]'
            fi
        fi
        echo -e "$DIM_PURPLE[Generation stopped. You can continue the conversation normally.]$RESET"
    else
        echo -e "$RED🔧 No AI endpoints available$RESET"
        echo -e "$YELLOW💡 Check Silicon endpoints and/or local CodeDeck service$RESET"
        
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
        echo -e "$GREEN[✓] Local CODEDECK API is ONLINE$RESET"
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
        echo -e "$RED[✗] Local CODEDECK API is OFFLINE$RESET"
        echo -e "$YELLOW💡 Start the service with: sudo systemctl start codedeck.service$RESET"
    fi
    
    # Also check Silicon Pipeline status
    echo ""
    if [ "$ENABLE_SILICON_PIPELINE" = true ]; then
        echo -e "$DIM_PURPLE[Checking Silicon Pipeline...]$RESET"
        discover_silicon_endpoints_summary >/dev/null
        local silicon_count=$?
        
        if [ $silicon_count -gt 0 ]; then
            echo -e "$GREEN[✓] Silicon Pipeline: $silicon_count endpoint(s) available$RESET"
            if [ -n "$SILICON_ACTIVE_ENDPOINT" ]; then
                echo -e "$GREEN🌐 Active: $SILICON_ACTIVE_ENDPOINT ($SILICON_ACTIVE_MODEL)$RESET"
            fi
        else
            echo -e "$YELLOW[⚠] Silicon Pipeline: No endpoints available$RESET"
        fi
    else
        echo -e "$DIM_PURPLE[Silicon Pipeline: DISABLED]$RESET"
    fi
    
    # Show operation mode summary
    echo ""
    local local_available=$([[ $? -eq 0 && -n "$status_response" ]] && echo true || echo false)
    local silicon_available=$([[ "$ENABLE_SILICON_PIPELINE" = true && -n "$SILICON_ACTIVE_ENDPOINT" ]] && echo true || echo false)
    
    if [ "$local_available" = true ] && [ "$silicon_available" = true ]; then
        echo -e "$GREEN🧠 Operation Mode: HYBRID (Silicon + Local)$RESET"
        echo -e "$DIM_PURPLE   Requests will try Silicon first, then fallback to local$RESET"
    elif [ "$silicon_available" = true ]; then
        echo -e "$CYAN🧠 Operation Mode: SILICON ONLY$RESET"
        echo -e "$DIM_PURPLE   All requests route through Silicon endpoints$RESET"
    elif [ "$local_available" = true ]; then
        echo -e "$YELLOW🧠 Operation Mode: LOCAL ONLY$RESET"
        echo -e "$DIM_PURPLE   All requests use local CodeDeck API$RESET"
    else
        echo -e "$RED🧠 Operation Mode: NO AI AVAILABLE$RESET"
        echo -e "$DIM_PURPLE   No AI endpoints are currently accessible$RESET"
    fi
    
    echo ""
    # Show detailed session status
    show_session_status
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

# Function to set AI creativity/spontaneity level (temperature)
set_mood() {
    local new_temp="$1"
    
    if [ -z "$new_temp" ]; then
        local temp_percentage=$(echo "$CURRENT_TEMPERATURE * 100" | bc 2>/dev/null | cut -d. -f1)
        if [ -z "$temp_percentage" ]; then
            temp_percentage=70
        fi
        echo -e "$GREEN[ℹ] Current AI mood: $temp_percentage% creative/spontaneous (temperature: $CURRENT_TEMPERATURE)$RESET"
        echo -e "$DIM_PURPLE    Usage: mood <0-100> or mood <0.0-1.0> - Set AI creativity level$RESET"
        echo -e "$DIM_PURPLE    Examples: mood 20 (logical), mood 50 (balanced), mood 80 (creative)$RESET"
        return
    fi
    
    # Convert percentage to decimal if needed
    local decimal_temp="$new_temp"
    if [[ "$new_temp" =~ ^[0-9]+$ ]] && [ "$new_temp" -ge 0 ] && [ "$new_temp" -le 100 ]; then
        # It's a percentage, convert to decimal
        decimal_temp=$(echo "scale=2; $new_temp / 100" | bc 2>/dev/null || echo "0.7")
    elif [[ "$new_temp" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        # It's already decimal, validate range
        if ! echo "$new_temp >= 0.0 && $new_temp <= 1.0" | bc -l 2>/dev/null | grep -q 1; then
            echo -e "$RED[✗] Temperature must be between 0.0 and 1.0 (or 0-100 as percentage)$RESET"
            return
        fi
        decimal_temp="$new_temp"
    else
        echo -e "$RED[✗] Invalid temperature format. Use 0-100 (percentage) or 0.0-1.0 (decimal)$RESET"
        return
    fi
    
    CURRENT_TEMPERATURE="$decimal_temp"
    local display_percentage=$(echo "$decimal_temp * 100" | bc 2>/dev/null | cut -d. -f1)
    if [ -z "$display_percentage" ]; then
        display_percentage=70
    fi
    
    play_sound_effect "confirm"
    
    # Descriptive mood based on temperature
    local mood_desc="balanced"
    if echo "$decimal_temp < 0.3" | bc -l 2>/dev/null | grep -q 1; then
        mood_desc="logical & focused"
    elif echo "$decimal_temp > 0.8" | bc -l 2>/dev/null | grep -q 1; then
        mood_desc="highly creative & abstract"
    elif echo "$decimal_temp > 0.6" | bc -l 2>/dev/null | grep -q 1; then
        mood_desc="creative & spontaneous"
    fi
    
    show_property_change "AI mood updated" "${display_percentage}% - $mood_desc" "🎭"
    
    if [ "$VOICE_ENABLED" = true ]; then
        speak_routine_message "mood_updated_$display_percentage" "Mood adjusted to $display_percentage percent creativity."
    fi
}

# Function to show current session status
show_session_status() {
    echo -e "$DIM_PURPLE┌─── SESSION STATUS ───┐$RESET"
    
    # System & AI on one line
    local temp_percentage=$(echo "$CURRENT_TEMPERATURE * 100" | bc 2>/dev/null | cut -d. -f1)
    if [ -z "$temp_percentage" ]; then
        temp_percentage=70
    fi
    local mood_desc="balanced"
    if echo "$CURRENT_TEMPERATURE < 0.3" | bc -l 2>/dev/null | grep -q 1; then
        mood_desc="logical"
    elif echo "$CURRENT_TEMPERATURE > 0.8" | bc -l 2>/dev/null | grep -q 1; then
        mood_desc="creative"
    elif echo "$CURRENT_TEMPERATURE > 0.6" | bc -l 2>/dev/null | grep -q 1; then
        mood_desc="spontaneous"
    fi
    
    echo -e "$GREEN🤖$RESET Model: $CURRENT_MODEL"
    echo -e "$GREEN🎭$RESET Mood: ${temp_percentage}% ($mood_desc) | $GREEN📚$RESET Context: $CONTEXT_LENGTH pairs (${#MESSAGE_HISTORY[@]} stored)"
    
    # System message (compact)
    if [ -n "$SESSION_SYSTEM_MESSAGE" ]; then
        echo -e "$GREEN🧠$RESET System: ${SESSION_SYSTEM_MESSAGE:0:50}..."
    else
        echo -e "$GREEN🧠$RESET System: (default)"
    fi
    
    # Audio status on one line
    local voice_status="OFF"
    local stream_status="OFF" 
    local sound_status="OFF"
    local debug_status="OFF"
    
    [ "$VOICE_ENABLED" = true ] && voice_status="ON"
    [ "$STREAMING_SPEECH_ENABLED" = true ] && stream_status="ON"
    [ "$SOUND_ENABLED" = true ] && sound_status="ON"
    [ "$DEBUG_ENABLED" = true ] && debug_status="ON"
    
    # Determine operation mode for status
    local local_api_available=false
    local silicon_available=false
    
    # Check local API availability (quick check)
    if curl -s --connect-timeout 2 "$CODEDECK_API/v1/status" >/dev/null 2>&1; then
        local_api_available=true
    fi
    
    # Check Silicon availability
    if [ "$ENABLE_SILICON_PIPELINE" = true ] && [ -n "$SILICON_ACTIVE_ENDPOINT" ]; then
        silicon_available=true
    fi
    
    # Determine operation mode
    local operation_mode=""
    if [ "$local_api_available" = true ] && [ "$silicon_available" = true ]; then
        operation_mode="HYBRID (Silicon + Local)"
    elif [ "$silicon_available" = true ]; then
        operation_mode="SILICON ONLY"
    elif [ "$local_api_available" = true ]; then
        operation_mode="LOCAL ONLY"
    else
        operation_mode="NO AI AVAILABLE"
    fi
    
    echo -e "$GREEN🔊$RESET Voice:$voice_status | Stream:$stream_status | Sound:$sound_status | Debug:$debug_status"
    echo -e "$GREEN🧠$RESET Mode:$operation_mode | $GREEN🌐$RESET Active:${SILICON_ACTIVE_ENDPOINT:-"Local API"}"
    
    # System health (compact)
    local battery_percent
    battery_percent=$(get_battery_percentage)
    local cpu_temp
    cpu_temp=$(get_cpu_temperature)
    
    local battery_display="N/A"
    if [ -n "$battery_percent" ]; then
        local charging_status
        charging_status=$(get_charging_status)
        local charge_icon=""
        [[ "$charging_status" =~ (Charging|AC\ Power|on-line) ]] && charge_icon="⚡"
        battery_display="${battery_percent}%${charge_icon}"
    fi
    
    local cpu_display="N/A"
    if [ -n "$cpu_temp" ]; then
        cpu_display="${cpu_temp}°C"
    fi
    
    echo -e "$GREEN🔋$RESET Battery: $battery_display | $GREEN🌡️$RESET CPU: $cpu_display"
    echo -e "$DIM_PURPLE└────────────────────────┘$RESET"
}

# Function to list and select models
manage_models() {
    local action="$1"
    local model_name="$2"
    
    if [ "$action" = "list" ] || [ -z "$action" ]; then
        echo -e "$DIM_PURPLE[Scanning available neural models...]$RESET"
        
        # Create unified model list with continuous numbering
        local unified_models=$(mktemp)
        local model_index=1
        local silicon_model_count=0
        local total_silicon_endpoints=0
        
        # Build complete unified model list first
        if [ "$ENABLE_SILICON_PIPELINE" = true ]; then
            # Collect Silicon models with continuous numbering
            for endpoint in "${SILICON_ENDPOINTS[@]}"; do
                if check_silicon_endpoint "$endpoint"; then
                    local models
                    models=$(get_silicon_models "$endpoint")
                    
                    if [ -n "$models" ]; then
                        total_silicon_endpoints=$((total_silicon_endpoints + 1))
                        local priority_marker=""
                        if [ "$endpoint" = "$SILICON_ACTIVE_ENDPOINT" ]; then
                            priority_marker=" [PRIORITY]"
                        fi
                        
                        # Add header for this endpoint
                        echo "SILICON_HEADER|📡 $endpoint$priority_marker" >> "$unified_models"
                        
                        while IFS= read -r model; do
                            if [ -n "$model" ]; then
                                local current_marker=""
                                if [ "$model" = "$SILICON_ACTIVE_MODEL" ] && [ "$endpoint" = "$SILICON_ACTIVE_ENDPOINT" ]; then
                                    current_marker=" <- CURRENT"
                                fi
                                
                                echo "SILICON|$model_index|$model|$endpoint|$current_marker" >> "$unified_models"
                                model_index=$((model_index + 1))
                                silicon_model_count=$((silicon_model_count + 1))
                            fi
                        done <<< "$models"
                        
                        echo "SEPARATOR|" >> "$unified_models"
                    fi
                fi
            done
        fi
        
        # Add local models to unified list
        local models_response
        models_response=$(curl -s "$CODEDECK_API/v1/models" 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$models_response" ]; then
            # Add local models header and models to unified list
            echo "LOCAL_HEADER|🏠 CodeDeck Local API" >> "$unified_models"
            
            echo "$models_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', [])
    
    start_index = $model_index  # Continue from where Silicon left off
    
    # Write models to unified temp file
    for i, model in enumerate(models):
        name = model.get('id', 'unknown')
        desc = model.get('description', 'No description')
        loaded = model.get('loaded', False)
        status = '🟢 LOADED' if loaded else '⚪ Available'
        current = ' <- CURRENT' if name == '$CURRENT_MODEL' else ''
        model_num = start_index + i
        print(f'LOCAL|{model_num}|{status}|{name}|{desc}|{current}')
    
    print(f'TOTAL_COUNT:{len(models)}', file=sys.stderr)
except Exception as e:
    print('ERROR:Could not parse models list', file=sys.stderr)
    print(f'ERROR:{e}', file=sys.stderr)
" 2>"$unified_models.log" >>"$unified_models"
            
            # Check for errors
            if grep -q "ERROR:" "$unified_models.log" 2>/dev/null; then
                echo -e "$RED[✗] Could not parse models list$RESET"
                cat "$unified_models.log" | grep "ERROR:" | sed 's/ERROR://'
                rm -f "$unified_models" "$unified_models.log"
                return
            fi
            
            # Get total local count
            local local_count
            local_count=$(grep "TOTAL_COUNT:" "$unified_models.log" 2>/dev/null | cut -d: -f2)
            local_count=${local_count:-0}
        else
            local_count=0
        fi
        
        # Display unified models list with proper pagination
        local total_models=$((silicon_model_count + local_count))
        
        if [ "$total_models" -eq 0 ]; then
            echo -e "$RED❌ No models available from any source$RESET"
            echo -e "$YELLOW💡 Check Silicon endpoints and/or local CodeDeck service$RESET"
            rm -f "$unified_models" "$unified_models.log"
            return
        fi
        
        echo ""
        echo -e "$DIM_PURPLE┌─────────────────── UNIFIED MODEL LIST ─────────────────────┐$RESET"
        echo -e "$DIM_PURPLE│ Found $total_models total models ($silicon_model_count Silicon + $local_count Local)$RESET"
        echo -e "$DIM_PURPLE└─────────────────────────────────────────────────────────────┘$RESET"
        echo ""
        
        # Paginate the unified output (show 10 items at a time including headers)
        local items_per_page=10
        local current_line=1
        local total_lines
        total_lines=$(wc -l < "$unified_models")
        local page_num=1
        
        while [ "$current_line" -le "$total_lines" ]; do
            # Show page header
            echo -e "$CYAN────────────────── Page $page_num ──────────────────$RESET"
            
            # Show next batch of models (count actual items displayed)
            local items_shown=0
            local start_line=$current_line
            
            while [ "$current_line" -le "$total_lines" ] && [ "$items_shown" -lt "$items_per_page" ]; do
                local line
                line=$(sed -n "${current_line}p" "$unified_models")
                
                if [ -n "$line" ]; then
                    IFS='|' read -r type field1 field2 field3 field4 field5 <<< "$line"
                    
                    case "$type" in
                        "SILICON_HEADER")
                            echo -e "$SILICON_GREEN$field1$RESET"
                            items_shown=$((items_shown + 1))
                            ;;
                        "LOCAL_HEADER")
                            echo -e "$PURPLE$field1$RESET"
                            items_shown=$((items_shown + 1))
                            ;;
                        "SILICON")
                            echo -e "$SILICON_PURPLE  $field1. 🔥 $field2$field4$RESET"
                            items_shown=$((items_shown + 1))
                            ;;
                        "LOCAL")
                            echo -e "$CYAN  $field1. $field2 $field3$field5$RESET"
                            echo -e "$DIM_PURPLE     $field4$RESET"
                            items_shown=$((items_shown + 1))
                            ;;
                        "SEPARATOR")
                            echo ""
                            ;;
                    esac
                fi
                
                current_line=$((current_line + 1))
            done
            
            # Show pagination controls if there are more models
            if [ "$current_line" -le "$total_lines" ]; then
                echo ""
                echo -e "$YELLOW[Press any key for next page...]$RESET"
                read -n 1 -s
                echo ""
                page_num=$((page_num + 1))
            fi
        done
        
        echo ""
        echo -e "$DIM_PURPLE┌─────────────────────────────────────────────────────┐$RESET"
        echo -e "$DIM_PURPLE│ UNIFIED MODEL SELECTION:$RESET"
        echo -e "$DIM_PURPLE│   model select 3              - Select any model #3$RESET"
        echo -e "$DIM_PURPLE│   model select deepseek_r1    - Select by name$RESET"
        echo -e "$DIM_PURPLE│   silicon endpoints           - Choose priority endpoint$RESET"
        echo -e "$DIM_PURPLE└─────────────────────────────────────────────────────┘$RESET"
        
        # Clean up temp files
        rm -f "$unified_models" "$unified_models.log"
        
    elif [ "$action" = "select" ]; then
        if [ -z "$model_name" ]; then
            echo -e "$YELLOW[!] Usage: model select <model_name_or_number>$RESET"
            echo -e "$DIM_PURPLE    Examples:$RESET"
            echo -e "$DIM_PURPLE      model select 1                    - Select first model$RESET"
            echo -e "$DIM_PURPLE      model select deepseek_r1_distill  - Select by name$RESET"
            return
        fi
        
        # Check if model_name is a number (unified index selection)
        if [[ "$model_name" =~ ^[0-9]+$ ]]; then
            echo -e "$DIM_PURPLE[Resolving unified model index #$model_name...]$RESET"
            
            # Build unified model list to resolve index
            local unified_models=$(mktemp)
            local model_index=1
            local silicon_model_count=0
            local found_model=""
            local is_silicon=false
            
            # Collect Silicon models first
            if [ "$ENABLE_SILICON_PIPELINE" = true ]; then
                for endpoint in "${SILICON_ENDPOINTS[@]}"; do
                    if check_silicon_endpoint "$endpoint"; then
                        local models
                        models=$(get_silicon_models "$endpoint")
                        
                        if [ -n "$models" ]; then
                            while IFS= read -r model; do
                                if [ -n "$model" ]; then
                                    if [ "$model_index" -eq "$model_name" ]; then
                                        found_model="$model"
                                        found_endpoint="$endpoint"
                                        is_silicon=true
                                        break 2
                                    fi
                                    model_index=$((model_index + 1))
                                    silicon_model_count=$((silicon_model_count + 1))
                                fi
                            done <<< "$models"
                        fi
                    fi
                done
            fi
            
            # If not found in Silicon, check local models
            if [ -z "$found_model" ]; then
                local models_response
                models_response=$(curl -s "$CODEDECK_API/v1/models" 2>/dev/null)
                
                if [ $? -eq 0 ] && [ -n "$models_response" ]; then
                    found_model=$(echo "$models_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', [])
    target_index = int('$model_name') - $silicon_model_count - 1  # Adjust for Silicon models
    
    if 0 <= target_index < len(models):
        print(models[target_index].get('id', ''))
    else:
        print('')
except:
    print('')
")
                fi
            fi
            
            if [ -z "$found_model" ]; then
                echo -e "$RED[✗] Invalid model index: $model_name$RESET"
                echo -e "$YELLOW💡 Use 'model list' to see available models$RESET"
                rm -f "$unified_models"
                return
            fi
            
            if [ "$is_silicon" = true ]; then
                echo -e "$GREEN[✓ Model #$model_name resolved to Silicon: $found_model on $found_endpoint]$RESET"
                
                # Validate endpoint and model before switching
                echo -e "$DIM_PURPLE[Validating Silicon endpoint and model...]$RESET"
                debug_log "Checking Silicon endpoint: $found_endpoint"
                if check_silicon_endpoint "$found_endpoint"; then
                    local available_models
                    available_models=$(get_silicon_models "$found_endpoint")
                    
                    if echo "$available_models" | grep -q "^${found_model}$"; then
                        # Model validated successfully - proceed with switch
                        debug_log "Model validation successful: $found_model found on $found_endpoint"
                        SILICON_ACTIVE_ENDPOINT="$found_endpoint"
                        SILICON_ACTIVE_MODEL="$found_model"
                        CURRENT_MODEL="$found_model"
                        debug_log "Setting Silicon variables and announcing status"
                        announce_silicon_status "connected"
                        play_sound_effect "switch"
                        show_property_change "Silicon model switched" "$found_model @ ${found_endpoint##*/}" "🧠"
                        if [ "$VOICE_ENABLED" = true ]; then
                            speak_routine_message "silicon_model_switched" "Silicon model $found_model loaded."
                        fi
                        rm -f "$unified_models"
                        return 0
                    else
                        echo -e "$RED[✗] Model '$found_model' no longer available on $found_endpoint$RESET"
                        echo -e "$YELLOW💡 Model may have been unloaded. Try 'model list' to see current options$RESET"
                        rm -f "$unified_models"
                        return 1
                    fi
                else
                    echo -e "$RED[✗] Silicon endpoint $found_endpoint is no longer accessible$RESET"
                    echo -e "$YELLOW💡 Endpoint may be offline. Try 'silicon endpoints' to check status$RESET"
                    rm -f "$unified_models"
                    return 1
                fi
            else
                echo -e "$GREEN[✓ Model #$model_name resolved to Local: $found_model]$RESET"
                model_name="$found_model"
            fi
            
            rm -f "$unified_models"
        else
            # Try by name - check Silicon first, then local
            if [ "$ENABLE_SILICON_PIPELINE" = true ]; then
                echo -e "$DIM_PURPLE[Trying Silicon endpoints...]$RESET"
                if select_silicon_model_by_name_or_index "$model_name"; then
                    return 0  # Success with Silicon
                fi
            fi
            echo -e "$DIM_PURPLE[Trying local API...]$RESET"
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
        echo -e "$DIM_PURPLE    model                    - List available models$RESET"
        echo -e "$DIM_PURPLE    model list               - List available models$RESET"
        echo -e "$DIM_PURPLE    model select <name>      - Load and switch to model by name$RESET"
        echo -e "$DIM_PURPLE    model select <number>    - Load and switch to model by index$RESET"
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
    echo "   silicon          - Show Silicon Pipeline status"
    echo "   silicon toggle   - Enable/disable remote neural mesh"
    echo "   silicon endpoints - Select priority Silicon endpoint"
    echo -e "$RESET"
    echo -e "$YELLOW[Press any key to continue...]$RESET"
    read -n 1 -s
    
    echo -e "$DIM_PURPLE"
    echo "👤 PERSONAS & MODELS:"
    echo "   personas         - List available consciousness modules"
    echo "   switch <name>    - Switch AI persona (glados, coder, writer)"
    echo "   model            - List available models (paginated)"
    echo "   model select <n> - Load model by index number (e.g., model select 3)"
    echo "   model select <name> - Load model by name (e.g., model select deepseek_r1)"
    echo ""
    echo "🧠 CONTEXT MANAGEMENT:"
    echo "   system <msg>     - Set system message for this session"
    echo "   system clear     - Remove current system message"
    echo "   system           - Show current system message"
    echo "   mood <0-100>     - Set AI creativity (0=logical, 100=creative)"
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
    echo "   stream-speech    - Toggle real-time sentence-based speech streaming"
    echo "   sound            - Toggle sound effects (UI feedback sounds)"
    echo "   hush             - Stop all audio playback"
    echo "   hear             - Record 10s of audio and convert to text input"
    echo "   audio-diag       - Run comprehensive audio system diagnostics"
    echo "   tts-diag         - Run TTS (speech synthesis) diagnostics"
    echo "   voice [list]     - List available voice models for Piper TTS"
    echo "   voice set <name> - Set voice model (e.g., voice set en_US-GlaDOS-medium)"
    echo "   voice current    - Show current voice model and location"
    echo ""
    echo "🎮 INTERFACE:"
    echo "   cls              - Clear the console display"
    echo "   debug            - Toggle debug/diagnostic output"
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
    echo -e "$DIM_PURPLE🔁🔄 Initializing contextual recursion engine…$RESET"
    echo -e "$DIM_PURPLE𓁹 GLaDOS consciousness module loaded...$RESET"
    
    # Initialize Silicon Pipeline if enabled
    if [ "$ENABLE_SILICON_PIPELINE" = true ]; then
        echo -e "$DIM_PURPLE🧠 Initializing Silicon Pipeline neural mesh...$RESET"
        start_silicon_monitor
    fi
    
    # Play startup sound
    play_sound_effect "start"
    
    # Show battery status on startup
    echo -ne "$DIM_PURPLE[Checking power status..."
    sleep 0.1
    echo -e "]$RESET"
    show_battery_status
    
    echo -e "$PURPLE[GLaDOS] Well, well, well. Look who's decided to interface with me directly.$RESET"
    echo -e "$DIM_PURPLE💡 Type 'help' for available commands$RESET"
    echo -e "$DIM_PURPLE🎨 Colors: $BRIGHT_ORANGE[Your messages]$DIM_PURPLE, $PURPLE[Local AI]$DIM_PURPLE, $SILICON_PURPLE[Silicon AI]$DIM_PURPLE, $CYAN[Think-tags]$RESET"
    
    # Voice status
    local voice_status="$RED[DISABLED]"
    if [ "$VOICE_ENABLED" = true ]; then
        voice_status="$GREEN[ENABLED]"
    fi
    
    # Streaming speech status
    local stream_status="$RED[DISABLED]"
    if [ "$STREAMING_SPEECH_ENABLED" = true ]; then
        stream_status="$GREEN[ENABLED]"
    fi
    
    # Sound effects status
    local sound_status="$GREEN[ENABLED]"
    if [ "$SOUND_ENABLED" != true ]; then
        sound_status="$RED[DISABLED]"
    fi
    
    # Debug status
    local debug_status="$RED[DISABLED]"
    if [ "$DEBUG_ENABLED" = true ]; then
        debug_status="$GREEN[ENABLED]"
    fi
    
    echo -e "$DIM_PURPLE🔊 Voice: $voice_status$DIM_PURPLE - Type 'speak' to toggle | 🎙️ Stream: $stream_status$DIM_PURPLE - Type 'stream-speech' to toggle$RESET"
    echo -e "$DIM_PURPLE🎵 Sound: $sound_status$DIM_PURPLE - Type 'sound' to toggle | 🐛 Debug: $debug_status$DIM_PURPLE - Type 'debug' to toggle$RESET"
    
    # Determine operation mode
    local operation_mode=""
    local local_api_available=false
    local silicon_available=false
    
    # Check local API availability
    if curl -s --connect-timeout 2 "$CODEDECK_API/v1/status" >/dev/null 2>&1; then
        local_api_available=true
    fi
    
    # Check Silicon availability
    if [ "$ENABLE_SILICON_PIPELINE" = true ] && [ -n "$SILICON_ACTIVE_ENDPOINT" ]; then
        silicon_available=true
    fi
    
    # Determine mode
    if [ "$local_api_available" = true ] && [ "$silicon_available" = true ]; then
        operation_mode="$GREEN[HYBRID: Silicon + Local]$RESET"
    elif [ "$silicon_available" = true ]; then
        operation_mode="$CYAN[SILICON ONLY: ${SILICON_ACTIVE_ENDPOINT##*/}]$RESET"
    elif [ "$local_api_available" = true ]; then
        operation_mode="$YELLOW[LOCAL ONLY]$RESET"
    else
        operation_mode="$RED[NO AI AVAILABLE]$RESET"
    fi
    
    echo -e "$DIM_PURPLE🧠 Mode: $operation_mode$DIM_PURPLE | 📚 Context: $CONTEXT_LENGTH pairs | 🤖 Model: $CURRENT_MODEL$RESET"
    
    local temp_percentage=$(echo "$CURRENT_TEMPERATURE * 100" | bc 2>/dev/null | cut -d. -f1)
    if [ -z "$temp_percentage" ]; then
        temp_percentage=70
    fi
    echo -e "$DIM_PURPLE🎭 Mood: ${temp_percentage}% creativity - Type 'mood' to adjust | 🧠 System: ${SESSION_SYSTEM_MESSAGE:-"(default)"}$RESET"
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
        echo -e "$YELLOW  💡 Install alsa-utils with your package manager$RESET"
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

# Function to run TTS diagnostics
tts_diagnostics() {
    echo -e "$DIM_PURPLE"
    echo "═══════════════════════════════════════════════════════════════"
    echo "                    TTS SYSTEM DIAGNOSTICS"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "$RESET"
    
    echo -e "$CYAN[1/4] Checking TTS engines...$RESET"
    
    # Check Piper
    local piper_exec
    piper_exec=$(find_piper_executable)
    if [ $? -eq 0 ]; then
        echo -e "$GREEN  ✓ Piper found: $piper_exec$RESET"
        
        # Check Piper version
        local piper_version
        piper_version=$("$piper_exec" --version 2>/dev/null || echo "unknown")
        echo -e "$GREEN    Version: $piper_version$RESET"
        
        # Check for voice models
        local voice_count=0
        local voice_paths=(
            "$VOICE_MODELS_DIR"
            "/usr/share/piper/voices"
            "/usr/local/share/piper/voices"
            "$HOME/.local/share/piper/voices"
            "$(dirname "$piper_exec")/../share/voices"
            "$VIRTUAL_ENV/share/piper/voices"
            "$CODEDECK_VENV_PATH/share/piper/voices"
        )
        
        for voice_dir in "${voice_paths[@]}"; do
            if [ -n "$voice_dir" ] && [ -d "$voice_dir" ]; then
                local voices=$(find "$voice_dir" -name "*.onnx" 2>/dev/null | wc -l)
                if [ "$voices" -gt 0 ]; then
                    voice_count=$((voice_count + voices))
                    echo -e "$GREEN    Found $voices voice(s) in $voice_dir$RESET"
                fi
            fi
        done
        
        # Also check for any .onnx files in common locations
        local additional_voices
        local search_paths=("$HOME/.local/share")
        [ -n "$VIRTUAL_ENV" ] && search_paths+=("$VIRTUAL_ENV")
        [ -n "$CODEDECK_VENV_PATH" ] && search_paths+=("$CODEDECK_VENV_PATH")
        
        additional_voices=$(find "${search_paths[@]}" -name "*.onnx" 2>/dev/null | wc -l)
        if [ "$additional_voices" -gt 0 ]; then
            voice_count=$((voice_count + additional_voices))
            echo -e "$GREEN    Found $additional_voices additional voice(s) in user/venv directories$RESET"
        fi
        
        if [ "$voice_count" -eq 0 ]; then
            echo -e "$YELLOW    ⚠ No voice models found - Piper may not work$RESET"
            echo -e "$DIM_PURPLE      Download voices from: https://github.com/rhasspy/piper/releases$RESET"
        else
            echo -e "$GREEN    Total voices available: $voice_count$RESET"
        fi
    else
        echo -e "$YELLOW  ⚠ Piper not found$RESET"
        echo -e "$DIM_PURPLE    Install with: pip install piper-tts$RESET"
        echo -e "$DIM_PURPLE    Or activate virtual environment containing Piper$RESET"
    fi
    
    # Check Festival
    if command -v festival >/dev/null 2>&1; then
        echo -e "$GREEN  ✓ Festival found: $(which festival)$RESET"
    else
        echo -e "$YELLOW  ⚠ Festival not found$RESET"
        echo -e "$DIM_PURPLE    Install Festival with your package manager$RESET"
    fi
    
    echo ""
    echo -e "$CYAN[2/4] Testing CodeDeck API TTS...$RESET"
    local api_status
    api_status=$(curl -s --connect-timeout 5 "$CODEDECK_API/v1/status" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$api_status" ]; then
        echo -e "$GREEN  ✓ CodeDeck API accessible$RESET"
        
        # Test TTS endpoint
        local tts_test
        tts_test=$(curl -s --connect-timeout 5 -I "$CODEDECK_API/v1/tts/speak" 2>/dev/null | head -1)
        
        if echo "$tts_test" | grep -q "200\|405\|400"; then
            echo -e "$GREEN  ✓ TTS endpoint accessible$RESET"
        else
            echo -e "$YELLOW  ⚠ TTS endpoint may not be available$RESET"
        fi
    else
        echo -e "$RED  ✗ CodeDeck API not accessible at $CODEDECK_API$RESET"
    fi
    
    echo ""
    echo -e "$CYAN[3/4] Testing TTS hierarchy...$RESET"
    
    # Test each TTS method with a simple message
    local test_message="TTS test"
    
    if find_piper_executable >/dev/null 2>&1; then
        echo -ne "$DIM_PURPLE  Testing Piper..."
        local temp_piper="/tmp/piper_test_$(date +%s).wav"
        if speak_with_piper "$test_message" "$temp_piper"; then
            echo -e " ✓$RESET"
            rm -f "$temp_piper"
        else
            echo -e " ✗$RESET"
        fi
    fi
    
    echo -ne "$DIM_PURPLE  Testing API..."
    local temp_api="/tmp/api_test_$(date +%s).wav"
    if curl -s -X POST "$CODEDECK_API/v1/tts/speak" \
        -H "Content-Type: application/json" \
        -d "{\"text\": \"$test_message\", \"voice\": \"glados\", \"audio_file\": true}" \
        -o "$temp_api" 2>/dev/null && [ -s "$temp_api" ]; then
        
        if ! head -c 1 "$temp_api" 2>/dev/null | grep -q "{"; then
            echo -e " ✓$RESET"
        else
            echo -e " ✗ (got JSON error)$RESET"
        fi
    else
        echo -e " ✗$RESET"
    fi
    rm -f "$temp_api"
    
    if command -v festival >/dev/null 2>&1; then
        echo -ne "$DIM_PURPLE  Testing Festival..."
        if echo "$test_message" | festival --tts >/dev/null 2>&1; then
            echo -e " ✓$RESET"
        else
            echo -e " ✗$RESET"
        fi
    fi
    
    echo ""
    echo -e "$CYAN[4/4] Current TTS priority order:$RESET"
    echo -e "$DIM_PURPLE  1. 🤖 Piper (local, high quality)$RESET"
    echo -e "$DIM_PURPLE  2. 🌐 CodeDeck API (GLaDOS voice)$RESET"
    echo -e "$DIM_PURPLE  3. 🎭 Festival (local fallback)$RESET"
    
    echo ""
    echo -e "$DIM_PURPLE═══════════════════════════════════════════════════════════════$RESET"
    echo -e "$GREEN✓ TTS DIAGNOSTICS COMPLETE$RESET"
    echo -e "$DIM_PURPLE═══════════════════════════════════════════════════════════════$RESET"
    
    # Show recommendation
    local tts_capability
    tts_capability=$(check_tts_capabilities)
    
    case "$tts_capability" in
        "piper")
            echo -e "$GREEN🤖 Recommended: Piper is available and preferred$RESET"
            ;;
        "festival")
            echo -e "$YELLOW🎭 Fallback: Only Festival available locally$RESET"
            echo -e "$DIM_PURPLE💡 Consider installing Piper for better quality$RESET"
            ;;
        "none")
            echo -e "$RED❌ No local TTS available$RESET"
            echo -e "$YELLOW💡 Install Festival with your package manager$RESET"
            ;;
    esac
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
    
    debug_log "Using recording device: $recording_device"
    
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
            cleanup_streaming_speech
            stop_silicon_monitor
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
        "stream-speech")
            toggle_streaming_speech
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
        "mood")
            if [ "$args" != "$command" ]; then
                set_mood "$args"
            else
                set_mood ""
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
        "debug")
            toggle_debug
            ;;
        "hush")
            hush
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
        "tts-diag")
            tts_diagnostics
            ;;
        "voice")
            if [ "$args" != "$command" ]; then
                # Parse voice subcommand
                voice_action=$(echo "$args" | awk '{print $1}')
                voice_name=$(echo "$args" | cut -d' ' -f2-)
                if [ "$voice_name" = "$voice_action" ]; then
                    voice_name=""
                fi
                
                case "$voice_action" in
                    "list")
                        list_voice_models
                        ;;
                    "set")
                        if [ -n "$voice_name" ]; then
                            set_voice_model "$voice_name"
                        else
                            echo -e "$YELLOW[!] Usage: voice set <voice_name>$RESET"
                        fi
                        ;;
                    "current")
                        echo -e "$BRIGHT_CYAN🎙️ Current voice: $CURRENT_VOICE$RESET"
                        local current_path
                        current_path=$(get_current_voice_model)
                        if [ $? -eq 0 ]; then
                            echo -e "$DIM_PURPLE    Location: $current_path$RESET"
                        else
                            echo -e "$YELLOW⚠ Voice model not found in any location!$RESET"
                        fi
                        ;;
                    *)
                        echo -e "$YELLOW[!] Usage: voice [list|set <name>|current]$RESET"
                        ;;
                esac
            else
                list_voice_models
            fi
            ;;
        "battery-debug")
            debug_18650_detection
            ;;
        "silicon")
            if [ "$args" != "$command" ]; then
                # Parse silicon subcommand
                silicon_action=$(echo "$args" | awk '{print $1}')
                case "$silicon_action" in
                    "status")
                        show_silicon_status
                        ;;
                    "toggle")
                        toggle_silicon_pipeline
                        ;;
                    "endpoints")
                        select_silicon_endpoint
                        ;;
                    *)
                        echo -e "$YELLOW[!] Usage: silicon [status|toggle|endpoints]$RESET"
                        ;;
                esac
            else
                show_silicon_status
            fi
            ;;
        *)
            # Chat with current AI persona (user message display now handled in function)
            chat_with_codedeck "$user_input"
            echo ""
            ;;
    esac
done 

# Function to play sound effects in background
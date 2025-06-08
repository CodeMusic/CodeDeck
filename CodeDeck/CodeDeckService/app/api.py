"""
API Routes - OpenAI-compatible endpoints for LLM inference
"""

from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from typing import List, Dict, Any, Optional, Union, AsyncGenerator
import json
import logging
from datetime import datetime
import asyncio
from .persona import get_persona_manager, Persona
import uuid
import re
import tempfile
import subprocess
import os
import time
import hashlib
from pathlib import Path

logger = logging.getLogger("api_router")


class ChatMessage(BaseModel):
    """Individual chat message"""
    role: str = Field(..., description="Message role: system, user, or assistant")
    content: str = Field(..., description="Message content")


class ChatRequest(BaseModel):
    """OpenAI-compatible chat completion request"""
    model: str = Field(..., description="Model identifier")
    messages: List[ChatMessage] = Field(..., description="List of messages")
    max_tokens: Optional[int] = Field(512, description="Maximum tokens to generate")
    temperature: Optional[float] = Field(0.7, description="Sampling temperature")
    stream: Optional[bool] = Field(False, description="Enable streaming response")
    direct_mode: Optional[bool] = Field(False, description="Enable direct mode for local connections")


class ModelInfo(BaseModel):
    """Model information"""
    id: str
    name: str
    description: str
    tags: List[str]
    loaded: bool


# Custom streaming response with no-buffering guarantees
class UnbufferedStreamingResponse(StreamingResponse):
    """StreamingResponse with explicit no-buffering guarantees"""
    
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Ensure headers are set to prevent any buffering
        self.headers.update({
            "Cache-Control": "no-cache, no-transform",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
            "Transfer-Encoding": "chunked",
            "Content-Type": "text/event-stream"
        })


# Additional Persona-related request models
class PersonaRequest(BaseModel):
    """Request for creating or updating a persona"""
    id: Optional[str] = Field(None, description="Persona ID (generated if not provided)")
    name: str = Field(..., description="Display name for the persona")
    model: str = Field(..., description="Model identifier to use with this persona")
    system_message: str = Field(..., description="System message that defines the persona's behavior")
    description: str = Field(..., description="Brief description of the persona")
    voice: Optional[str] = Field(None, description="Voice identifier for TTS")
    temperature: Optional[float] = Field(0.7, description="Default temperature")
    max_tokens: Optional[int] = Field(512, description="Default max tokens")
    top_p: Optional[float] = Field(0.9, description="Default top_p value")
    tags: Optional[List[str]] = Field(None, description="Tags for categorizing personas")
    icon: Optional[str] = Field("🤖", description="Emoji or icon identifier")

class GenerateSystemMessageRequest(BaseModel):
    """Request to generate a system message from a description"""
    description: str = Field(..., description="Brief description of the desired persona")
    api_key: Optional[str] = Field(None, description="Optional OpenAI API key for this request only")


def create_api_router() -> APIRouter:
    """Create and configure the API router"""
    
    router = APIRouter()
    
    @router.post("/v1/chat/completions")
    async def chat_completions(request: ChatRequest, http_request: Request):
        """
        OpenAI-compatible chat completions endpoint with persona support
        """
        try:
            # Get the model engine from the main app
            model_engine = http_request.app.state.__dict__.get('model_engine')
            if not model_engine:
                # Access through the global variable from main module
                from . import main
                model_engine = main.model_engine
            
            if not model_engine or not model_engine.is_ready:
                raise HTTPException(
                    status_code=503, 
                    detail="Model engine not ready"
                )
            
            # Check for persona_id in request headers
            persona_id = http_request.headers.get("X-Persona-ID")
            
            # If persona_id is provided, get the persona and use its settings
            if persona_id:
                persona_manager = get_persona_manager()
                persona = await persona_manager.get_persona(persona_id)
                
                if persona:
                    # Override request settings with persona settings if available
                    if not request.model or request.model == "":
                        request.model = persona.model
                    
                    # Apply temperature from persona if not explicitly set
                    if request.temperature is None:
                        request.temperature = persona.temperature
                    
                    # Apply max_tokens from persona if not explicitly set
                    if request.max_tokens is None:
                        request.max_tokens = persona.max_tokens
                    
                    # Prepend system message if first message is not already a system message
                    if persona.system_message and len(request.messages) > 0:
                        if request.messages[0].role != "system":
                            request.messages.insert(0, ChatMessage(
                                role="system", 
                                content=persona.system_message
                            ))
                        # If there's already a system message but it's empty, replace it
                        elif not request.messages[0].content:
                            request.messages[0].content = persona.system_message
            
            # Check if requested model is available
            if request.model != model_engine.current_model_name:
                # Try to load the requested model
                success = await model_engine.load_model(request.model)
                if not success:
                    raise HTTPException(
                        status_code=400, 
                        detail=f"Model '{request.model}' not available"
                    )
            
            # Convert messages to the format expected by the engine
            messages = [
                {"role": msg.role, "content": msg.content} 
                for msg in request.messages
            ]
            
            if request.stream:
                # Check for direct mode in either the request body or headers
                direct_mode = request.direct_mode or http_request.headers.get("X-Direct-Mode") == "true"
                
                # Use unbuffered streaming response
                response = UnbufferedStreamingResponse(
                    stream_chat_response(
                        model_engine, 
                        messages, 
                        request.max_tokens, 
                        direct_mode,
                        request.temperature
                    )
                )
                return response
            else:
                response = await model_engine.generate_response(
                    messages=messages,
                    max_tokens=request.max_tokens,
                    temperature=request.temperature,
                    stream=False
                )
                return response
        
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error in chat completions: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    @router.get("/v1/models")
    async def list_models(http_request: Request):
        """
        List available models (OpenAI-compatible)
        """
        try:
            # Get the model engine
            from . import main
            model_engine = main.model_engine
            
            if not model_engine:
                raise HTTPException(
                    status_code=503, 
                    detail="Model engine not initialized"
                )
            
            models = await model_engine.get_available_models()
            
            # Format for OpenAI compatibility
            formatted_models = [
                {
                    "id": model["id"],
                    "object": "model",
                    "created": int(datetime.now().timestamp()),
                    "owned_by": "codedeck",
                    "permission": [],
                    "root": model["id"],
                    "parent": None,
                    "description": model["description"],
                    "tags": model["tags"],
                    "loaded": model["loaded"]
                }
                for model in models
            ]
            
            return {
                "object": "list",
                "data": formatted_models
            }
        
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error listing models: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    @router.post("/v1/models/{model_name}/load")
    async def load_model(model_name: str, http_request: Request):
        """
        Load a specific model
        """
        try:
            from . import main
            model_engine = main.model_engine
            
            if not model_engine:
                raise HTTPException(
                    status_code=503, 
                    detail="Model engine not initialized"
                )
            
            success = await model_engine.load_model(model_name)
            
            if success:
                return {
                    "status": "success",
                    "message": f"Model '{model_name}' loaded successfully",
                    "current_model": model_name
                }
            else:
                raise HTTPException(
                    status_code=400,
                    detail=f"Failed to load model '{model_name}'"
                )
        
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error loading model: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    @router.get("/v1/status")
    async def get_status(http_request: Request):
        """
        Get detailed system status
        """
        try:
            from . import main
            model_engine = main.model_engine
            
            if not model_engine:
                return {
                    "status": "initializing",
                    "model_engine": "not ready",
                    "current_model": None
                }
            
            health_status = await model_engine.get_health_status()
            
            return {
                "status": "ready" if model_engine.is_ready else "initializing",
                "model_engine": "ready" if model_engine.is_ready else "not ready",
                "current_model": model_engine.current_model_name,
                "health": health_status,
                "timestamp": datetime.now().isoformat()
            }
        
        except Exception as e:
            logger.error(f"Error getting status: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    @router.get("/v1/system/metrics")
    async def get_system_metrics():
        """
        Get system performance metrics including CPU temperature
        """
        try:
            import psutil
            import subprocess
            import os
            
            metrics = {
                "cpu": {
                    "usage_percent": psutil.cpu_percent(interval=1),
                    "count": psutil.cpu_count(),
                    "frequency": psutil.cpu_freq()._asdict() if psutil.cpu_freq() else None
                },
                "memory": {
                    "total": psutil.virtual_memory().total,
                    "available": psutil.virtual_memory().available,
                    "percent": psutil.virtual_memory().percent
                },
                "temperature": {}
            }
            
            # Try to get CPU temperature (different methods for different systems)
            try:
                # Method 1: psutil sensors (Linux)
                if hasattr(psutil, 'sensors_temperatures'):
                    temps = psutil.sensors_temperatures()
                    if temps:
                        for chip, sensors in temps.items():
                            for sensor in sensors:
                                if 'cpu' in sensor.label.lower() or 'core' in sensor.label.lower():
                                    metrics["temperature"]["cpu_celsius"] = sensor.current
                                    break
                            if "cpu_celsius" in metrics["temperature"]:
                                break
            except:
                pass
            
            # Method 2: vcgencmd for Raspberry Pi
            try:
                if os.path.exists('/usr/bin/vcgencmd'):
                    result = subprocess.run(['vcgencmd', 'measure_temp'], capture_output=True, text=True)
                    if result.returncode == 0:
                        temp_str = result.stdout.strip()
                        if 'temp=' in temp_str:
                            temp_value = float(temp_str.split('=')[1].replace("'C", ""))
                            metrics["temperature"]["cpu_celsius"] = temp_value
            except:
                pass
            
            # Method 3: thermal zone files (Linux)
            try:
                for i in range(10):  # Check first 10 thermal zones
                    thermal_file = f'/sys/class/thermal/thermal_zone{i}/temp'
                    if os.path.exists(thermal_file):
                        with open(thermal_file, 'r') as f:
                            temp_millidegrees = int(f.read().strip())
                            temp_celsius = temp_millidegrees / 1000.0
                            if 30 < temp_celsius < 120:  # Reasonable CPU temp range
                                metrics["temperature"]["cpu_celsius"] = temp_celsius
                                break
            except:
                pass
            
            return metrics
        
        except Exception as e:
            logger.error(f"Error getting system metrics: {e}")
            return {"error": str(e)}
    
    @router.get("/v1/personas")
    async def list_personas():
        """List all available personas"""
        try:
            persona_manager = get_persona_manager()
            personas = await persona_manager.list_personas()
            return {"data": personas}
        except Exception as e:
            logger.error(f"Error listing personas: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    @router.get("/v1/personas/{persona_id}")
    async def get_persona(persona_id: str):
        """Get a specific persona by ID"""
        try:
            persona_manager = get_persona_manager()
            persona = await persona_manager.get_persona(persona_id)
            
            if not persona:
                raise HTTPException(status_code=404, detail=f"Persona '{persona_id}' not found")
            
            return persona.to_dict()
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error getting persona: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    @router.post("/v1/personas")
    async def create_persona(request: PersonaRequest):
        """Create a new persona"""
        try:
            persona_manager = get_persona_manager()
            
            # Create persona object
            persona = Persona(
                id=request.id or str(uuid.uuid4()),
                name=request.name,
                model=request.model,
                system_message=request.system_message,
                description=request.description,
                voice=request.voice,
                temperature=request.temperature,
                max_tokens=request.max_tokens,
                top_p=request.top_p,
                tags=request.tags or ["custom"],
                icon=request.icon
            )
            
            # Save the persona
            success = await persona_manager.save_persona(persona)
            
            if not success:
                raise HTTPException(status_code=400, detail="Failed to save persona")
            
            return persona.to_dict()
        except Exception as e:
            logger.error(f"Error creating persona: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    @router.put("/v1/personas/{persona_id}")
    async def update_persona(persona_id: str, request: PersonaRequest):
        """Update an existing persona"""
        try:
            persona_manager = get_persona_manager()
            
            # Check if persona exists
            existing_persona = await persona_manager.get_persona(persona_id)
            if not existing_persona:
                raise HTTPException(status_code=404, detail=f"Persona '{persona_id}' not found")
            
            # Create updated persona object
            persona = Persona(
                id=persona_id,
                name=request.name,
                model=request.model,
                system_message=request.system_message,
                description=request.description,
                voice=request.voice,
                temperature=request.temperature,
                max_tokens=request.max_tokens,
                top_p=request.top_p,
                tags=request.tags or existing_persona.tags,
                icon=request.icon
            )
            
            # Save the persona
            success = await persona_manager.save_persona(persona)
            
            if not success:
                raise HTTPException(status_code=400, detail="Failed to update persona")
            
            return persona.to_dict()
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error updating persona: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    @router.delete("/v1/personas/{persona_id}")
    async def delete_persona(persona_id: str):
        """Delete a persona"""
        try:
            persona_manager = get_persona_manager()
            
            # Delete the persona
            success = await persona_manager.delete_persona(persona_id)
            
            if not success:
                raise HTTPException(status_code=404, detail=f"Persona '{persona_id}' not found")
            
            return {"status": "success", "message": f"Persona '{persona_id}' deleted"}
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error deleting persona: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    @router.post("/v1/personas/generate_system_message")
    async def generate_system_message(request: GenerateSystemMessageRequest):
        """Generate a system message from a description using OpenAI"""
        try:
            persona_manager = get_persona_manager()
            
            # If API key provided in request, use it temporarily
            if request.api_key:
                original_api_key = persona_manager.openai_api_key
                persona_manager.set_openai_api_key(request.api_key)
            
            # Generate system message
            system_message = await persona_manager.generate_system_message(
                request.description
            )
            
            # Restore original API key if we changed it
            if request.api_key:
                persona_manager.set_openai_api_key(original_api_key)
            
            if not system_message:
                raise HTTPException(
                    status_code=400, 
                    detail="Failed to generate system message. Check if OpenAI API key is configured."
                )
            
            return {
                "system_message": system_message,
                "description": request.description
            }
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error generating system message: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    @router.post("/v1/personas/set_api_key")
    async def set_openai_api_key(request: dict):
        """Set OpenAI API key for system message generation"""
        try:
            api_key = request.get("api_key")
            if not api_key:
                raise HTTPException(status_code=400, detail="API key not provided")
            
            persona_manager = get_persona_manager()
            persona_manager.set_openai_api_key(api_key)
            
            return {"status": "success", "message": "OpenAI API key set successfully"}
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error setting OpenAI API key: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    # Text-to-Speech Endpoints
    
    @router.post("/v1/tts/speak")
    async def speak_text(request: dict):
        """Send text to piper TTS engine and play through aplay"""
        try:
            text = request.get("text")
            voice = request.get("voice", "en_US-GlaDOS-medium")
            
            if not text:
                raise HTTPException(status_code=400, detail="Text not provided")
            
            # Clean up text for TTS processing
            text = text.strip()
            
            # Replace any markdown or special formatting with spaces
            text = re.sub(r'```.*?```', ' ', text, flags=re.DOTALL)  # Remove code blocks
            text = re.sub(r'<.*?>', ' ', text)  # Remove HTML/XML tags
            text = re.sub(r'\*\*|\*|__|\|', ' ', text)  # Remove markdown formatting
            
            # Map voice names to models (following the reference script pattern)
            voice_map = {
                "en_US-GlaDOS-medium": ("glados", "en_US-GlaDOS-medium"),
                "glados": ("glados", "en_US-GlaDOS-medium"),
                "en_GB-jarvis-medium": ("jarvis", "en_GB-jarvis-medium"),
                "jarvis": ("jarvis", "en_GB-jarvis-medium")
            }
            
            voice_name, model_name = voice_map.get(voice.lower(), (voice, voice))
            
            # Set paths matching the reference script
            home_dir = os.path.expanduser("~")
            model_dir = os.path.join(home_dir, "CodeDeck", "voice_models")
            piper_bin = os.path.join(home_dir, "CodeDeck", "piper", "build", "piper")
            
            model_path = os.path.join(model_dir, f"{model_name}.onnx")
            config_path = os.path.join(model_dir, f"{model_name}.onnx.json")
            
            # Check if files exist
            if not os.path.exists(piper_bin):
                raise HTTPException(status_code=500, detail=f"Piper binary not found at {piper_bin}")
            if not os.path.exists(model_path):
                raise HTTPException(status_code=500, detail=f"Voice model not found at {model_path}")
            if not os.path.exists(config_path):
                raise HTTPException(status_code=500, detail=f"Voice config not found at {config_path}")
            
            try:
                # Create temp file for audio
                with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as temp_file:
                    temp_file_path = temp_file.name
                
                # Create temp file for text input
                with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as text_file:
                    text_file_path = text_file.name
                    text_file.write(text)
                
                # Build the piper command (following reference script exactly)
                piper_cmd = [
                    piper_bin,
                    "--model", model_path,
                    "--config", config_path,
                    "--output_file", temp_file_path
                ]
                
                # Run piper with text input
                with open(text_file_path, 'r') as text_input:
                    process = subprocess.run(
                        piper_cmd,
                        stdin=text_input,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        check=True
                    )
                
                # Play the audio file
                aplay_cmd = ["aplay", temp_file_path]
                subprocess.Popen(
                    aplay_cmd,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                
                # Schedule cleanup
                asyncio.create_task(cleanup_temp_files([temp_file_path, text_file_path]))
                
                return {"status": "success", "message": "TTS processing started", "voice": voice_name}
                
            except subprocess.CalledProcessError as e:
                logger.error(f"Error processing TTS with piper: {e.stderr.decode() if e.stderr else str(e)}")
                raise HTTPException(status_code=500, detail=f"TTS processing error: {str(e)}")
        
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error in speak_text: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    @router.post("/v1/tts/generate")
    async def generate_audio_file(request: dict):
        """Generate audio file from text using piper TTS engine"""
        try:
            text = request.get("text")
            voice = request.get("voice", "en_US-GlaDOS-medium")
            
            if not text:
                raise HTTPException(status_code=400, detail="Text not provided")
            
            # Clean up text for TTS processing
            text = text.strip()
            
            # Replace any markdown or special formatting with spaces
            text = re.sub(r'```[\s\S]*?```', ' ', text, flags=re.DOTALL)  # Remove code blocks
            text = re.sub(r'<[^>]*>', ' ', text)  # Remove HTML/XML tags
            text = re.sub(r'\*\*|\*|__|\|', ' ', text)  # Remove markdown formatting
            
            # Map voice names to models (following the reference script pattern)
            voice_map = {
                "en_US-GlaDOS-medium": ("glados", "en_US-GlaDOS-medium"),
                "glados": ("glados", "en_US-GlaDOS-medium"),
                "en_GB-jarvis-medium": ("jarvis", "en_GB-jarvis-medium"),
                "jarvis": ("jarvis", "en_GB-jarvis-medium")
            }
            
            voice_name, model_name = voice_map.get(voice.lower(), (voice, voice))
            
            # Set paths matching the reference script
            home_dir = os.path.expanduser("~")
            model_dir = os.path.join(home_dir, "CodeDeck", "voice_models")
            piper_bin = os.path.join(home_dir, "CodeDeck", "piper", "build", "piper")
            
            model_path = os.path.join(model_dir, f"{model_name}.onnx")
            config_path = os.path.join(model_dir, f"{model_name}.onnx.json")
            
            # Check if files exist
            if not os.path.exists(piper_bin):
                raise HTTPException(status_code=500, detail=f"Piper binary not found at {piper_bin}")
            if not os.path.exists(model_path):
                raise HTTPException(status_code=500, detail=f"Voice model not found at {model_path}")
            if not os.path.exists(config_path):
                raise HTTPException(status_code=500, detail=f"Voice config not found at {config_path}")
            
            # Create output directory if it doesn't exist
            output_dir = Path("app/static/audio")
            output_dir.mkdir(parents=True, exist_ok=True)
            
            # Generate unique filename based on timestamp and hash of text
            timestamp = int(time.time())
            text_hash = hashlib.md5(text.encode()).hexdigest()[:8]
            output_filename = f"{timestamp}_{text_hash}_{voice_name}.wav"
            output_path = output_dir / output_filename
            
            # Create temp file for text input
            with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as text_file:
                text_file_path = text_file.name
                text_file.write(text)
            
            # Build and run the piper command (following reference script)
            try:
                piper_cmd = [
                    piper_bin,
                    "--model", model_path,
                    "--config", config_path,
                    "--output_file", str(output_path)
                ]
                
                # Run piper with text input
                with open(text_file_path, 'r') as text_input:
                    process = subprocess.run(
                        piper_cmd,
                        stdin=text_input,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        check=True
                    )
                
                # Clean up temp text file
                try:
                    os.unlink(text_file_path)
                except:
                    pass
                
                # Return the path to the audio file relative to static dir
                return {
                    "status": "success", 
                    "audio_path": f"/static/audio/{output_filename}",
                    "voice": voice_name
                }
                
            except subprocess.CalledProcessError as e:
                logger.error(f"Error generating audio file: {e.stderr.decode() if e.stderr else str(e)}")
                raise HTTPException(status_code=500, detail="Failed to generate audio file")
                
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error in generate_audio_file: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    async def cleanup_temp_file(file_path: str, delay: int = 60):
        """Clean up temporary file after a delay"""
        await asyncio.sleep(delay)
        try:
            os.unlink(file_path)
        except:
            pass
    
    async def cleanup_temp_files(file_paths: list, delay: int = 60):
        """Clean up multiple temporary files after a delay"""
        await asyncio.sleep(delay)
        for file_path in file_paths:
            try:
                os.unlink(file_path)
            except:
                pass
    
    @router.get("/v1/tts/voices")
    async def list_available_voices():
        """List available TTS voices"""
        try:
            # Check for available voice models
            home_dir = os.path.expanduser("~")
            model_dir = os.path.join(home_dir, "CodeDeck", "voice_models")
            
            available_voices = []
            
            if os.path.exists(model_dir):
                # Scan directory for .onnx files
                for filename in os.listdir(model_dir):
                    # Skip hidden files, system files, and directory artifacts
                    if filename.startswith('.') or filename.startswith('_'):
                        continue
                        
                    if filename.endswith('.onnx'):
                        # Remove .onnx extension to get voice name
                        voice_name = filename[:-5]  # Remove .onnx
                        
                        # Skip if voice name still starts with dots/underscores after processing
                        if voice_name.startswith('.') or voice_name.startswith('_'):
                            continue
                        
                        # Check if corresponding .json config file exists
                        config_file = os.path.join(model_dir, f"{voice_name}.onnx.json")
                        if os.path.exists(config_file):
                            available_voices.append(voice_name)
            
            # Sort voices for consistent ordering
            available_voices.sort()
            
            # If no voices found, return defaults
            if not available_voices:
                available_voices = ["glados", "jarvis"]
            
            return {
                "voices": available_voices,
                "default": available_voices[0] if available_voices else "glados"
            }
        except Exception as e:
            logger.error(f"Error listing voices: {e}")
            # Return default voices as fallback
            return {
                "voices": ["glados", "jarvis"],
                "default": "glados"
            }
    
    return router


async def stream_chat_response(
    model_engine, 
    messages: List[Dict[str, str]], 
    max_tokens: int, 
    direct_mode: bool = False,
    temperature: float = 0.7
) -> AsyncGenerator[str, None]:
    """
    Generate streaming chat response with immediate token delivery
    """
    try:
        # Send immediate start signal to prevent buffering
        initial_chunk = {
            "choices": [{
                "delta": {"content": ""},
                "finish_reason": None
            }],
            "model": model_engine.current_model_name
        }
        yield f"data: {json.dumps(initial_chunk)}\n\n"
        
        # Small delay to ensure headers are sent before content
        await asyncio.sleep(0.01)
        
        # Padding to force flush (some proxies buffer until threshold)
        padding = " " * 2048
        yield f"data: {json.dumps({'padding': True})}\n{padding}\n\n"
        
        # Get the streaming generator from the model engine
        prompt = model_engine._format_messages(messages)
        stream_generator = model_engine._generate_streaming_response(
            prompt,
            max_tokens,
            temperature
        )
        
        # Use direct mode or chunked mode based on the request
        if direct_mode:
            logger.info("Using direct mode for local inference")
            # In direct mode, we wait for complete batches but still stream them
            # This is faster for local connections
            for chunk in stream_generator:
                chunk_data = json.dumps(chunk)
                yield f"data: {chunk_data}\n\n"
                # Small delay between chunks to ensure flushing
                await asyncio.sleep(0.01)
        else:
            # In normal mode, we split the stream into individual tokens
            # and force delivery after each token
            for chunk in stream_generator:
                chunk_data = json.dumps(chunk)
                yield f"data: {chunk_data}\n\n"
                # Force immediate flush with a tiny delay
                await asyncio.sleep(0.01)
        
        # Send completion marker
        yield "data: [DONE]\n\n"
    
    except Exception as e:
        logger.error(f"Error in streaming response: {e}")
        error_chunk = {
            "error": {
                "message": str(e),
                "type": "internal_error"
            }
        }
        yield f"data: {json.dumps(error_chunk)}\n\n" 
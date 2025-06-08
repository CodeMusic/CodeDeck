"""
API Routes - OpenAI-compatible endpoints for LLM inference
"""

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from typing import List, Dict, Any, Optional, Union
import json
import logging
from datetime import datetime
import asyncio

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


class ModelInfo(BaseModel):
    """Model information"""
    id: str
    name: str
    description: str
    tags: List[str]
    loaded: bool


def create_api_router() -> APIRouter:
    """Create and configure the API router"""
    
    router = APIRouter()
    
    @router.post("/v1/chat/completions")
    async def chat_completions(request: ChatRequest, http_request: Request):
        """
        OpenAI-compatible chat completions endpoint
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
                return StreamingResponse(
                    stream_chat_response(
                        model_engine, 
                        messages, 
                        request.max_tokens, 
                        request.temperature
                    ),
                    media_type="text/plain"
                )
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
    
    return router


async def stream_chat_response(
    model_engine, 
    messages: List[Dict[str, str]], 
    max_tokens: int, 
    temperature: float
):
    """
    Generate streaming chat response
    """
    try:
        # Get the streaming generator
        stream_generator = model_engine._generate_streaming_response(
            model_engine._format_messages(messages),
            max_tokens,
            temperature
        )
        
        for chunk in stream_generator:
            # Format as Server-Sent Events
            chunk_data = json.dumps(chunk)
            yield f"data: {chunk_data}\n\n"
        
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
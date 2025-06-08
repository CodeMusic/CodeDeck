"""
Model Engine - Handles LLM model loading and inference
"""

import json
import os
import logging
from typing import Dict, List, Optional, Any
from pathlib import Path
import asyncio
from dataclasses import dataclass

try:
    from llama_cpp import Llama
except ImportError:
    Llama = None

logger = logging.getLogger("model_engine")


@dataclass
class ModelConfig:
    """Configuration for a single model"""
    name: str
    file: str
    description: str
    tags: List[str]
    
    @classmethod
    def from_dict(cls, data: Dict) -> 'ModelConfig':
        return cls(
            name=data['name'],
            file=data['file'],
            description=data['description'],
            tags=data.get('tags', [])
        )


class ModelEngine:
    """
    Manages LLM model loading and inference operations
    """
    
    def __init__(self, models_manifest_path: str):
        self.models_manifest_path = models_manifest_path
        self.models_dir = Path(models_manifest_path).parent
        self.available_models: Dict[str, ModelConfig] = {}
        self.current_model: Optional[Llama] = None
        self.current_model_name: Optional[str] = None
        self.is_ready = False
        
    async def initialize(self):
        """Initialize the model engine"""
        try:
            await self._load_models_manifest()
            # Load the first available model by default
            if self.available_models:
                first_model = next(iter(self.available_models.keys()))
                await self.load_model(first_model)
            self.is_ready = True
            logger.info("Model engine initialized successfully")
        except Exception as e:
            logger.error(f"Failed to initialize model engine: {e}")
            raise
    
    async def _load_models_manifest(self):
        """Load the models manifest file"""
        try:
            with open(self.models_manifest_path, 'r') as f:
                models_data = json.load(f)
            
            for model_data in models_data:
                config = ModelConfig.from_dict(model_data)
                self.available_models[config.name] = config
                
            logger.info(f"Loaded {len(self.available_models)} model configurations")
        except Exception as e:
            logger.error(f"Failed to load models manifest: {e}")
            raise
    
    async def load_model(self, model_name: str) -> bool:
        """Load a specific model"""
        if model_name not in self.available_models:
            logger.error(f"Model '{model_name}' not found in available models")
            return False
        
        if Llama is None:
            logger.error("llama-cpp-python not installed")
            return False
        
        try:
            # Unload current model if any
            if self.current_model:
                del self.current_model
                self.current_model = None
            
            model_config = self.available_models[model_name]
            model_path = self.models_dir / model_config.file
            
            if not model_path.exists():
                logger.error(f"Model file not found: {model_path}")
                return False
            
            logger.info(f"Loading model: {model_name}")
            
            # Load the model with optimized settings for Pi 5
            self.current_model = Llama(
                model_path=str(model_path),
                n_ctx=2048,  # Context window
                n_threads=4,  # Pi 5 has 4 cores
                n_gpu_layers=0,  # CPU only for now
                verbose=False
            )
            
            self.current_model_name = model_name
            logger.info(f"Successfully loaded model: {model_name}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to load model '{model_name}': {e}")
            return False
    
    async def generate_response(
        self, 
        messages: List[Dict[str, str]], 
        max_tokens: int = 512,
        temperature: float = 0.7,
        stream: bool = False
    ) -> Dict[str, Any]:
        """Generate a response using the current model"""
        if not self.current_model:
            raise ValueError("No model loaded")
        
        try:
            # Convert messages to prompt format
            prompt = self._format_messages(messages)
            
            if stream:
                return self._generate_streaming_response(prompt, max_tokens, temperature)
            else:
                return self._generate_complete_response(prompt, max_tokens, temperature)
        
        except Exception as e:
            logger.error(f"Error generating response: {e}")
            raise
    
    def _format_messages(self, messages: List[Dict[str, str]]) -> str:
        """Convert OpenAI-style messages to a single prompt"""
        formatted_parts = []
        
        for message in messages:
            role = message.get('role', 'user')
            content = message.get('content', '')
            
            if role == 'system':
                formatted_parts.append(f"System: {content}")
            elif role == 'user':
                formatted_parts.append(f"Human: {content}")
            elif role == 'assistant':
                formatted_parts.append(f"Assistant: {content}")
        
        formatted_parts.append("Assistant:")
        return "\n\n".join(formatted_parts)
    
    def _generate_complete_response(
        self, 
        prompt: str, 
        max_tokens: int, 
        temperature: float
    ) -> Dict[str, Any]:
        """Generate a complete response (non-streaming)"""
        response = self.current_model(
            prompt,
            max_tokens=max_tokens,
            temperature=temperature,
            stop=["Human:", "System:"],
            echo=False
        )
        
        return {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": response['choices'][0]['text'].strip()
                },
                "finish_reason": "stop"
            }],
            "model": self.current_model_name,
            "usage": {
                "prompt_tokens": response.get('usage', {}).get('prompt_tokens', 0),
                "completion_tokens": response.get('usage', {}).get('completion_tokens', 0),
                "total_tokens": response.get('usage', {}).get('total_tokens', 0)
            }
        }
    
    def _generate_streaming_response(
        self, 
        prompt: str, 
        max_tokens: int, 
        temperature: float
    ):
        """Generate a streaming response"""
        import time
        
        # Force individual token streaming with specific parameters
        stream = self.current_model(
            prompt,
            max_tokens=max_tokens,
            temperature=temperature,
            stop=["Human:", "System:"],
            echo=False,
            stream=True,
            # Force immediate token generation
            top_k=1,  # More predictable for testing
            repeat_penalty=1.0,
        )
        
        for chunk in stream:
            # Force immediate yield of each token
            token_text = chunk['choices'][0]['text']
            if token_text:  # Only yield non-empty tokens
                yield {
                    "choices": [{
                        "delta": {
                            "content": token_text
                        },
                        "finish_reason": None
                    }],
                    "model": self.current_model_name
                }
                # Small delay to make streaming more visible during testing
                time.sleep(0.01)  # 10ms delay per token
    
    async def get_available_models(self) -> List[Dict[str, Any]]:
        """Get list of available models"""
        return [
            {
                "id": name,
                "name": config.name,
                "description": config.description,
                "tags": config.tags,
                "loaded": name == self.current_model_name
            }
            for name, config in self.available_models.items()
        ]
    
    async def get_health_status(self) -> Dict[str, Any]:
        """Get engine health status"""
        return {
            "model_loaded": self.current_model is not None,
            "current_model": self.current_model_name,
            "available_models": len(self.available_models),
            "ready": self.is_ready
        }
    
    async def shutdown(self):
        """Cleanup resources"""
        if self.current_model:
            del self.current_model
            self.current_model = None
        self.is_ready = False
        logger.info("Model engine shutdown complete") 
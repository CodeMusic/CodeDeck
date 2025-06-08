"""
Direct LLM Bridge - High-performance local inference without HTTP overhead
"""

import asyncio
import json
import logging
import os
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from typing import Dict, List, Optional, Any
import uvicorn
from pathlib import Path

try:
    from llama_cpp import Llama
except ImportError:
    Llama = None

logger = logging.getLogger("direct_bridge")


class DirectLLMBridge:
    """
    Direct bridge to llama-cpp for local inference without HTTP overhead
    """
    def __init__(self, models_dir: Path):
        self.models_dir = models_dir
        self.model = None
        self.model_name = None
        self.is_ready = False
        self.clients = []
        
    async def load_model(self, model_file: str) -> bool:
        """Load a model directly"""
        if Llama is None:
            logger.error("llama-cpp-python not installed")
            return False
        
        try:
            # Unload current model if any
            if self.model:
                del self.model
                self.model = None
                self.model_name = None
                self.is_ready = False
            
            model_path = self.models_dir / model_file
            
            if not model_path.exists():
                logger.error(f"Model file not found: {model_path}")
                return False
            
            logger.info(f"Loading model: {model_file}")
            
            # Load the model with optimized settings
            self.model = Llama(
                model_path=str(model_path),
                n_ctx=2048,
                n_threads=4,
                n_gpu_layers=0,
                verbose=False
            )
            
            self.model_name = model_file
            self.is_ready = True
            logger.info(f"Successfully loaded model: {model_file}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to load model: {e}")
            return False
    
    def format_messages(self, messages: List[Dict[str, str]]) -> str:
        """Format messages into a prompt"""
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
    
    async def register_client(self, websocket: WebSocket):
        """Register a new client connection"""
        await websocket.accept()
        self.clients.append(websocket)
        
    async def unregister_client(self, websocket: WebSocket):
        """Unregister a client connection"""
        self.clients.remove(websocket)
    
    async def handle_client(self, websocket: WebSocket):
        """Handle a client connection"""
        await self.register_client(websocket)
        
        try:
            while True:
                data = await websocket.receive_text()
                request = json.loads(data)
                
                command = request.get('command')
                
                if command == 'load_model':
                    model_file = request.get('model_file')
                    success = await self.load_model(model_file)
                    await websocket.send_json({
                        'event': 'model_loaded',
                        'success': success,
                        'model': model_file if success else None
                    })
                
                elif command == 'generate':
                    if not self.is_ready or not self.model:
                        await websocket.send_json({
                            'event': 'error',
                            'message': 'Model not loaded'
                        })
                        continue
                    
                    messages = request.get('messages', [])
                    max_tokens = request.get('max_tokens', 512)
                    temperature = request.get('temperature', 0.7)
                    
                    # Format the prompt
                    prompt = self.format_messages(messages)
                    
                    # Send start marker
                    await websocket.send_json({
                        'event': 'generation_start',
                        'model': self.model_name
                    })
                    
                    # Generate with streaming
                    stream = self.model(
                        prompt,
                        max_tokens=max_tokens,
                        temperature=temperature,
                        stop=["Human:", "System:"],
                        echo=False,
                        stream=True
                    )
                    
                    generated_text = ""
                    
                    for chunk in stream:
                        token = chunk['choices'][0]['text']
                        if token:
                            generated_text += token
                            
                            # Send token directly to the client
                            await websocket.send_json({
                                'event': 'token',
                                'token': token,
                                'text_so_far': generated_text
                            })
                            
                            # Small delay to make streaming more visible
                            await asyncio.sleep(0.005)  # 5ms delay
                    
                    # Send completion marker
                    await websocket.send_json({
                        'event': 'generation_complete',
                        'text': generated_text
                    })
                
                elif command == 'status':
                    await websocket.send_json({
                        'event': 'status',
                        'is_ready': self.is_ready,
                        'model': self.model_name
                    })
                
                else:
                    await websocket.send_json({
                        'event': 'error',
                        'message': f'Unknown command: {command}'
                    })
        
        except WebSocketDisconnect:
            await self.unregister_client(websocket)
        except Exception as e:
            logger.error(f"Error handling client: {e}")
            try:
                await websocket.send_json({
                    'event': 'error',
                    'message': str(e)
                })
            except:
                pass
            await self.unregister_client(websocket)


def create_direct_bridge_app():
    """Create a FastAPI app with WebSocket support for direct LLM access"""
    app = FastAPI(title="CodeDeck Direct LLM Bridge")
    
    # Determine models directory
    base_dir = Path(__file__).parent.parent.parent
    models_dir = base_dir / "models"
    
    # Create the bridge
    bridge = DirectLLMBridge(models_dir)
    
    @app.websocket("/ws")
    async def websocket_endpoint(websocket: WebSocket):
        await bridge.handle_client(websocket)
    
    @app.get("/")
    async def get_root():
        return {
            "status": "online",
            "message": "CodeDeck Direct LLM Bridge is running",
            "is_ready": bridge.is_ready,
            "model": bridge.model_name
        }
    
    return app


if __name__ == "__main__":
    # Configure logging
    logging.basicConfig(level=logging.INFO)
    
    # Create and run the app
    app = create_direct_bridge_app()
    
    # Get port from environment or use default
    port = int(os.environ.get("DIRECT_BRIDGE_PORT", 8765))
    
    print(f"🚀 Starting Direct LLM Bridge on port {port}")
    
    uvicorn.run(app, host="127.0.0.1", port=port) 
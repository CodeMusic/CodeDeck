"""
CodeDeckService - Main API Hub
Orchestrates the LLM inference pipeline for CodeDeck
"""

import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.responses import HTMLResponse
from contextlib import asynccontextmanager
import logging
import os
import sys

from .api import create_api_router
from .model_loader import ModelEngine

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("codedeck_service")

# Global model engine instance
model_engine = None


@asynccontextmanager
async def lifespan_manager(app: FastAPI):
    """
    Manages the startup and shutdown lifecycle
    """
    global model_engine
    
    logger.info("🧠 Initializing model engine...")
    
    try:
        # Initialize the model engine
        models_manifest_path = os.path.join(
            os.path.dirname(os.path.dirname(__file__)), 
            "..", 
            "models", 
            "models.json"
        )
        
        model_engine = ModelEngine(models_manifest_path)
        await model_engine.initialize()
        
        logger.info("✨ Model engine ready")
        
        yield
        
    except Exception as error:
        logger.error(f"💥 Initialization failed: {error}")
        sys.exit(1)
    
    finally:
        # Graceful shutdown
        if model_engine:
            await model_engine.shutdown()
        logger.info("🌙 Model engine shutdown complete")


def create_app() -> FastAPI:
    """
    Creates the main FastAPI application
    """
    
    # Create the core app
    app = FastAPI(
        title="CodeDeck Neural Interface",
        description="Local LLM Inference Hub - Where silicon meets synapses",
        version="1.0.0",
        lifespan=lifespan_manager
    )
    
    # Configure CORS
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    
    # Include API routes
    api_router = create_api_router()
    app.include_router(api_router)
    
    # Setup templates
    templates_path = os.path.join(os.path.dirname(__file__), "templates")
    if os.path.exists(templates_path):
        templates = Jinja2Templates(directory=templates_path)
        
        @app.get("/ui", response_class=HTMLResponse)
        async def get_ui(request: Request):
            """Serve the HTML interface"""
            return templates.TemplateResponse("index.html", {"request": request})
    
    # Mount static files
    static_path = os.path.join(os.path.dirname(__file__), "static")
    if os.path.exists(static_path):
        app.mount("/static", StaticFiles(directory=static_path), name="static")
    
    return app


# Create the main application instance
app = create_app()


@app.get("/")
async def root():
    """
    Basic status endpoint
    """
    return {
        "status": "online",
        "message": "CodeDeck Neural Interface is running",
        "engine_state": "ready" if model_engine and model_engine.is_ready else "initializing",
        "ui_available": "/ui"
    }


@app.get("/health")
async def health_check():
    """
    Health check endpoint
    """
    if not model_engine:
        raise HTTPException(status_code=503, detail="Model engine not initialized")
    
    health_status = await model_engine.get_health_status()
    return {
        "status": "healthy",
        "engine_metrics": health_status,
        "system_status": "operational"
    }


if __name__ == "__main__":
    logger.info("🚀 Starting CodeDeck service...")
    
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        log_level="info"
    ) 
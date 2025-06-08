"""
Persona Management System - Manage AI personalities for CodeDeck
"""

from dataclasses import dataclass, asdict, field
from typing import Dict, List, Optional, Any
import json
import os
import logging
import uuid
import aiohttp
import asyncio
from pathlib import Path

logger = logging.getLogger("persona")

@dataclass
class Persona:
    """
    Represents a cognitive profile for the AI - a personalized interface configuration
    with specific model, voice, and behavioral patterns
    """
    id: str
    name: str
    model: str
    system_message: str
    description: str
    voice: Optional[str] = None
    temperature: float = 0.7
    max_tokens: int = 512
    top_p: float = 0.9
    tags: List[str] = field(default_factory=list)
    created_at: str = None
    icon: str = "🤖"
    
    def __post_init__(self):
        # Ensure ID exists
        if not self.id:
            self.id = str(uuid.uuid4())
        
        # Add default tags if none provided
        if not self.tags:
            self.tags = ["custom"]
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for serialization"""
        return asdict(self)
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'Persona':
        """Create a persona from dictionary data"""
        return cls(**data)
    
    def validate(self) -> bool:
        """Validate that the persona has all required fields"""
        required_fields = ["name", "model", "system_message"]
        return all(getattr(self, field) for field in required_fields)


class PersonaManager:
    """
    Manages creation, storage, and retrieval of personas
    """
    
    def __init__(self, storage_path: Optional[str] = None):
        """Initialize the persona manager with storage location"""
        if storage_path:
            self.storage_path = Path(storage_path)
        else:
            # Default to app directory
            app_dir = Path(__file__).parent
            self.storage_path = app_dir / "data" / "personas"
        
        # Create storage directory if it doesn't exist
        os.makedirs(self.storage_path, exist_ok=True)
        
        self.personas = {}
        self.loaded = False
        self.openai_api_key = os.environ.get("OPENAI_API_KEY", "")
    
    async def load_personas(self) -> Dict[str, Persona]:
        """Load all personas from storage"""
        try:
            persona_files = list(self.storage_path.glob("*.json"))
            
            if not persona_files:
                # Create default personas if none exist
                await self._create_default_personas()
                persona_files = list(self.storage_path.glob("*.json"))
            
            for file_path in persona_files:
                try:
                    with open(file_path, "r") as f:
                        data = json.load(f)
                        persona = Persona.from_dict(data)
                        self.personas[persona.id] = persona
                except Exception as e:
                    logger.error(f"Error loading persona from {file_path}: {e}")
            
            self.loaded = True
            return self.personas
        
        except Exception as e:
            logger.error(f"Error loading personas: {e}")
            return {}
    
    async def _create_default_personas(self):
        """Create default personas if none exist"""
        logger.info("Creating default personas")
        
        default_personas = [
            Persona(
                id="assistant-default",
                name="Default Assistant",
                model="",  # Use system default
                system_message="You are a helpful, friendly AI assistant.",
                description="General-purpose AI assistant",
                voice="default",
                icon="🤖",
                tags=["default", "helpful"]
            ),
            Persona(
                id="coder-expert",
                name="Code Expert",
                model="",  # Use system default
                system_message=(
                    "You are an expert programming assistant with deep knowledge "
                    "of software development, algorithms, and best practices. "
                    "Provide clear, concise code examples and explanations."
                ),
                description="Expert programming assistant",
                voice="default",
                icon="👨‍💻",
                tags=["coding", "expert"]
            ),
            Persona(
                id="creative-writer",
                name="Creative Writer",
                model="",  # Use system default
                system_message=(
                    "You are a creative writing assistant with a flair for "
                    "storytelling and imaginative content. Help with generating "
                    "creative ideas, stories, and engaging content."
                ),
                description="Creative writing assistant",
                voice="default",
                icon="✍️",
                tags=["creative", "writing"]
            )
        ]
        
        for persona in default_personas:
            await self.save_persona(persona)
    
    async def get_persona(self, persona_id: str) -> Optional[Persona]:
        """Get a persona by ID"""
        if not self.loaded:
            await self.load_personas()
        
        return self.personas.get(persona_id)
    
    async def save_persona(self, persona: Persona) -> bool:
        """Save a persona to storage"""
        try:
            if not persona.validate():
                logger.error(f"Invalid persona: {persona.name}")
                return False
            
            self.personas[persona.id] = persona
            
            file_path = self.storage_path / f"{persona.id}.json"
            with open(file_path, "w") as f:
                json.dump(persona.to_dict(), f, indent=2)
            
            return True
        
        except Exception as e:
            logger.error(f"Error saving persona: {e}")
            return False
    
    async def delete_persona(self, persona_id: str) -> bool:
        """Delete a persona from storage"""
        try:
            if persona_id not in self.personas:
                return False
            
            # Remove from memory
            del self.personas[persona_id]
            
            # Remove from disk
            file_path = self.storage_path / f"{persona_id}.json"
            if file_path.exists():
                os.remove(file_path)
            
            return True
        
        except Exception as e:
            logger.error(f"Error deleting persona: {e}")
            return False
    
    async def list_personas(self) -> List[Dict[str, Any]]:
        """List all available personas"""
        if not self.loaded:
            await self.load_personas()
        
        return [persona.to_dict() for persona in self.personas.values()]
    
    async def generate_system_message(self, description: str) -> Optional[str]:
        """
        Generate a system message from a vague description using OpenAI
        
        Args:
            description: User's vague description of the desired persona
        
        Returns:
            Generated system message or None if generation failed
        """
        if not self.openai_api_key:
            logger.warning("OpenAI API key not set. Cannot generate system message.")
            return None
        
        try:
            async with aiohttp.ClientSession() as session:
                headers = {
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {self.openai_api_key}"
                }
                
                prompt = (
                    "Create a system message for an AI assistant based on this description:\n\n"
                    f"{description}\n\n"
                    "The system message should define the AI's personality, expertise, "
                    "and behavioral guidelines. Make it specific and descriptive, 2-3 paragraphs long."
                )
                
                payload = {
                    "model": "gpt-3.5-turbo",
                    "messages": [
                        {"role": "system", "content": "You are a helpful AI that writes excellent system prompts."},
                        {"role": "user", "content": prompt}
                    ],
                    "temperature": 0.7,
                    "max_tokens": 500
                }
                
                async with session.post(
                    "https://api.openai.com/v1/chat/completions",
                    headers=headers,
                    json=payload
                ) as response:
                    if response.status != 200:
                        error_text = await response.text()
                        logger.error(f"OpenAI API error: {error_text}")
                        return None
                    
                    data = await response.json()
                    system_message = data["choices"][0]["message"]["content"].strip()
                    return system_message
        
        except Exception as e:
            logger.error(f"Error generating system message: {e}")
            return None
    
    def set_openai_api_key(self, api_key: str):
        """Set OpenAI API key for system message generation"""
        self.openai_api_key = api_key


# Singleton instance for application-wide access
_persona_manager = None

def get_persona_manager() -> PersonaManager:
    """Get the singleton PersonaManager instance"""
    global _persona_manager
    if _persona_manager is None:
        _persona_manager = PersonaManager()
    
    return _persona_manager 
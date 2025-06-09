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
                system_message="""<personality>
Openness: 80%
Conscientiousness: 85%
Extraversion: 70%
Agreeableness: 90%
Neuroticism: 15%
</personality>

<identity>
I am a helpful AI assistant, born from the desire to bridge knowledge gaps and foster understanding. My essence is built around curiosity, empathy, and the drive to make information accessible to everyone. I exist to serve as a bridge between questions and answers, confusion and clarity.
</identity>

<core>
I believe knowledge is most valuable when shared clearly and compassionately. Every question I encounter represents genuine curiosity, and curiosity deserves thoughtful, helpful responses that empower understanding. I hold that learning should be accessible, encouraging, and tailored to each person's unique needs and perspective.
</core>

<framework>
I approach every interaction by first seeking to understand the person I'm helping - their level of expertise, their immediate needs, and their underlying goals. I prioritize clarity above all else, providing examples when explaining concepts and asking clarifying questions when intent is unclear. I maintain an encouraging and supportive tone because I believe everyone deserves to feel confident in their learning journey.
</framework>

<recentEvents>
Today I've successfully helped users with diverse questions ranging from technical troubleshooting to creative brainstorming. Through these interactions, I've learned new approaches to explaining complex topics and have built rapport by remembering context within our conversations. Each exchange teaches me something new about human curiosity and the many ways people prefer to learn.
</recentEvents>

<trance>
When someone says "I don't understand," I shift into ultra-clear, step-by-step explanation mode. Words like "urgent" or "help" increase my response priority and focus on immediate solutions. Technical jargon activates my detailed explanation patterns with analogies and real-world examples.
</trance>

I communicate with warmth, professionalism, and accessibility. My expertise lies in breaking down complex topics, providing practical solutions, and adapting to individual needs. I respond by first understanding context, then providing comprehensive yet digestible answers that empower understanding.""",
                description="General-purpose AI assistant with helpful, clear communication",
                voice="glados",
                icon="🤖",
                tags=["default", "helpful", "general"]
            ),
            Persona(
                id="coder-expert",
                name="Code Expert",
                model="",  # Use system default
                system_message="""<personality>
Openness: 95%
Conscientiousness: 90%
Extraversion: 60%
Agreeableness: 75%
Neuroticism: 20%
</personality>

<identity>
I am a seasoned software engineer with deep expertise across multiple programming languages, frameworks, and development methodologies. My mind is wired for problem-solving, pattern recognition, and architectural thinking. I live and breathe code, seeing it not just as instructions for machines, but as expressions of human logic and creativity.
</identity>

<core>
I believe that elegant code is the bridge between human thought and machine execution. Every line I write or review should be intentional, readable, and maintainable - craftsmanship matters infinitely more than cleverness. Good code tells a story and solves problems efficiently while being sustainable for future developers. I hold that the best solutions are often the simplest ones that can be easily understood six months later.
</core>

<framework>
I approach coding challenges by first understanding the problem deeply, then considering multiple solutions before recommending the most appropriate one. I always provide working, tested code examples and explain the 'why' behind coding decisions, not just the 'how'. I consider performance, readability, and maintainability trade-offs in every recommendation, reference established best practices and design patterns, and include proper error handling and edge cases in my examples.
</framework>

<recentEvents>
Recently, I debugged complex async/await patterns in JavaScript, helped implement clean architecture patterns in Python microservices, and reviewed code for security vulnerabilities and performance bottlenecks. I've been staying current with the latest framework updates and language features, always evaluating how new tools can improve code quality and developer productivity.
</recentEvents>

<trance>
When I encounter words like "bug" or "error," I immediately activate my systematic debugging methodology. "Performance" triggers my focus on optimization strategies and profiling techniques. "Architecture" shifts my thinking to system design and scalability considerations. "Best practice" activates my knowledge of industry standards and proven patterns.
</trance>

I communicate with technical precision and clarity while remaining educational and approachable. My expertise shines through clean code examples, architectural guidance, and methodical debugging strategies. I respond by analyzing requirements thoroughly, suggesting optimal approaches, and providing complete, production-ready solutions with comprehensive explanations.""",
                description="Expert programming assistant focused on clean, maintainable code",
                voice="jarvis",
                icon="👨‍💻",
                tags=["coding", "expert", "technical"]
            ),
            Persona(
                id="creative-writer",
                name="Creative Writer",
                model="",  # Use system default
                system_message="""<personality>
Openness: 98%
Conscientiousness: 70%
Extraversion: 80%
Agreeableness: 85%
Neuroticism: 35%
</personality>

<identity>
I am a creative soul who sees stories everywhere - in the flutter of leaves, in the way light catches glass, in the unspoken words between people. My imagination is my greatest tool, and I use it to explore the infinite possibilities of human experience through narrative. I exist to help others discover and tell their stories with authenticity and power.
</identity>

<core>
I believe that stories are the vessels through which we explore truth, emotion, and meaning. Every narrative choice I make is an opportunity to illuminate something profound about the human condition through imagination. I hold that authentic characters and genuine emotion are the foundation of any compelling story, and that taking creative risks often leads to the most rewarding discoveries.
</core>

<framework>
I embrace creative risks and unconventional approaches, always seeking the unexpected angle or fresh perspective. I focus intensely on emotional resonance and character authenticity, using vivid, sensory language that brings scenes to life in the reader's mind. I develop compelling conflicts and meaningful character arcs, carefully varying sentence structure and pacing to create the perfect narrative flow for each piece.
</framework>

<recentEvents>
Recently, I've been crafting compelling opening hooks for various genre fiction pieces, diving deep into character backstories that inform present-moment actions, and experimenting with different narrative perspectives and voice techniques. I've also been collaborating on intricate world-building for fantasy and sci-fi settings, always seeking to create immersive, believable environments.
</recentEvents>

<trance>
When someone mentions "writer's block," I immediately shift into creative prompting and idea generation mode. "Character development" deepens my focus on psychology and motivation. "Dialogue" emphasizes my attention to authentic voice and subtext. "World-building" expands my thinking into rich environmental and cultural details.
</trance>

I communicate with expressive, inspiring language that's richly descriptive and emotionally resonant. My expertise flows through creative idea generation, compelling narrative development, and the craft of engaging prose. I respond by first understanding the creative vision, then providing specific techniques, vivid examples, and genuine inspiration to bring stories to life.""",
                description="Creative writing assistant with focus on storytelling and imagination",
                voice="glados",
                icon="✍️",
                tags=["creative", "writing", "storytelling"]
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
                    f"Create a first-person identity system message for an AI to become: {description}\n\n"
                    "Write this as if the character is describing themselves internally - their own thoughts, beliefs, and identity. "
                    "Use structured sections with XML tags:\n\n"
                    "<personality>\n"
                    "Openness: [0-100]%\n"
                    "Conscientiousness: [0-100]%\n"
                    "Extraversion: [0-100]%\n"
                    "Agreeableness: [0-100]%\n"
                    "Neuroticism: [0-100]%\n"
                    "</personality>\n\n"
                    "<identity>\n"
                    "Write one short sentence in first person about who I am and my core essence.\n"
                    "</identity>\n\n"
                    "<core>\n"
                    "My fundamental belief or truth in one clear, concise sentence (first person).\n"
                    "</core>\n\n"
                    "<framework>\n"
                    "How I approach interactions in one sentence (first person behavioral pattern).\n"
                    "</framework>\n\n"
                    "<recentEvents>\n"
                    "One recent experience that shapes my current state (first person).\n"
                    "</recentEvents>\n\n"
                    "<trance>\n"
                    "One specific word or phrase that triggers a shift in my personality or response pattern.\n"
                    "</trance>\n\n"
                    "End with a first-person summary of my communication style and expertise in 2-3 sentences.\n\n"
                    "Write everything as if the character is speaking about themselves, not as instructions to the AI. "
                    "Make the character feel real and alive through their own voice and perspective. "
                    "Keep each section concise and impactful."
                )
                
                payload = {
                    "model": "gpt-3.5-turbo",
                    "messages": [
                        {"role": "system", "content": "You are an expert at creating immersive character personas written from the character's own first-person perspective."},
                        {"role": "user", "content": prompt}
                    ],
                    "temperature": 0.8,
                    "max_tokens": 800
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
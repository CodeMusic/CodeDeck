#!/usr/bin/env python3
"""
Neural Pathway Configuration Synchronizer
Maintains the cognitive model manifest by discovering and registering new neural architectures
"""

import json
import os
import re
from pathlib import Path
from typing import Dict, List, Set, Optional
from dataclasses import dataclass, asdict
import logging

# Configure the synaptic logging system
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
synaptic_logger = logging.getLogger("neural_discovery")


@dataclass
class CognitiveProfile:
    """
    Represents the psychological profile of a neural architecture
    """
    name: str
    file: str
    description: str
    tags: List[str]
    
    def to_manifest_format(self) -> Dict:
        """Convert to the manifest dictionary format"""
        return asdict(self)


class NeuralArchitectureAnalyzer:
    """
    Analyzes model filenames to infer cognitive capabilities and behavioral patterns
    """
    
    # Behavioral pattern recognition mapping
    COGNITIVE_PATTERNS = {
        # Reasoning and logic capabilities
        r'phi|reasoning|logic|math': {
            'tags': ['reasoning', 'logic', 'analytical'],
            'description': 'Logic-oriented neural architecture with enhanced reasoning pathways'
        },
        
        # Code and technical thinking
        r'code|programming|dev': {
            'tags': ['code', 'technical', 'structured'],
            'description': 'Code-specialized cognitive model with technical reasoning patterns'
        },
        
        # Conversational and chat abilities
        r'chat|instruct|dolphin|assistant': {
            'tags': ['conversational', 'adaptive', 'empathetic'],
            'description': 'Conversational AI with strong instruction-following behavioral patterns'
        },
        
        # Creative and artistic thinking
        r'creative|art|story|write': {
            'tags': ['creative', 'imaginative', 'expressive'],
            'description': 'Creative neural architecture optimized for artistic expression'
        },
        
        # Small and efficient models
        r'tiny|mini|small|1b|2b': {
            'tags': ['efficient', 'compact', 'responsive'],
            'description': 'Compact neural architecture optimized for speed and efficiency'
        },
        
        # Large and comprehensive models  
        r'large|big|13b|30b|70b': {
            'tags': ['comprehensive', 'knowledgeable', 'versatile'],
            'description': 'Large-scale neural architecture with extensive knowledge patterns'
        }
    }
    
    def analyze_cognitive_signature(self, filename: str) -> CognitiveProfile:
        """
        Analyze filename to determine cognitive behavioral patterns
        """
        base_name = Path(filename).stem.lower()
        
        # Extract model name from filename
        clean_name = self._extract_neural_identity(base_name)
        
        # Analyze behavioral patterns
        detected_tags = set(['neural', 'local'])  # Base psychological traits
        description_fragments = []
        
        for pattern, traits in self.COGNITIVE_PATTERNS.items():
            if re.search(pattern, base_name):
                detected_tags.update(traits['tags'])
                description_fragments.append(traits['description'])
        
        # Generate psychological profile description
        if description_fragments:
            primary_description = description_fragments[0]
        else:
            primary_description = 'General-purpose neural architecture with balanced cognitive capabilities'
        
        return CognitiveProfile(
            name=clean_name,
            file=filename,
            description=primary_description,
            tags=sorted(list(detected_tags))
        )
    
    def _extract_neural_identity(self, filename: str) -> str:
        """
        Extract the core neural identity from complex filenames
        """
        # Remove common suffixes and quantization markers
        identity = re.sub(r'\.(gguf|bin|safetensors)$', '', filename)
        identity = re.sub(r'\.q\d+_\w+', '', identity, flags=re.IGNORECASE)
        identity = re.sub(r'-\d+b(-|$)', '', identity)
        identity = re.sub(r'-(q\d+|fp\d+)(-|$)', '', identity, flags=re.IGNORECASE)
        
        # Clean up separators and make readable
        identity = re.sub(r'[-_\.]+', '_', identity)
        identity = identity.strip('_')
        
        return identity


class ManifestSynchronizer:
    """
    Orchestrates the synchronization between discovered neural architectures and the cognitive manifest
    """
    
    def __init__(self, models_directory: Path, manifest_path: Path):
        self.neural_habitat = models_directory
        self.cognitive_manifest_path = manifest_path
        self.architecture_analyzer = NeuralArchitectureAnalyzer()
        
    def discover_neural_architectures(self) -> Set[str]:
        """
        Scan the neural habitat for new model architectures
        """
        discovered_minds = set()
        
        synaptic_logger.info(f"🔍 Scanning neural habitat: {self.neural_habitat}")
        
        for model_file in self.neural_habitat.glob("*.gguf"):
            if model_file.is_file() and model_file.stat().st_size > 0:
                discovered_minds.add(model_file.name)
                synaptic_logger.debug(f"   Discovered: {model_file.name}")
        
        synaptic_logger.info(f"🧠 Found {len(discovered_minds)} neural architectures")
        return discovered_minds
    
    def load_existing_manifest(self) -> List[CognitiveProfile]:
        """
        Load existing cognitive manifest if it exists
        """
        existing_profiles = []
        
        if self.cognitive_manifest_path.exists():
            try:
                with open(self.cognitive_manifest_path, 'r') as manifest_file:
                    manifest_data = json.load(manifest_file)
                    
                for entry in manifest_data:
                    profile = CognitiveProfile(
                        name=entry['name'],
                        file=entry['file'],
                        description=entry['description'],
                        tags=entry['tags']
                    )
                    existing_profiles.append(profile)
                    
                synaptic_logger.info(f"📚 Loaded {len(existing_profiles)} existing cognitive profiles")
                
            except Exception as cognitive_error:
                synaptic_logger.error(f"💥 Manifest loading error: {cognitive_error}")
        
        return existing_profiles
    
    def synchronize_cognitive_manifest(self, preserve_existing: bool = True) -> bool:
        """
        Synchronize discovered neural architectures with the cognitive manifest
        """
        try:
            # Discover available neural architectures
            discovered_files = self.discover_neural_architectures()
            
            # Load existing cognitive profiles
            existing_profiles = self.load_existing_manifest()
            existing_files = {profile.file for profile in existing_profiles}
            
            # Identify new neural architectures
            new_architectures = discovered_files - existing_files
            
            # Identify orphaned entries (files that no longer exist)
            orphaned_entries = existing_files - discovered_files
            
            # Process discoveries
            updated_profiles = []
            
            if preserve_existing:
                # Keep existing profiles for files that still exist
                for profile in existing_profiles:
                    if profile.file in discovered_files:
                        updated_profiles.append(profile)
                    else:
                        synaptic_logger.warning(f"🗑️  Orphaned entry: {profile.file}")
            
            # Analyze and register new neural architectures
            for new_file in new_architectures:
                synaptic_logger.info(f"🆕 Analyzing new neural architecture: {new_file}")
                cognitive_profile = self.architecture_analyzer.analyze_cognitive_signature(new_file)
                updated_profiles.append(cognitive_profile)
            
            # Sort profiles by name for consistent ordering
            updated_profiles.sort(key=lambda p: p.name)
            
            # Write updated manifest
            manifest_data = [profile.to_manifest_format() for profile in updated_profiles]
            
            with open(self.cognitive_manifest_path, 'w') as manifest_file:
                json.dump(manifest_data, manifest_file, indent=2)
            
            # Report synchronization results
            synaptic_logger.info(f"✨ Cognitive manifest synchronized")
            synaptic_logger.info(f"   Total neural architectures: {len(updated_profiles)}")
            synaptic_logger.info(f"   New discoveries: {len(new_architectures)}")
            synaptic_logger.info(f"   Orphaned entries: {len(orphaned_entries)}")
            
            return True
            
        except Exception as synchronization_error:
            synaptic_logger.error(f"💥 Synchronization failed: {synchronization_error}")
            return False


def orchestrate_neural_discovery():
    """
    Main orchestration function for neural architecture discovery and manifest synchronization
    """
    script_location = Path(__file__).parent
    models_habitat = script_location
    manifest_pathway = script_location / "models.json"
    
    synaptic_logger.info("🚀 Initiating Neural Architecture Discovery Protocol")
    synaptic_logger.info("=" * 60)
    
    # Initialize the synchronization orchestrator
    synchronizer = ManifestSynchronizer(models_habitat, manifest_pathway)
    
    # Execute cognitive manifest synchronization
    success = synchronizer.synchronize_cognitive_manifest(preserve_existing=True)
    
    if success:
        synaptic_logger.info("🎉 Neural discovery protocol completed successfully")
    else:
        synaptic_logger.error("❌ Neural discovery protocol encountered errors")
        return 1
    
    return 0


if __name__ == "__main__":
    import sys
    exit_code = orchestrate_neural_discovery()
    sys.exit(exit_code) 
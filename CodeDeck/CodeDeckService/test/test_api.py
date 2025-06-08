#!/usr/bin/env python3
"""
Simple test script for CodeDeck API endpoints
"""

import requests
import json
import time
import sys

BASE_URL = "http://localhost:8000"


def test_health_check():
    """Test basic health endpoint"""
    print("🔍 Testing health check...")
    try:
        response = requests.get(f"{BASE_URL}/health")
        if response.status_code == 200:
            print("✅ Health check passed")
            print(json.dumps(response.json(), indent=2))
        else:
            print(f"❌ Health check failed: {response.status_code}")
            print(response.text)
    except requests.exceptions.ConnectionError:
        print("❌ Cannot connect to server. Is it running?")
        return False
    return True


def test_list_models():
    """Test models listing endpoint"""
    print("\n🔍 Testing models list...")
    try:
        response = requests.get(f"{BASE_URL}/v1/models")
        if response.status_code == 200:
            print("✅ Models list retrieved")
            data = response.json()
            print(f"Available models: {len(data['data'])}")
            for model in data['data']:
                print(f"  - {model['id']}: {model['description']}")
        else:
            print(f"❌ Models list failed: {response.status_code}")
            print(response.text)
    except Exception as e:
        print(f"❌ Error: {e}")


def test_chat_completion():
    """Test chat completion endpoint"""
    print("\n🔍 Testing chat completion...")
    
    # First get available models
    try:
        models_response = requests.get(f"{BASE_URL}/v1/models")
        if models_response.status_code != 200:
            print("❌ Cannot get models list")
            return
        
        models = models_response.json()['data']
        if not models:
            print("❌ No models available")
            return
        
        # Use the first available model
        model_id = models[0]['id']
        print(f"Using model: {model_id}")
        
        # Test request
        chat_request = {
            "model": model_id,
            "messages": [
                {
                    "role": "user",
                    "content": "Hello! Can you tell me what 2+2 equals?"
                }
            ],
            "max_tokens": 100,
            "temperature": 0.7
        }
        
        response = requests.post(
            f"{BASE_URL}/v1/chat/completions",
            json=chat_request,
            headers={"Content-Type": "application/json"}
        )
        
        if response.status_code == 200:
            print("✅ Chat completion successful")
            data = response.json()
            print("Response:")
            print(f"  Model: {data.get('model', 'unknown')}")
            if 'choices' in data and data['choices']:
                content = data['choices'][0]['message']['content']
                print(f"  Content: {content}")
        else:
            print(f"❌ Chat completion failed: {response.status_code}")
            print(response.text)
    
    except Exception as e:
        print(f"❌ Error: {e}")


def main():
    """Run all tests"""
    print("🧪 CodeDeck API Test Suite")
    print("=" * 40)
    
    if not test_health_check():
        print("\n❌ Server not accessible, stopping tests")
        sys.exit(1)
    
    test_list_models()
    test_chat_completion()
    
    print("\n🎉 Test suite completed!")


if __name__ == "__main__":
    main() 
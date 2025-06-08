#!/bin/bash

# CodeDeck Service Startup Script
# Activates virtual environment and starts the FastAPI server

set -e

echo "🚀 Starting CodeDeck Neural Interface..."

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Activate virtual environment
VENV_PATH="$PROJECT_ROOT/codedeck_venv"

if [ ! -d "$VENV_PATH" ]; then
    echo "❌ Virtual environment not found at $VENV_PATH"
    echo "Please create it first with: python3 -m venv $VENV_PATH"
    exit 1
fi

echo "📦 Activating virtual environment..."
source "$VENV_PATH/bin/activate"

# Install dependencies if needed
echo "🔧 Checking dependencies..."
pip install -r "$SCRIPT_DIR/requirements.txt"

# Set environment variables
export PYTHONPATH="$SCRIPT_DIR:$PYTHONPATH"

# Start the server
echo "🌟 Starting FastAPI server..."
cd "$SCRIPT_DIR"
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload

echo "✨ CodeDeck Neural Interface is ready!" 
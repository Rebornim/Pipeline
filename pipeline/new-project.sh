#!/bin/bash

# Creates a new project directory with the standard pipeline structure.
# Usage: bash pipeline/new-project.sh <system-name>

set -e

if [ -z "$1" ]; then
    echo "Usage: bash pipeline/new-project.sh <system-name>"
    echo "Example: bash pipeline/new-project.sh gun-system"
    exit 1
fi

PIPELINE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$PIPELINE_ROOT/projects/$1"

if [ -d "$PROJECT_DIR" ]; then
    echo "Error: Project '$1' already exists at $PROJECT_DIR"
    exit 1
fi

# Create project directories
mkdir -p "$PROJECT_DIR/src/src/server"
mkdir -p "$PROJECT_DIR/src/src/client"
mkdir -p "$PROJECT_DIR/src/src/shared"

# Create state file
cat > "$PROJECT_DIR/state.md" << 'STATE'
# Project State

**Stage:** Idea
**Status:** not-started
**Pipeline Version:** v3
**Last Updated:** (auto-update this)

## Resume Notes
<!-- If you stopped mid-pass, write exactly where you left off here -->
<!-- Include: which pass, which step (design/build/prove), what's done, what's next -->

STATE

# Create default Rojo project file
cat > "$PROJECT_DIR/src/default.project.json" << 'ROJO'
{
  "name": "GameSystem",
  "tree": {
    "$className": "DataModel",
    "ServerScriptService": {
      "$className": "ServerScriptService",
      "$path": "src/server"
    },
    "StarterPlayer": {
      "$className": "StarterPlayer",
      "StarterPlayerScripts": {
        "$className": "StarterPlayerScripts",
        "$path": "src/client"
      }
    },
    "ReplicatedStorage": {
      "$className": "ReplicatedStorage",
      "$path": "src/shared"
    }
  }
}
ROJO

echo "Project '$1' created at $PROJECT_DIR"
echo ""
echo "Structure:"
echo "  $PROJECT_DIR/"
echo "  ├── state.md"
echo "  └── src/"
echo "      ├── default.project.json"
echo "      └── src/"
echo "          ├── server/"
echo "          ├── client/"
echo "          └── shared/"
echo ""
echo "Next: Open Claude Code in $PIPELINE_ROOT and start the Idea stage."
echo "  Tell Claude: \"Starting idea for $1\""

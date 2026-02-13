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

**Phase:** 1
**Status:** not-started
**Last Updated:** (auto-update this)

## Resume Notes
<!-- If you stopped mid-phase, write exactly where you left off here -->

STATE

# Copy testing report template
cp "$PIPELINE_ROOT/pipeline/templates/testing-report.md" "$PROJECT_DIR/testing-report.md"

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
echo "  ├── testing-report.md  (fill this out during Phase 3 testing)"
echo "  └── src/"
echo "      ├── default.project.json"
echo "      └── src/"
echo "          ├── server/"
echo "          ├── client/"
echo "          └── shared/"
echo ""
echo "Next: Open Claude Code in $PIPELINE_ROOT and start Phase 1."
echo "  Tell Claude: \"Starting Phase 1 for $1\""

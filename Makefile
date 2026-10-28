.PHONY: all build build-release test db reset-db clean clean-db clean-all-dbs env-info help

# Active Environment (dev, test, prod). Default is dev.
ENV ?= dev

# Load environment variable files if they exist (highest precedence to lowest)
-include config/environments/$(ENV).env
-include .env.$(ENV)
-include .env

# Export loaded variables to child processes
export PLAYITRIGHT_ENV ?= $(ENV)

# Resolved database paths per environment
DB_DIR ?= db/$(ENV)
DB_FILE ?= $(if $(PLAYITRIGHT_DB_PATH),$(if $(filter :memory:,$(PLAYITRIGHT_DB_PATH)),$(DB_DIR)/library.db,$(PLAYITRIGHT_DB_PATH)),$(DB_DIR)/library.db)
SCHEMA_FILE ?= schema.sql

# Toolchain flags for Swift Testing on macOS CommandLineTools
CLT_FRAMEWORKS ?= /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_USRLIB ?= /Library/Developer/CommandLineTools/Library/Developer/usr/lib
SWIFT_TEST_FLAGS ?= -Xswiftc -F$(CLT_FRAMEWORKS) -Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) -Xlinker -rpath -Xlinker $(CLT_USRLIB)

# Default target: build the Swift package and create the database for the current environment
all: build db

## build: Build the Swift package in debug mode
build:
	@echo "==> Building Swift package (debug) [ENV=$(ENV)]..."
	swift build

## build-release: Build the Swift package in release mode
build-release:
	@echo "==> Building Swift package (release) [ENV=$(ENV)]..."
	swift build -c release

## test: Run automated tests in testing environment
test:
	@echo "==> Running test suite [ENV=test]..."
	PLAYITRIGHT_ENV=test swift test $(SWIFT_TEST_FLAGS)

## db: Initialize the database for the active environment (ENV=dev|test|prod)
db: $(DB_FILE)

$(DB_FILE): $(SCHEMA_FILE)
	@echo "==> Creating database directory for '$(ENV)' at '$$(dirname $(DB_FILE))'..."
	@mkdir -p $$(dirname $(DB_FILE))
	@echo "==> Initializing SQLite database at '$(DB_FILE)' using '$(SCHEMA_FILE)'..."
	@sqlite3 $(DB_FILE) < $(SCHEMA_FILE)
	@echo "==> Database successfully created for '$(ENV)' at '$(DB_FILE)'."

## reset-db: Recreate a fresh database for the active environment (ENV=dev|test|prod)
reset-db: clean-db db

## clean-db: Remove database for the active environment (ENV=dev|test|prod)
clean-db:
	@echo "==> Cleaning database for '$(ENV)' at '$(DB_FILE)'..."
	@rm -f $(DB_FILE) $(DB_FILE)-wal $(DB_FILE)-shm

## clean-all-dbs: Remove all databases in db/ across all environments
clean-all-dbs:
	@echo "==> Removing all databases in db/..."
	@rm -rf db/

## clean: Clean build artifacts and all databases
clean: clean-all-dbs
	@echo "==> Cleaning Swift build artifacts..."
	swift package clean

## env-info: Display current active environment and configuration
env-info:
	@echo "Active Environment: $(ENV)"
	@echo "Database File:      $(DB_FILE)"
	@echo "Schema File:        $(SCHEMA_FILE)"
	@echo "Backup Dir:         $(PLAYITRIGHT_BACKUP_DIR)"
	@echo "Artwork Dir:        $(PLAYITRIGHT_ARTWORK_DIR)"

## help: Display this help message
help:
	@echo "PlayItRight Build & Database Management"
	@echo "Usage: make [target] [ENV=dev|test|prod]"
	@echo ""
	@echo "Targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed -e 's/## //g' | awk 'BEGIN {FS = ":"}; {printf "  %-16s %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make db                  # Create dev database (db/dev/library.db)"
	@echo "  make db ENV=test         # Create test database (db/test/library.db)"
	@echo "  make db ENV=prod         # Create prod database (db/prod/library.db)"
	@echo "  make reset-db ENV=dev    # Reset dev database"
	@echo "  make test                # Run test suite in test environment"
	@echo "  make env-info ENV=dev    # Show resolved dev environment parameters"

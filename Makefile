# PlayItRight build, test, and database helpers.
.DEFAULT_GOAL := all

# Active environment (dev, test, prod). Default is dev.
ENV ?= dev
VALID_ENVS := dev test prod

# Load environment variable files if they exist (highest precedence to lowest).
-include config/environments/$(ENV).env
-include .env.$(ENV)
-include .env

# Export the active environment to child processes.
export PLAYITRIGHT_ENV ?= $(ENV)

# Resolved database location for the active environment.
# An in-memory database (e.g. ENV=test) has no file to create or clean.
IS_IN_MEMORY := $(if $(filter :memory:,$(PLAYITRIGHT_DB_PATH)),1,)
DB_FILE ?= $(if $(IS_IN_MEMORY),,$(if $(PLAYITRIGHT_DB_PATH),$(PLAYITRIGHT_DB_PATH),db/$(ENV)/library.db))
DB_DIR ?= $(if $(DB_FILE),$(dir $(DB_FILE)),db/$(ENV))
SCHEMA_FILE ?= db/schema.sql

# Prefer a full Xcode toolchain when available.
XCODE_DEVELOPER_DIR ?= $(shell if [ -d /Applications/Xcode.app/Contents/Developer ]; then echo /Applications/Xcode.app/Contents/Developer; else xcode-select -p; fi)
XCODEBUILD ?= DEVELOPER_DIR="$(XCODE_DEVELOPER_DIR)" xcodebuild
XCODE_PROJECT ?= PlayItRight.xcodeproj
XCODE_SCHEME ?= PlayItRight
XCODE_TEST_DESTINATION ?= platform=tvOS Simulator,name=Apple TV 4K (3rd generation)

.PHONY: all build build-release test xcode-build xcode-test test-suite xcode-clean \
	db reset-db clean-db clean-all-dbs clean distclean env-info check-env help

## all: Build the tvOS app and initialize the database for the active environment
all: build db

## build: Build the tvOS app in debug mode
build: xcode-build

## build-release: Build the tvOS app in release mode
build-release:
	@echo "==> Building $(XCODE_SCHEME) for tvOS (Release)..."
	$(XCODEBUILD) -project $(XCODE_PROJECT) -scheme $(XCODE_SCHEME) \
		-destination 'generic/platform=tvOS' -configuration Release \
		build CODE_SIGNING_ALLOWED=NO

## test: Run the app, core, and UI tests on the tvOS simulator
test: xcode-test

## xcode-build: Build the tvOS app and LibraryCore framework with Xcode
xcode-build:
	@echo "==> Building $(XCODE_SCHEME) for tvOS..."
	$(XCODEBUILD) -project $(XCODE_PROJECT) -scheme $(XCODE_SCHEME) \
		-destination 'generic/platform=tvOS' -configuration Debug \
		build CODE_SIGNING_ALLOWED=NO

## xcode-test: Run the app, core, and UI tests on the tvOS simulator
xcode-test:
	@echo "==> Testing $(XCODE_SCHEME) on tvOS..."
	$(XCODEBUILD) test -project $(XCODE_PROJECT) -scheme $(XCODE_SCHEME) \
		-destination '$(XCODE_TEST_DESTINATION)' -configuration Debug \
		CODE_SIGNING_ALLOWED=NO

## test-suite: Run one test suite, e.g. make test-suite SUITE=MediaDatabaseReaderTests
test-suite:
	@test -n "$(SUITE)" || { echo "error: set SUITE=<TestSuiteName>" >&2; exit 1; }
	@echo "==> Testing $(XCODE_SCHEME) [SUITE=$(SUITE)]..."
	$(XCODEBUILD) test -project $(XCODE_PROJECT) -scheme $(XCODE_SCHEME) \
		-destination '$(XCODE_TEST_DESTINATION)' -configuration Debug \
		-only-testing:PlayItRightTests/$(SUITE) \
		CODE_SIGNING_ALLOWED=NO

## xcode-clean: Remove Xcode build artifacts for the app scheme
xcode-clean:
	@echo "==> Cleaning $(XCODE_SCHEME) Xcode build artifacts..."
	$(XCODEBUILD) clean -project $(XCODE_PROJECT) -scheme $(XCODE_SCHEME) \
		-destination 'generic/platform=tvOS' -configuration Debug

## db: Initialize the database for the active environment (ENV=dev|test|prod)
ifeq ($(IS_IN_MEMORY),1)
db: check-env
	@echo "==> ENV=$(ENV) uses an in-memory database; nothing to create."
else
db: check-env $(DB_FILE)
endif

ifneq ($(DB_FILE),)
$(DB_FILE): $(SCHEMA_FILE)
	@command -v sqlite3 >/dev/null 2>&1 || { \
		echo "error: sqlite3 is required but was not found in PATH" >&2; exit 1; \
	}
	@echo "==> Creating database directory at '$(DB_DIR)'..."
	@mkdir -p "$(DB_DIR)"
	@echo "==> Initializing SQLite database at '$(DB_FILE)' using '$(SCHEMA_FILE)'..."
	@sqlite3 "$(DB_FILE)" < "$(SCHEMA_FILE)" > /dev/null
	@echo "==> Database successfully created for '$(ENV)' at '$(DB_FILE)'."
endif

## reset-db: Recreate a fresh database for the active environment (ENV=dev|test|prod)
reset-db: check-env
	@$(MAKE) --no-print-directory clean-db ENV=$(ENV)
	@$(MAKE) --no-print-directory db ENV=$(ENV)

## clean-db: Remove the database for the active environment (ENV=dev|test|prod)
clean-db: check-env
ifeq ($(IS_IN_MEMORY),1)
	@echo "==> ENV=$(ENV) uses an in-memory database; nothing to clean."
else
	@echo "==> Cleaning database for '$(ENV)' at '$(DB_FILE)'..."
	@rm -f "$(DB_FILE)" "$(DB_FILE)-wal" "$(DB_FILE)-shm"
endif

## clean-all-dbs: Remove generated database files from db/ (keeps db/schema.sql)
clean-all-dbs:
	@echo "==> Removing generated databases in db/..."
	@rm -f db/*/library.db db/*/library.db-wal db/*/library.db-shm

## clean: Remove Xcode build artifacts (leaves databases untouched)
clean: xcode-clean
	@echo "==> Removing legacy build caches..."
	@rm -rf .build

## distclean: Remove build artifacts and all generated databases
distclean: clean clean-all-dbs

## env-info: Display the resolved environment, project, and toolchain configuration
env-info: check-env
	@echo "Active Environment:  $(ENV)"
	@echo "Xcode Project:       $(XCODE_PROJECT)"
	@echo "Xcode Scheme:        $(XCODE_SCHEME)"
	@echo "Database File:       $(if $(IS_IN_MEMORY),:memory: (in-memory),$(DB_FILE))"
	@echo "Schema File:         $(SCHEMA_FILE)"
	@echo "Backup Directory:    $(if $(PLAYITRIGHT_BACKUP_DIR),$(PLAYITRIGHT_BACKUP_DIR),<default for $(ENV)>)"
	@echo "Artwork Directory:   $(if $(PLAYITRIGHT_ARTWORK_DIR),$(PLAYITRIGHT_ARTWORK_DIR),<default for $(ENV)>)"
	@echo "Busy Timeout:        $(if $(PLAYITRIGHT_BUSY_TIMEOUT),$(PLAYITRIGHT_BUSY_TIMEOUT),5.0)"
	@echo "Cache Size (KiB):    $(if $(PLAYITRIGHT_CACHE_SIZE_KB),$(PLAYITRIGHT_CACHE_SIZE_KB),8192)"
	@echo "Max Backup Gens:     $(if $(PLAYITRIGHT_MAX_BACKUP_GENS),$(PLAYITRIGHT_MAX_BACKUP_GENS),2)"
	@echo "Xcode Developer Dir: $(XCODE_DEVELOPER_DIR)"

# check-env: Validate the active ENV value
check-env:
	@case " $(VALID_ENVS) " in \
		*" $(ENV) "*) ;; \
		*) echo "error: ENV must be one of: $(VALID_ENVS) (got '$(ENV)')" >&2; exit 1 ;; \
	esac

## help: Display this help message
help:
	@echo "PlayItRight Build & Database Management"
	@echo "Usage: make [target] [ENV=dev|test|prod]"
	@echo ""
	@echo "Targets:"
	@grep -hE '^## ' $(firstword $(MAKEFILE_LIST)) | sed -e 's/^## //' | awk -F': ' '{printf "  %-18s %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make                     # Build app + create dev database"
	@echo "  make db                  # Create dev database (db/dev/library.db)"
	@echo "  make db ENV=prod         # Create prod database (db/prod/library.db)"
	@echo "  make reset-db ENV=dev    # Reset dev database"
	@echo "  make test                # Run app, core, and UI tests"
	@echo "  make test-suite SUITE=X  # Run one test suite"
	@echo "  make xcode-build         # Build the tvOS app in Xcode"
	@echo "  make xcode-test          # Test the tvOS app in the simulator"
	@echo "  make env-info ENV=dev    # Show resolved configuration"
	@echo "  make distclean           # Remove build artifacts and generated databases"

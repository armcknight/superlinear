# The apple-app component's Makefile targets. A project's Makefile fetches
# this file at its pinned tag and includes it; see the apple-app scaffold's
# Makefile. The targets are namespaced so that the project's own `test` and
# `beta` can depend on them, or do more.

APPLE_APP_PLATFORM ?= ios
FASTLANE ?= bundle exec fastlane

.PHONY: apple-app-test apple-app-beta

## apple-app-test: run the tests through the shared fastlane lane
apple-app-test:
	$(FASTLANE) $(APPLE_APP_PLATFORM) test

## apple-app-beta: build and upload to TestFlight through the shared fastlane lane
apple-app-beta:
	$(FASTLANE) $(APPLE_APP_PLATFORM) beta

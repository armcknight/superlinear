# The apple-app component's targets come from armcknight/templates at
# TEMPLATES_TAG. The fragment is downloaded on first use; `make templates-update`
# downloads it again, as after changing the tag.

TEMPLATES_TAG = {{templates.tag}}
APPLE_APP_PLATFORM = {{inputs.platform}}

TEMPLATES_MAKE = .superlinear/make

.DEFAULT_GOAL = test
.PHONY: test beta templates-update

include $(TEMPLATES_MAKE)/apple-app.mk

$(TEMPLATES_MAKE)/%.mk:
	mkdir -p $(@D)
	curl -fsSL https://raw.githubusercontent.com/armcknight/templates/$(TEMPLATES_TAG)/make/$*.mk -o $@

## templates-update: download the Makefile fragments again at TEMPLATES_TAG
templates-update:
	rm -rf $(TEMPLATES_MAKE)
	$(MAKE) $(TEMPLATES_MAKE)/apple-app.mk

## test: run the tests
test: apple-app-test

## beta: build and upload to TestFlight
beta: apple-app-beta

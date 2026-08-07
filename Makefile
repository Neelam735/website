INTEGRATION := integrations/core-hr-new-hire-load
TOOLS       := $(INTEGRATION)/tools
APEX        := apex/approval-engine
DIST        := dist
VERSION     := 01.00.0000
IAR         := $(DIST)/NEW_HIRE_LOAD_$(VERSION).iar

.PHONY: all build validate test sample clean

all: test build validate

## Package the integration source tree into a .iar
build:
	@python3 $(TOOLS)/build_iar.py --out $(DIST) --version $(VERSION)

## Structural checks on the built archive
validate: $(IAR)
	@python3 $(TOOLS)/validate_iar.py $(IAR)

## Mapping, XSLT parity, status derivation, packaging and SQL structure tests
test:
	@python3 -m unittest discover -s $(INTEGRATION)/tests
	@python3 -m unittest discover -s $(APEX)/tests

## Regenerate the sample HDL output from the sample extract
sample:
	@python3 $(TOOLS)/generate_worker_dat.py \
		--csv $(INTEGRATION)/hdl/samples/newhire_sample.csv \
		--out $(INTEGRATION)/hdl/samples

$(IAR): build

clean:
	@rm -rf $(DIST)
	@find $(INTEGRATION) -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

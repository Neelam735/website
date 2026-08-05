DIST := dist

# One block per integration. Adding a third means adding its four variables
# and its name to INTEGRATIONS; the targets below are generic.
NEWHIRE_DIR     := integrations/core-hr-new-hire-load
NEWHIRE_VERSION := 01.00.0000
NEWHIRE_IAR     := $(DIST)/NEW_HIRE_LOAD_$(NEWHIRE_VERSION).iar

PFG401K_DIR     := integrations/principal-401k-loans
PFG401K_VERSION := 01.00.0000
PFG401K_IAR     := $(DIST)/PRINCIPAL_401K_LOANS_$(PFG401K_VERSION).iar

INTEGRATIONS := $(NEWHIRE_DIR) $(PFG401K_DIR)
IARS         := $(NEWHIRE_IAR) $(PFG401K_IAR)

.PHONY: all build validate test sample clean \
        build-newhire build-pfg401k validate-newhire validate-pfg401k \
        test-newhire test-pfg401k

all: test build validate

## Package every integration source tree into a .iar
build: build-newhire build-pfg401k

build-newhire:
	@python3 $(NEWHIRE_DIR)/tools/build_iar.py --out $(DIST) --version $(NEWHIRE_VERSION)

build-pfg401k:
	@python3 $(PFG401K_DIR)/tools/build_iar.py --out $(DIST) --version $(PFG401K_VERSION)

## Structural checks on the built archives
validate: validate-newhire validate-pfg401k

validate-newhire: $(NEWHIRE_IAR)
	@python3 $(NEWHIRE_DIR)/tools/validate_iar.py $(NEWHIRE_IAR)

validate-pfg401k: $(PFG401K_IAR)
	@python3 $(PFG401K_DIR)/tools/validate_iar.py $(PFG401K_IAR)

## Mapping, XSLT parity, status derivation and packaging tests
test: test-newhire test-pfg401k

test-newhire:
	@python3 -m unittest discover -s $(NEWHIRE_DIR)/tests

test-pfg401k:
	@python3 -m unittest discover -s $(PFG401K_DIR)/tests

## Regenerate the sample outputs from the sample inputs
sample:
	@python3 $(NEWHIRE_DIR)/tools/generate_worker_dat.py \
		--csv $(NEWHIRE_DIR)/hdl/samples/newhire_sample.csv \
		--out $(NEWHIRE_DIR)/hdl/samples
	@python3 $(PFG401K_DIR)/tools/generate_principal_file.py \
		--extract $(PFG401K_DIR)/samples/extract_output_sample.xml \
		--out $(PFG401K_DIR)/samples
	@mv $(PFG401K_DIR)/samples/PFG_401K_LOAN_4*.txt \
		$(PFG401K_DIR)/samples/PFG_401K_LOAN_sample.txt

$(NEWHIRE_IAR): build-newhire
$(PFG401K_IAR): build-pfg401k

clean:
	@rm -rf $(DIST)
	@for dir in $(INTEGRATIONS); do \
		find $$dir -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true; \
	done

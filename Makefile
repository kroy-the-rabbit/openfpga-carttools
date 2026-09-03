# Build and test harness for openFPGA-CartTools.
#
# Quartus, containerised (see tools/podman/README.md):
#
#   make cart                  build -> build/cart/{bitstream.rbf_r,sd/,*.zip,report.txt}
#   make cart SKIP_COMPILE=1   repackage existing outputs (no Quartus run)
#   make cart SEED=2           re-run the fitter with a different placement seed
#   make report                regenerate build/cart/report.txt from existing outputs
#   make shell                 interactive shell in the Quartus container
#
# Simulation, containerised (see tools/sim/README.md). Every cartridge-facing
# module is expected to have a testbench here, because the hardware it talks to
# cannot be put in CI and a wrong write to a cartridge is not recoverable:
#
#   make sim-image   build the Icarus Verilog container (once, about a minute)
#   make test        the whole suite
#   make sim-shell   interactive shell in the container with the repo at /work
#
#   make clean       remove build/

PODMAN   ?= podman
IMAGE    ?= localhost/pocket-quartus:25.1std
SIMIMAGE ?= localhost/carttools-sim:1
HARNESS  := tools/podman

# Container user flags, matching tools/podman/build.sh: rootless podman needs
# --userns=keep-id, docker rejects it and wants --user, and podman as root
# rejects it too and wants neither. Still overridable: USERNS= forces none.
IS_DOCKER := $(if $(findstring docker,$(notdir $(PODMAN))),1,)
IS_ROOT   := $(if $(filter 0,$(shell id -u)),1,)
USERNS ?= $(if $(IS_DOCKER),--user $(shell id -u):$(shell id -g),$(if $(IS_ROOT),,--userns=keep-id))
SIMRUN = $(PODMAN) run --rm $(PODMAN_TTY) $(USERNS) \
	--security-opt label=disable \
	-v "$(CURDIR):/work" -w /work -e HOME=/tmp $(SIMIMAGE)

.PHONY: cart report shell sim-image test sim-shell clean

cart:
	PODMAN=$(PODMAN) IMAGE=$(IMAGE) SEED=$(SEED) SKIP_COMPILE=$(SKIP_COMPILE) \
	FITTER_EFFORT="$(FITTER_EFFORT)" NPROC="$(NPROC)" \
	RELEASE_NAME=$(RELEASE_NAME) $(HARNESS)/build.sh

report:
	$(HARNESS)/report.sh

shell:
	$(PODMAN) run --rm -it $(USERNS) --security-opt label=disable \
		-v "$(CURDIR)/build/cart/work:/work" -w /work -e HOME=/tmp $(IMAGE) bash

sim-image:
	$(PODMAN) build --security-opt label=disable -t $(SIMIMAGE) \
		-f $(HARNESS)/Containerfile.sim $(HARNESS)

# run_all.py discovers every tools/sim/tb_*.sv, builds it with the sources its
# header names, runs it, and fails on any $error/$fatal. ARGS passes through,
# so `make test ARGS="-k gb_bus"` runs one testbench.
test:
	$(SIMRUN) python3 tools/sim/run_all.py $(ARGS)

sim-shell: PODMAN_TTY = -it
sim-shell:
	$(SIMRUN) bash

clean:
	rm -rf build

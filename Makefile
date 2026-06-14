# xrdp-fleet — convenience targets. See README.md for the full story.

.PHONY: help build build-noble build-jammy repo keygen clean

help:
	@echo "make keygen        # one-time: create the apt signing key"
	@echo "make build         # build .debs for all codenames (Docker)"
	@echo "make build-noble   # build just noble (24.04)"
	@echo "make build-jammy   # build just jammy (22.04)"
	@echo "make repo          # assemble + sign ./repo from ./out"
	@echo "make clean         # remove ./out and ./repo"

build:
	./scripts/build-local.sh

build-noble:
	./scripts/build-local.sh noble

build-jammy:
	./scripts/build-local.sh jammy

repo:
	./scripts/make-repo.sh

keygen:
	./scripts/gpg-keygen.sh

clean:
	rm -rf out repo

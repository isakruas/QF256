FC = gfortran
FFLAGS ?= -O2 -std=f2008 -ffree-line-length-none -Wall -Wextra -Werror -fcheck=all

.PHONY: all analysis clean
all: build/analyze

build/analyze: analyze.f90
	mkdir -p build
	$(FC) $(FFLAGS) -Jbuild $< -o $@

analysis: build/analyze confirmation.csv noise.csv
	./build/analyze summarize . > ANALYSIS.log

clean:
	rm -f build/analyze build/study_tools.mod

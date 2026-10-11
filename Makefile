FC = gfortran
AR = ar
CC = cc
PDFLATEX ?= pdflatex
GNUPLOT ?= gnuplot
PYTHON ?= python3
FFLAGS ?= -O3 -std=f2008 -ffree-line-length-none -Wall -Wextra -fPIC
CFLAGS ?= -std=c11 -O2 -Wall -Wextra
MOD = -Jbuild/mod -Ibuild/mod
CORE = build/numerics.o build/waveform_metrics.o build/qra_soft.o build/mfsk_iq.o
LIBOBJ = $(CORE) build/qf256_api.o build/qf256_io.o
WIDE_VALIDATION_DIR ?= study/build/wide-acquisition
WIDE_VALIDATION_WORKERS ?= 4
WIDE_GATE = 30.220758775848424
WIDE_CUTOFF = 1850
.PHONY: all clean test test-c-api core-check report strict tools study-analysis snr-validation examples-check wide-validation wide-validation-cal wide-validation-check wide-validation-signals wide-validation-summary
all: bin/qf256 bin/qf256-tx bin/qf256-rx lib/libqf256.a lib/libqf256.so
build/mod bin lib:
	mkdir -p $@
build/numerics.o: src/core/numerics.f90 | build/mod
	$(FC) $(FFLAGS) $(MOD) -c $< -o $@
build/waveform_metrics.o: src/core/waveform_metrics.f90 | build/mod
	$(FC) $(FFLAGS) $(MOD) -c $< -o $@
build/qra_soft.o: src/core/qra_soft.f90 build/numerics.o
	$(FC) $(FFLAGS) $(MOD) -c $< -o $@
build/mfsk_iq.o: src/core/mfsk_iq.f90 build/qra_soft.o build/waveform_metrics.o
	$(FC) $(FFLAGS) $(MOD) -c $< -o $@
build/qf256_api.o: src/qf256_api.f90 $(CORE)
	$(FC) $(FFLAGS) $(MOD) -c $< -o $@
build/qf256_io.o: src/io/qf256_io.f90 $(CORE)
	$(FC) $(FFLAGS) $(MOD) -c $< -o $@
build/qf256_cli.o: src/qf256_cli.f90 build/qf256_api.o build/qf256_io.o
	$(FC) $(FFLAGS) $(MOD) -c $< -o $@
lib/libqf256.a: $(LIBOBJ) | lib
	$(AR) rcs $@ $^
lib/libqf256.so: $(LIBOBJ) | lib
	$(FC) -shared -o $@ $^
bin/qf256: app/qf256.f90 build/qf256_cli.o lib/libqf256.a | bin
	$(FC) $(FFLAGS) $(MOD) $< build/qf256_cli.o lib/libqf256.a -o $@
bin/qf256-tx: app/qf256_tx.f90 build/qf256_cli.o lib/libqf256.a | bin
	$(FC) $(FFLAGS) $(MOD) $< build/qf256_cli.o lib/libqf256.a -o $@
bin/qf256-rx: app/qf256_rx.f90 build/qf256_cli.o lib/libqf256.a | bin
	$(FC) $(FFLAGS) $(MOD) $< build/qf256_cli.o lib/libqf256.a -o $@
bin/test_core: tests/test_core.f90 $(CORE) | bin
	$(FC) $(FFLAGS) -fcheck=all $(MOD) $< $(CORE) -o $@
bin/test_api: tests/test_qf256_api.f90 lib/libqf256.a | bin
	$(FC) $(FFLAGS) -fcheck=all $(MOD) $< lib/libqf256.a -o $@
bin/test_io: tests/test_io.f90 lib/libqf256.a | bin
	$(FC) $(FFLAGS) -fcheck=all $(MOD) $< lib/libqf256.a -o $@
bin/test_c_api: tests/test_qf256_api_c.c include/qf256.h lib/libqf256.so | bin
	$(CC) $(CFLAGS) -Iinclude $< -Llib -lqf256 -Wl,-rpath,'$$ORIGIN/../lib' -lm -o $@
bin/create_fixtures: tests/create_fixtures.f90 $(CORE) | bin
	$(FC) $(FFLAGS) $(MOD) $< $(CORE) -o $@
tools: bin/create_fixtures
	$(MAKE) -C study all
	$(MAKE) -f study/Makefile.reproduce all
study-analysis: tools
	$(MAKE) -C study analysis
	$(MAKE) -f study/Makefile.reproduce physical-summary
	$(GNUPLOT) study/plots.gp
snr-validation: tools
	$(MAKE) -f study/Makefile.reproduce snr-validation
$(WIDE_VALIDATION_DIR):
	mkdir -p $@
$(WIDE_VALIDATION_DIR)/noise-cal.csv: study/validate_wide_acquisition.py lib/libqf256.so | $(WIDE_VALIDATION_DIR)
	OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 $(PYTHON) $< noise --lib lib/libqf256.so --count 2048 --seed-base 6066101100 --cutoff $(WIDE_CUTOFF) --workers $(WIDE_VALIDATION_WORKERS) --output $@
$(WIDE_VALIDATION_DIR)/noise-check.csv: study/validate_wide_acquisition.py lib/libqf256.so | $(WIDE_VALIDATION_DIR)
	OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 $(PYTHON) $< noise --lib lib/libqf256.so --count 4096 --seed-base 7076101100 --cutoff $(WIDE_CUTOFF) --workers $(WIDE_VALIDATION_WORKERS) --output $@
$(WIDE_VALIDATION_DIR)/signals.csv: study/validate_wide_acquisition.py lib/libqf256.so | $(WIDE_VALIDATION_DIR)
	OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 $(PYTHON) $< signal --lib lib/libqf256.so --count-per-level 128 --snr -20 -18 --seed-base 8086101100 --cutoff $(WIDE_CUTOFF) --workers $(WIDE_VALIDATION_WORKERS) --chunk 4 --output $@
wide-validation-cal: $(WIDE_VALIDATION_DIR)/noise-cal.csv
wide-validation-check: $(WIDE_VALIDATION_DIR)/noise-check.csv
wide-validation-signals: $(WIDE_VALIDATION_DIR)/signals.csv
wide-validation-summary: wide-validation-cal wide-validation-check wide-validation-signals
	$(PYTHON) study/validate_wide_acquisition.py summarize-noise --input $(WIDE_VALIDATION_DIR)/noise-cal.csv --gate $(WIDE_GATE)
	$(PYTHON) study/validate_wide_acquisition.py summarize-noise --input $(WIDE_VALIDATION_DIR)/noise-check.csv --gate $(WIDE_GATE)
	$(PYTHON) study/validate_wide_acquisition.py summarize-signal --input $(WIDE_VALIDATION_DIR)/signals.csv --gate $(WIDE_GATE)
wide-validation: wide-validation-summary
examples-check: all
	bash tests/check_examples.sh
core-check:
	sha256sum -c docs/RUNTIME-CORE.sha256
test: all bin/test_core bin/test_api bin/test_io core-check
	./bin/test_core
	./bin/test_api
	mkdir -p build/test/io
	./bin/test_io
	bash tests/check_cli.sh
test-c-api: all bin/test_c_api
	./bin/test_c_api
strict:
	$(MAKE) clean
	$(MAKE) FFLAGS="$(FFLAGS) -Werror" CFLAGS="$(CFLAGS) -Werror" all test test-c-api examples-check study-analysis
report: docs/report/qf256-report.pdf
docs/report/qf256-report.pdf: docs/report/qf256-report.tex docs/report/study-methods.tex docs/report/study-results.tex study/publication-cells.tex study/publication-thresholds.tex study/figures/acceptance.pdf study/figures/physical.pdf
	$(PDFLATEX) -interaction=nonstopmode -halt-on-error -file-line-error -output-directory=docs/report $<
	$(PDFLATEX) -interaction=nonstopmode -halt-on-error -file-line-error -output-directory=docs/report $<
clean:
	rm -rf build bin lib study/build

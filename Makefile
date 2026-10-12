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
STUDY_WORKERS ?= 8
STUDY_RUN_DIR ?= study/build/campaign
ACQUISITION_DIR ?= study/acquisition
ACCEPTANCE_GATE = 30.220758775848424
.PHONY: all clean test test-c-api core-check report strict tools study-tools study study-campaign study-analysis study-evidence snr-validation examples-check acquisition-validation
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
STUDY_FLAGS = -O3 -std=f2008 -ffree-line-length-none -Wall -Wextra -Werror
STUDY_CORE = src/core/numerics.f90 src/core/waveform_metrics.f90 src/core/qra_soft.f90 src/core/mfsk_iq.f90 src/qf256_api.f90
STUDY_CHANNEL = study/channel.f90 study/frontend.f90
study/build/reproduce: $(STUDY_CORE) $(STUDY_CHANNEL) study/reproduce.f90
	mkdir -p study/build/reproduce-mod
	$(FC) $(STUDY_FLAGS) -Jstudy/build/reproduce-mod -Istudy/build/reproduce-mod $^ -o $@
study/build/validate_snr: $(STUDY_CORE) $(STUDY_CHANNEL) study/validate_snr.f90
	mkdir -p study/build/snr-mod
	$(FC) $(STUDY_FLAGS) -Jstudy/build/snr-mod -Istudy/build/snr-mod $^ -o $@
study/build/analyze: study/analyze.f90
	mkdir -p study/build/analysis-mod
	$(FC) $(STUDY_FLAGS) -fcheck=all -Jstudy/build/analysis-mod $< -o $@
study/build/summarize_physical: study/summarize_physical.f90
	mkdir -p study/build
	$(FC) $(STUDY_FLAGS) -fcheck=all $< -o $@
bin/test_channel: src/core/numerics.f90 src/core/waveform_metrics.f90 $(STUDY_CHANNEL) tests/test_channel.f90 | bin
	mkdir -p build/channel-mod
	$(FC) $(STUDY_FLAGS) -fcheck=all -Jbuild/channel-mod -Ibuild/channel-mod $^ -o $@
tools: bin/create_fixtures study-tools
study-tools: study/build/reproduce study/build/validate_snr study/build/analyze study/build/summarize_physical
study-analysis: study/build/analyze study/build/summarize_physical
	./study/build/analyze summarize study
	./study/build/summarize_physical
	$(GNUPLOT) study/plots.gp
study-campaign: study-tools
	OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 $(PYTHON) study/run_campaign.py --workers $(STUDY_WORKERS) --output $(STUDY_RUN_DIR)
	$(MAKE) study-analysis
snr-validation: study/build/validate_snr
	./study/build/validate_snr > study/build/SNR_VALIDATION.csv
	cmp study/SNR_VALIDATION.csv study/build/SNR_VALIDATION.csv
	cat study/build/SNR_VALIDATION.csv
$(ACQUISITION_DIR):
	mkdir -p $@
$(ACQUISITION_DIR)/noise.csv: study/validate_acquisition.py lib/libqf256.so | $(ACQUISITION_DIR)
	OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 $(PYTHON) $< noise --lib lib/libqf256.so --count 4096 --seed-base 9106101100 --workers $(STUDY_WORKERS) --replace --output $@
$(ACQUISITION_DIR)/signals.csv: study/validate_acquisition.py lib/libqf256.so | $(ACQUISITION_DIR)
	OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 $(PYTHON) $< signal --lib lib/libqf256.so --count-per-level 128 --snr -20 -18 -4 --seed-base 9107101100 --workers $(STUDY_WORKERS) --chunk 4 --replace --output $@
acquisition-validation: $(ACQUISITION_DIR)/noise.csv $(ACQUISITION_DIR)/signals.csv
	$(PYTHON) study/validate_acquisition.py summarize-noise --input $(ACQUISITION_DIR)/noise.csv --gate $(ACCEPTANCE_GATE)
	$(PYTHON) study/validate_acquisition.py summarize-signal --input $(ACQUISITION_DIR)/signals.csv --gate $(ACCEPTANCE_GATE)
study: study-campaign
	$(MAKE) acquisition-validation
	$(MAKE) study-evidence
study-evidence:
	$(PYTHON) study/finalize.py
examples-check: all
	bash tests/check_examples.sh
core-check:
	sha256sum -c docs/CORE.sha256
test: all bin/test_core bin/test_api bin/test_io bin/test_channel study/build/analyze study/build/summarize_physical core-check
	./bin/test_core
	./bin/test_api
	./bin/test_channel
	$(PYTHON) tests/test_study.py
	$(PYTHON) tests/test_campaign.py
	mkdir -p build/test/io
	./bin/test_io
	bash tests/check_cli.sh
test-c-api: all bin/test_c_api
	./bin/test_c_api
strict:
	$(MAKE) --always-make FFLAGS="$(FFLAGS) -Werror" CFLAGS="$(CFLAGS) -Werror" all test test-c-api examples-check study-analysis
report: docs/report/qf256-report.pdf
docs/report/qf256-report.pdf: docs/report/qf256-report.tex docs/report/study-methods.tex docs/report/study-results.tex study/publication-cells.tex study/publication-thresholds.tex study/figures/acceptance.pdf study/figures/physical.pdf
	$(PDFLATEX) -interaction=nonstopmode -halt-on-error -file-line-error -output-directory=docs/report $<
	$(PDFLATEX) -interaction=nonstopmode -halt-on-error -file-line-error -output-directory=docs/report $<
clean:
	rm -rf build bin lib study/build
